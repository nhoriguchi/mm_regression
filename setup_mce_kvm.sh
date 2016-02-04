#!/bin/bash

. $TCDIR/lib/mm.sh
. $TCDIR/lib/numa.sh
. $TCDIR/lib/mce.sh
. $TCDIR/lib/kvm.sh

SSH_OPT="-o ConnectTimeout=5"

[ ! "$VM" ] && echo_log "You must give VM name in recipe file" && return 1
[ ! "$VMIP" ] && echo_log "You must give VM IP address in recipe file" && return 1

GPA2HPA=$(dirname $(readlink -f $BASH_SOURCE))/gpa2hpa.rb
guest_test_alloc=/usr/local/bin/test_alloc_generic
GUESTPAGETYPES=/usr/local/bin/page-types
TARGETGVA=""
TARGETGPA=""
TARGETHPA=""

# check VM RAM size is not greater than 2GB
memsize=$(virsh dominfo $VM | grep "Used memory:" | tr -s ' ' | cut -f3 -d' ')
if [ "$memsize" -gt 2097152 ] ; then
	echo_log "Too much VM RAM size. (> 2GB)"
	return 1
fi

# send helper tools to guest
send_helper_to_guest() {
	scp $test_alloc_generic $VMIP:$guest_test_alloc > /dev/null
	scp $PAGETYPES $VMIP:$GUESTPAGETYPES > /dev/null
}

# define helper functions below

stop_guest_memeater() {
	ssh $VMIP "pkill -9 -f $guest_test_alloc > /dev/null 2>&1 </dev/null"
}

start_guest_memeater() {
	stop_guest_memeater

	echo_log "start running test_alloc_generic on VM ($VM:$VMIP)"
	ssh $VMIP "$guest_test_alloc -B pagecache -N 2 -f read -L 'mmap access:type=read:wait_after access:type=read:wait_after' > /dev/null 2>&1 </dev/null &"
	ssh $VMIP "$guest_test_alloc -B pagecache -N 2 -f write -L 'mmap access:type=write:wait_after access:type=write:wait_after' > /dev/null 2>&1 </dev/null &"
	ssh $VMIP "$guest_test_alloc -B anonymous -B thp -N 2 -L 'mmap access:wait_after access:wait_after' > /dev/null 2>&1 </dev/null &"
	ssh $VMIP "pgrep -f $guest_test_alloc" | tr '\n' ' ' > $TMPD/guest_memeater_pids.1
	if [ ! -s $TMPD/guest_memeater_pids.1 ] ; then
		echo "Failed to start guest memeater $guest_test_alloc" >&2
		return 1
	fi
	return 0
}

