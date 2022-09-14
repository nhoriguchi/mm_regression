#!/bin/bash

. $TRDIR/lib/mm.sh

[ ! -x /usr/local/bin/sshvm ] && install $TCDIR/lib/sshvm /usr/local/bin/sshvm
[ ! "$VM" ] && echo_log "You must give VM name in recipe file" && return 1

SSH_OPT="-o ConnectTimeout=5"
GPA2HPA=$(dirname $(readlink -f $BASH_SOURCE))/gpa2hpa.rb
GUESTTESTALLOC=/usr/local/bin/test_alloc_generic
GUESTPAGETYPES=/usr/local/bin/page-types

vm_running() {
	local vm=$1

	if [ ! -f "/var/run/libvirt/qemu/$vm.pid" ] ; then
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

	ping -w1 $vm > /dev/null
}

vm_ssh_connectable_one() {
	local vm=$1

	ssh -o ConnectTimeout=3 $vm date > /dev/null 2>&1
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

vm_start_wait_noexpect() {
	local vm=$1
	local _tmpd=$(mktemp -d)

	if vm_running $vm ; then
		echo "[$vm] domain already running."
	else
		echo "[$vm] starting domain ... "
		virsh start $vm > /dev/null 2>&1
	fi

	for i in $(seq 60) ; do
		if ssh -o ConnectTimeout=3 $vm date > /dev/null 2>&1 ; then
			echo "done $$"
			return 0
		fi
		sleep 1
	done

	echo "VM started, but not ssh-connectable."
	return 1
}

vm_shutdown_wait() {
	local vm=$1
	local ret=0

	if ! vm_running $vm ; then
		echo "[$vm] already shut off"
		return 0
	fi
	if vm_connectable_one $vm && vm_ssh_connectable_one $vm ; then
		echo "shutdown vm $vm"
		ssh $vm "sync ; shutdown -h now"

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

_VM_CONSOLE=
start_vm_console_monitor() {
    local basename=$1
    local vm=$2
    local vmconsole=$(get_vm_console $vm)
	local vmid=$(get_vm_id $vm)

	if [ -e $basename.$vm.$vmid ] ; then
		echo "you already monitoring $basename.$vm.$vmid"
		return
	fi
	_VM_CONSOLE=$vmconsole
    cat $vmconsole > $basename.$vm.$vmid &
    echo "===> started vm console monitor for $vm, ID $vmid, saved in $basename.$vm.$vmid"
    ln -sf $basename.$vm.$vmid $basename
}

vm_watchdog() {
	local vm=$1
	local timer=$2 # in sec
	local tmp_timer=

	while true ; do
		tmp_timer=$timer
		while [ "$tmp_timer" -gt 0 ] ; do
			if ping -w1 $vm > /dev/null ; then
				break
			else
				tmp_timer=$[tmp_timer - 1]
			fi
			if [ "$tmp_timer" -eq 0 ] ; then
				echo "[$vm] watchdog timeout"
				vm_shutdown_wait $vm
				return 0
			fi
			if ! vm_running $vm ; then
				echo "[$vm] guest shutdown"
				return 0
			fi
		done
		sleep 1
	done
}

# TODO: need to convert VM name to IP address, but currently assuming that
# DNS is configured in virtual netowrk.
vm_to_vmip() {
	echo $VM
}

send_helper_to_guest() {
	local vmip=$1

	scp build/test_alloc_generic $vmip:$GUESTTESTALLOC > /dev/null || return 1
	scp build/page-types $vmip:$GUESTPAGETYPES > /dev/null || return 1
}

stop_guest_memeater() {
	local vmip=$1

	ssh $vmip "pkill -9 -f $GUESTTESTALLOC > /dev/null 2>&1 </dev/null"
}

start_guest_memeater() {
	local vm=$1
	local vmip=$(vm_to_vmip $VM)
	local size=$2

	stop_guest_memeater $vmip

	echo_log "start running test_alloc_generic on VM ($vm:$vmip)"
	if [ "$BACKEND" == clean_pagecache ] ; then
		ssh $vmip "
			$GUESTTESTALLOC -B pagecache -n $size -f read -L \"mmap access:type=read:wait_after access:type=read:wait_after\" > /dev/null 2>&1 </dev/null &"
	elif [ "$BACKEND" == dirty_pagecache ] ; then
		ssh $vmip "
			$GUESTTESTALLOC -B pagecache -n $size -f write -L \"mmap access:type=write:wait_after access:type=write:wait_after\" > /dev/null 2>&1 </dev/null &"
	elif [ "$BACKEND" == anonymous ] ; then
		ssh $vmip "
			$GUESTTESTALLOC -B anonymous -n $size -L \"mmap access:wait_after access:wait_after\" > /dev/null 2>&1 </dev/null &"
	elif [ "$BACKEND" == thp ] ; then
		ssh $vmip "
			$GUESTTESTALLOC -B thp -n $size -L \"mmap access:wait_after access:wait_after\" > /dev/null 2>&1 </dev/null &"
	else
		ssh $vmip "
			$GUESTTESTALLOC -B pagecache -B anonymous -B thp -n $size -L \"mmap access:wait_after access:wait_after\" > /dev/null 2>&1 </dev/null &"
	fi
	ssh $vmip "pgrep -f $GUESTTESTALLOC" | tr '\n' ' ' > $TMPD/_guest_memeater_pids.1
	if [ ! -s $TMPD/_guest_memeater_pids.1 ] ; then
		echo "Failed to start guest memeater $GUESTTESTALLOC" >&2
		return 1
	fi
	return 0
}

set_vm_maxmemory() {
	local vm=$1

	virsh dumpxml $vm > $TMPD/vm.xml || return 1
	if grep -q "<maxMemory " $TMPD/vm.xml ; then
		# already set
		return 0;
	fi

	virsh destroy $vm || return 1
	head -n3 $TMPD/vm.xml > $TMPD/.vm1.xml
	echo "<maxMemory slots='16' unit='KiB'>125829120</maxMemory>" >> $TMPD/.vm1.xml
	sed -ne '4,$p' $TMPD/vm.xml > $TMPD/.vm2.xml
	cat $TMPD/.vm1.xml $TMPD/.vm2.xml > $TMPD/vm.xml
	virsh define $TMPD/vm.xml
	virsh start $vm
}
