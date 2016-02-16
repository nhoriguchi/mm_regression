#!/bin/bash

vm_running() {
	[ "$(virsh domstate ${VM})" = "running" ] && return 0 || return 1
}

vm_connectable() {
	ping -w1 $VMIP > /dev/null
}

vm_ssh_connectable() {
	ssh -o ConnectTimeout=3 $VMIP date > /dev/null 2>&1
}

# assuming that sshvm is located under PATH
vm_ssh_connectable_one() {
	local vm=$1
	local vmip=$(sshvm -i $vm 2> /dev/null)

	ssh -o ConnectTimeout=3 $vmip date > /dev/null 2>&1
}

# Start VM and wait until the VM become connectable.
vm_start_wait() {
	local vm=$1

	cat <<EOF > $TMPD/vm_start_wait.exp
#!/usr/bin/expect

set timeout 1
set timecount 100
log_file -noappend $TMPD/vm_start_wait.log

spawn virsh console $vm

expect "Escape character is"
send "\n"
while {\$timecount > 0} {
    send "\n"
    expect "login:" {
        send_user "\nVM start finished\n"
        break
    }
    set timecount [expr \$timecount-1]
    if {[expr \$timecount] == 0} {
        send_user "\nVM start timeout\n"
    }
}
send -- ""
interact
EOF
	if [ "$(virsh domstate $vm)" == "running" ] ; then
		echo "[$vm] domain already running."
	else
		echo "[$vm] starting domain ... "
		virsh start $vm > /dev/null 2>&1
	fi
	expect $TMPD/vm_start_wait.exp > /dev/null 2>&1
	[ ! -e $TMPD/vm_start_wait.log ] && echo "expect failed." && return 1
	if grep -q "VM start finished" $TMPD/vm_start_wait.log ; then
		for i in $(seq 20) ; do
			vm_ssh_connectable_one $vm && return 0
			sleep 2
		done
	fi
	echo "[$vm] VM started, but not ssh-connectable."
	return 1
}

VMDIRTY=false
get_vmdirty()   { echo $VMDIRTY; }
set_vmdirty()   { VMDIRTY=true;  }
clear_vmdirty() { VMDIRTY=false; }
vmdirty()       { [ $VMDIRTY = true ] && return 0 || return 1 ; }

vm_shutdown_wait() {
	local vm=$1
	local vmip=$2
	local ret=0

	if [ "$(virsh domstate $vm)" == "shut off" ] ; then
		echo "[$vm] already shut off"
		return 0
	fi

	echo "shutdown vm $vm"
	ssh "$vmip" "sync ; shutdown -h now"

	# virsh start might fail, because the above command terminates the connection
	# before the vm completes the shutdown. Need to confirm vm is shut off.
	local timeout=60
	while [ "$timeout" -gt 0 ] ; do
		if [ "$(virsh domstate $vm)" == "shut off" ] ; then
			echo "[$vm] shutdown done"
			return 0
		fi
		sleep 1
		timeout=$[timeout - 1]
	done
	echo "[$vm] shutdown timeout. Destroy it."
	virsh destroy $vm
	return 1
}

vm_serial_monitor() {
	cat <<EOF > $TMPD/vm_serial_monitor.exp
#!/usr/bin/expect

set timeout 5
set target $VM
log_file -noappend $TMPD/vm_serial_monitor.log

spawn virsh console $VM
expect "Escape character is"
send "\n"
send "\n"
sleep 10
send -- ""
interact
EOF
	expect $TMPD/vm_serial_monitor.exp > /dev/null 2>&1
}

run_vm_serial_monitor() {
	vm_serial_monitor $VM > /dev/null 2>&1 &
	GUESTSERIALMONITORPID=$!
	sleep 1
}

stop_vm_serial_monitor() {
	disown $GUESTSERIALMONITORPID
	kill -SIGKILL $GUESTSERIALMONITORPID > /dev/null 2>&1
}

get_guest_kernel_message() {
	echo "####### GUEST CONSOLE #######"
	if [ -e "$TMPD/dmesg_guest_after" ] ; then
		diff $TMPD/dmesg_guest_before $TMPD/dmesg_guest_after | \
			grep -v '^< ' | tee $TMPD/dmesg_guest_diff
	else
		layout_guest_dmesg $TMPD/vm_serial_monitor.log | \
			tee $TMPD/dmesg_guest_diff
	fi
	echo "####### GUEST CONSOLE END #######"
}

get_guest_kernel_message_before() {
	ssh ${SSH_OPT} $VMIP dmesg > $TMPD/dmesg_guest_before
	rm $TMPD/dmesg_guest_after 2> /dev/null
}

get_guest_kernel_message_after() {
	ssh ${SSH_OPT} $VMIP dmesg > $TMPD/dmesg_guest_after
}

layout_guest_dmesg() {
	tac $1 | gawk '
		BEGIN { flag = 0; }
		{
			if (flag == 0 && $0 ~ /.*login: .*/) {
				flag = 1;
				print gensub(/.*login: (.*)/, "\\1", "g", $0);
			}
			if (flag == 0) { print $0; }
		}
	' | tac
}

check_guest_kernel_message() {
	[ "$1" = -v ] && local inverse=true && shift
	local word="$1"
	if [ "$word" ] ; then
		count_testcount
		grep "$word" $TMPD/dmesg_guest_diff > /dev/null 2>&1
		if [ $? -eq 0 ] ; then
			if [ "$inverse" ] ; then
				count_failure "guest kernel message shows unexpected word '$word'."
			else
				count_success "guest kernel message shows expected word '$word'."
			fi
		else
			if [ "$inverse" ] ; then
				count_success "guest kernel message does not show unexpected word '$word'."
			else
				count_failure "guest kernel message does not show expected word '$word'."
			fi
		fi
	fi
}
