#!/bin/bash

vm_running() {
	local vm=$1

	if [ ! -e /var/run/libvirt/qemu/$vm.pid ] ; then
		return 1
	fi

	if ! check_process_status $(cat /var/run/libvirt/qemu/$vm.pid) ; then
		return 1
	fi

	return 0
	# [ "$(virsh domstate ${VM})" = "running" ] && return 0 || return 1
}

vm_connectable_one() {
	local vm=$1
	local vmip=$(sshvm -i $vm 2> /dev/null)

	[ "$vmip" ] || return 1
	ping -w1 $vmip > /dev/null
}

# assuming that sshvm is located under PATH
vm_ssh_connectable_one() {
	local vm=$1
	local vmip=$(sshvm -i $vm 2> /dev/null)

	[ "$vmip" ] || return 1
	ssh -o ConnectTimeout=3 $vmip date > /dev/null 2>&1
}

# Start VM and wait until the VM become connectable.
vm_start_wait() {
	local vm=$1
	local _tmpd=$(mktemp -d)

	cat <<EOF > $_tmpd/vm_start_wait.exp
#!/usr/bin/expect

set timeout 1
set timecount 100
log_file -noappend $_tmpd/vm_start_wait.log

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
	if vm_running $vm ; then
		echo "[$vm] domain already running."
	else
		echo "[$vm] starting domain ... "
		virsh start $vm > /dev/null 2>&1
	fi
	expect $_tmpd/vm_start_wait.exp > /dev/null 2>&1
	[ ! -e $_tmpd/vm_start_wait.log ] && echo "expect failed." && return 1
	if grep -q "VM start finished" $_tmpd/vm_start_wait.log ; then
		for i in $(seq 60) ; do
			vm_ssh_connectable_one $vm && return 0
			sleep 2
		done
	fi
	echo "[$vm] VM started, but not ssh-connectable."
	return 1
}

vm_shutdown_wait() {
	local vm=$1
	local vmip=$2
	local ret=0

	if ! vm_running $vm ; then
		echo "[$vm] already shut off"
		return 0
	fi
	if vm_connectable_one $vm && vm_ssh_connectable_one $vm ; then
		echo "shutdown vm $vm"
		vmip=$(sshvm -i $vm)
		ssh "$vmip" "sync ; shutdown -h now"

		# virsh start might fail, because the above command terminates the connection
		# before the vm completes the shutdown. Need to confirm vm is shut off.
		for i in $(seq 60) ; do
			if ! vm_running $vm ; then
				echo "[$vm] shutdown done"
				return 0
			fi
			sleep 2
		done
		echo "[$vm] shutdown timeout, destroy it."
	else
		echo "[$vm] no ssh-connection, destroy it."
	fi
	timeout 5 virsh destroy $vm
	ret=$?
	if [ $ret -eq 0 ] ; then
		return 1
	else
		if [ $ret -eq 124 ] ; then
			echo "[$vm] virsh destroy timed out"
		else
			echo "[$vm] virsh destroy failed"
			kill -9 $(cat /var/run/libvirt/qemu/$vm.pid)
		fi
	fi
}

show_guest_console() {
	echo "####### GUEST CONSOLE #######"
	cat $TMPD/vmconsole
	echo "####### GUEST CONSOLE END #######"
}

check_guest_kernel_message() {
	[ "$1" = -v ] && local inverse=true && shift
	local word="$1"
	if [ "$word" ] ; then
		count_testcount
		grep "$word" $TMPD/vmconsole > /dev/null 2>&1
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

# virsh command sometimes doesn't work, so look at libvirt file directly
# /var/run/libvirt/qemu/<VM>.xml
get_vm_id() {
    local vm=$1

    xmllint --xpath "/domstatus/domain/@id" /var/run/libvirt/qemu/$vm.xml | cut -f2 -d= | tr -d '"'
}

get_vm_console() {
    local vm=$1

    xmllint --xpath "/domstatus/domain/devices/console/source/@path" /var/run/libvirt/qemu/$vm.xml | cut -f2 -d= | tr -d '"'
}

start_vm_console_monitor() {
    local basename=$1
    local vm=$2
    local vmconsole=$(get_vm_console $vm)
	local vmid=$(get_vm_id $vm)

    cat $vmconsole > $basename.$vm.$vmid &
    echo "===> started vm console monitor for $vm, ID $vmid, saved in $basename.$vm.$vmid"
    echo "ln -sf $basename.$vm.$vmid $basename"
    ln -sf $basename.$vm.$vmid $basename
}