get_gpa_guest_memeater() {
	local flagtype=$1
	# scp $VMIP:/tmp/mapping /tmp/mapping > /dev/null 2>&1
	# local start=$(printf "0x%lx" $[$(sort /tmp/mapping | sort | head -n1)/4096])
	# local end=$(printf "0x%lx" $[$(sort /tmp/mapping | sort | tail -n1)/4096 + 256])
	# local cmd="$GUESTPAGETYPES -p ${GUESTMEMEATERPID} -b ${flagtype} -rNL"
	# local line=
	# while read line ; do
	# 	cmd="$cmd -a $[line/4096]+256"
	# done < /tmp/mapping
	# echo_log "$cmd"
	# ssh $VMIP "$cmd" | grep -v offset | tr '\t' ' ' | tr -s ' ' > $TMPD/guest-page-types
	# local lines=`wc -l $TMPD/guest-page-types | cut -f1 -d' '`
	# [ "$lines" -eq 0 ] && echo_log "Page on pid:$GUESTMEMEATERPID not found." >&2 && return 1
	# [ "$lines" -gt 2 ] && lines=`ruby -e "p rand($lines) + 1"`
	# TARGETGVA=0x`cat $TMPD/guest-page-types | sed -n ${lines}p | cut -f1 -d ' '`
	# TARGETGPA=0x`cat $TMPD/guest-page-types | sed -n ${lines}p | cut -f2 -d ' '`

	ssh $VMIP "for pid in $(cat $TMPD/guest_memeater_pids.1) ; do $GUESTPAGETYPES -p \$pid -NrL -b $flagtype -a 0x700000000+0x10000000 ; done" | grep -v offset | tr '\t' ' ' | tr -s ' ' > $TMPD/guest_page_types

	local lines=`wc -l $TMPD/guest_page_types | cut -f1 -d' '`
	[ "$lines" -eq 0 ] && echo_log "Page ($flagtype) not exist on guest memeater." >&2 && return 1
	[ "$lines" -gt 2 ] && lines=`ruby -e "p rand($lines) + 1"`
	echo "# of pages $flagtypes: $lines"
	TARGETGVA=0x`cat $TMPD/guest_page_types | sed -n ${lines}p | cut -f1 -d ' '`
	TARGETGPA=0x`cat $TMPD/guest_page_types | sed -n ${lines}p | cut -f2 -d ' '`
	[ "$TARGETGPA" == 0x ] && echo_log "Failed to get GPA. Test skipped." && return 1
	TARGETHPA=`ruby $GPA2HPA $VM $TARGETGPA`
	if [ ! "$TARGETHPA" ] || [ "$TARGETHPA" == "0x" ] || [ "$TARGETHPA" == "0x0" ] ; then
		echo_log "Failed to get HPA. Test skipped." && return 1
	fi
	echo_log "GVA:$TARGETGVA => GPA:$TARGETGPA => HPA:$TARGETHPA"
	return 0
}

get_hpa() {
	local flagtype="$1"
	get_gpa_guest_memeater "$flagtype" || return 1
	echo_log -n "HPA status: " ; $PAGETYPES -a $TARGETHPA -Nlr | grep -v offset
	echo_log -n "GPA status: " ; ssh $VMIP $GUESTPAGETYPES -a $TARGETGPA -Nlr | grep -v offset
}

guest_process_running() {
	ssh $VMIP "pgrep -f $guest_test_alloc" | tr '\n' ' ' > $TMPD/guest_memeater_pids.2
	diff -q $TMPD/guest_memeater_pids.1 $TMPD/guest_memeater_pids.2 > /dev/null
}

prepare_mce_kvm() {
	TARGETGVA=""
	TARGETGPA=""
	TARGETHPA=""

	if [ "$ERROR_TYPE" = mce-srao ] ; then
		check_mce_capability || return 1 # MCE SRAO not supported
	fi

	prepare_mm_generic || return 1
	# unconditionally restart vm because memory background might change
	# (thp <=> anon)
	virsh destroy $VM
	echo 3 > /proc/sys/vm/drop_caches ; sync
	vm_restart_wait || sleep 1
	stop_guest_memeater
	send_helper_to_guest
	save_nr_corrupted_before
	get_guest_kernel_message_before
	run_vm_serial_monitor
}

cleanup_mce_kvm() {
	save_nr_corrupted_inject
	all_unpoison
	stop_guest_memeater
	vm_ssh_connectable && get_guest_kernel_message_after
	get_guest_kernel_message | tee -a $OFILE
	stop_vm_serial_monitor
	cleanup_mm_generic
	save_nr_corrupted_unpoison
}

check_guest_state() {
	if vm_ssh_connectable ; then
		echo_log "Guest OS still alive."
		set_return_code "GUEST_ALIVE"
		if guest_process_running ; then
			echo_log "And $guest_test_alloc still running."
			set_return_code "GUEST_PROC_ALIVE"
			echo_log "let $guest_test_alloc access to error page"

			access_error
			if vm_ssh_connectable ; then
				if guest_process_running ; then
					echo_log "$guest_test_alloc was still alive"
					set_return_code "GUEST_PROC_ALIVE_LATER_ACCESS"
				else
					echo_log "$guest_test_alloc was killed"
					set_return_code "GUEST_PROC_KILLED_LATER_ACCESS"
				fi
			else
				echo_log "Guest OS panicked."
				set_return_code "GUEST_PANICKED_LATER_ACCESS"
			fi
			return
		else
			echo_log "But $guest_test_alloc was killed."
			set_return_code "GUEST_PROC_KILLED"
			return
		fi
	else
		echo_log "Guest OS panicked."
		set_return_code "GUEST_PANICKED"
	fi
	# Force shutdown if VM is not connected (then maybe it stalls.)
	echo_log "Wait all kernel messages are output on serial console"
	sleep 5
	virsh destroy $VM
	set_vmdirty
}

access_error() {
	ssh $VMIP "pkill -SIGUSR1 -f $guest_test_alloc > /dev/null 2>&1 </dev/null"
	sleep 0.2 # need short time for access operation to finish.
}

check_page_migrated() {
	local gpa="$1"
	local oldhpa="$2"

	count_testcount
	currenthpa=$(ruby ${GPA2HPA} $VM $gpa)
	# echo_log "[$TARGETGPA] [$TARGETHPA] [$currenthpa]"
	if [ ! "$currenthpa" ] ; then
		count_failure "Fail to get HPA after migration."
	elif [ "$oldhpa" = "$currenthpa" ] ; then
		count_failure "page migration failed or not triggered."
	else
		count_success "page $oldhpa was migrated to $currenthpa."
	fi
}

control_mce_kvm() {
	start_guest_memeater || return 1
	sleep 0.2
	echo_log "get_hpa $TARGET_PAGETYPES"
	get_hpa "$TARGET_PAGETYPES" || return 1
	set_return_code "GOT_HPA"
	echo_log "$MCEINJECT -e $ERROR_TYPE -a ${TARGETHPA}"
	$MCEINJECT -e "$ERROR_TYPE" -a "${TARGETHPA}"
	check_guest_state
}

control_mce_kvm_panic() {
	echo_log "start $FUNCNAME"
	start_guest_memeater || return 1
	get_hpa "$TARGET_PAGETYPES" || return 1
	set_return_code "GOT_HPA"
	echo_log "echo 0 > /proc/sys/vm/memory_failure_recovery"
	ssh $VMIP "echo 0 > /proc/sys/vm/memory_failure_recovery"
	$MCEINJECT -e "$ERROR_TYPE" -a "${TARGETHPA}"
	if vm_connectable ; then
		ssh $VMIP "echo 1 > /proc/sys/vm/memory_failure_recovery"
	fi
	check_guest_state
}

check_mce_kvm() {
	check_nr_hwcorrupted
	check_kernel_message "${TARGETHPA}"
	check_kernel_message_nobug
	check_guest_kernel_message "${TARGETGPA}"
}

check_mce_kvm_panic() {
	check_nr_hwcorrupted
	check_kernel_message "${TARGETHPA}"
	check_guest_kernel_message "Kernel panic"
}

check_mce_kvm_soft_offline() {
	check_nr_hwcorrupted
	check_kernel_message_nobug
	check_guest_kernel_message -v "${TARGETGPA}"
	check_page_migrated "$TARGETGPA" "$TARGETHPA"
}

control_mce_kvm_inject_mce_on_qemu_page() {
	local pid=$(cat /var/run/libvirt/qemu/$VM.pid)
	$PAGETYPES -p $pid -Nrl -b lru | grep -v offset > $TMPD/pagetypes.1

	local target=$(tail -n1 $TMPD/pagetypes.1 | cut -f2)
	if [ "$target" ] ; then
		set_return_code GOT_TARGET_PFN
		echo "$MCEINJECT -e $ERROR_TYPE -a 0x$target"
		$MCEINJECT -e $ERROR_TYPE -a 0x$target
	else
		set_return_code NO_TARGET_PFN
	fi

	set_return_code EXIT
}

check_mce_kvm_inject_mce_on_qemu_page() {
	check_kernel_message "${TARGETHPA}"
	check_kernel_message_nobug
}

#
# Default definition. You can overwrite in each recipe
#
_control() {
	control_mce_kvm "$1" "$2"
}

_prepare() {
	prepare_mce_kvm || return 1
}

_cleanup() {
	cleanup_mce_kvm
}

_check() {
	check_mce_kvm
}
