#!/bin/bash

. $TRDIR/lib/mm.sh

set_monarch_timeout() {
    local value=$1

	[ ! "$value" ] && return

    find $SYSFS_MCHECK/ -type f -name monarch_timeout | while read line ; do
        echo $value > $line
    done
}

prepare_mce_test() {
	echo "[temporarily] check_mce_capability is skipped due to test code bug"
	# check_mce_capability || return 1 # MCE SRAO not supported
	prepare_mm_generic || return 1

	if [ "$MONARCH_TIMEOUT" ] ; then
		set_monarch_timeout $MONARCH_TIMEOUT
	fi

	# background memory accessor
	test_allocate_generic -B anonymous -N 1000 -L "mmap access busyloop" > /dev/null 2>&1 &

	save_nr_corrupted_before

	echo 1 > $DEBUGFSDIR/mce/fake_panic
}

cleanup_mce_test() {
	echo 0 > $DEBUGFSDIR/mce/fake_panic

	# This chech is only meaningful only if test programs are run in sync mode.
	if [ "$TEST_PROGRAM" ] ; then
		save_nr_corrupted_inject
	fi

	cleanup_mm_generic

	if [ "$DEFAULT_MONARCH_TIMEOUT" ] ; then
		set_monarch_timeout $DEFAULT_MONARCH_TIMEOUT
	fi

	# cleanup routine must make sure all corrupted pages are unpoisoned
    save_nr_corrupted_unpoison
}

check_mce_test() {
	check_nr_hwcorrupted

	if [ "$BACKEND" = ksm ] ; then
		check_console_output -v "can't handle KSM pages"
	fi

	if [ "$BACKEND" = huge_zero ] ; then
		check_console_output -v "non anonymous thp"
		check_console_output -v "recovery action for high-order kernel page: Ignored"
	fi
}

BASEVFN=0x700000000

control_mce_test() {
    local pid="$1"
    local line="$2"

	if [ "$pid" ] ; then # sync mode
		echo_log "=> $line"
		case "$line" in
			"after_start")
				kill -SIGUSR1 $pid
				;;
			"after_access")
				show_hugetlb_pool > $TMPD/hugetlb_pool.1
				get_numa_maps $pid > $TMPD/numa_maps.1
				get_smaps_block $pid smaps.1 700000 > /dev/null
				get_pagetypes $pid pagetypes.1 -Nrla 0x700000000+0x10000000
				get_pagemap $pid mig.1 -NrLa 0x700000000+0x10000000 > /dev/null
				cp /proc/vmstat $TMPD/vmstat.1

				kill -SIGUSR1 $pid
				;;
			"before_munmap") # dup with "exited busy loop"?
				show_hugetlb_pool > $TMPD/hugetlb_pool.2
				get_numa_maps $pid > $TMPD/numa_maps.2
				get_smaps_block $pid smaps.2 700000 > /dev/null
				get_pagetypes $pid pagetypes.2 -Nrla 0x700000000+0x10000000
				get_pagemap $pid mig.2 -NrLa 0x700000000+0x10000000 > /dev/null
				cp /proc/vmstat $TMPD/vmstat.2

				kill -SIGUSR1 $pid
				;;
			"before_exit")
				kill -SIGUSR1 $pid
				set_return_code EXIT
				return 0
				;;
			"waiting for injection from outside")

				[ ! "$ERROR_OFFSET" ] && ERROR_OFFSET=0
				echo_log "$MCEINJECT -p $pid -e $ERROR_TYPE -a $[BASEVFN + ERROR_OFFSET]"
				$MCEINJECT -p $pid -e $ERROR_TYPE -a $[BASEVFN + ERROR_OFFSET]
				if check_process_status $pid ; then
					set_return_code INJECT
				else
					set_return_code KILLED_IN_INJECTION
					return 0
				fi
				kill -SIGUSR1 $pid
				;;
			"after madvise injection")
				# TODO: return value?
				if check_process_status $pid ; then
					set_return_code INJECT
				else
					set_return_code KILLED_IN_INJECTION
					return 0
				fi
				sleep 0.3
				kill -SIGUSR1 $pid
				;;
			"writing affected region")
				set_return_code ACCESS
				kill -SIGUSR1 $pid
				# need to wait for the process is completely killed.
				# surprisingly it might take more than 1 sec... :(
				sleep 2

				if check_process_status $pid ; then
					set_return_code ACCESS_SUCCEEDED
				else
					set_return_code KILLED_IN_ACCESS
					return 0
				fi
				;;
			"do_multi_backend_busyloop")
				# TODO: better flag
				if [ "$MULTIINJ_ITERATIONS" ] ; then
					echo "do_multi_inject"
					do_multi_inject $pid
				fi
				set_return_code EXIT
				kill -SIGUSR1 $pid
				return 0
				;;
			*)
				;;
		esac
		return 1
	fi
}

do_multi_inject() {
	local pid=$1
	echo_log "multi injection for target page $TARGET_PAGEFLAG"
	echo "page-types -p $pid -b $TARGET_PAGEFLAG -rNl -a $BASEVFN,"
	local target=$(page-types -p $pid -b $TARGET_PAGEFLAG -rNl -a $BASEVFN, | grep -v X | grep -v offset | head -n1 | cut -f2)
	page-types -p $pid -b $TARGET_PAGEFLAG -rNl -a $BASEVFN, | grep -v X | head -n10
	if [ ! "$target" ] ; then
		echo "No page with $TARGET_PAGEFLAG found"
        set_return_code TARGET_NOT_FOUND
		return
	fi

	touch $TMPD/sync

    local i=
    for i in $(seq $NR_THREAD) ; do
        if [ "$INJECT_TYPE" == mce-srao ] || [ "$INJECT_TYPE" == hard-offline ] || [ "$INJECT_TYPE" == soft-offline ] ; then
            injtype=$INJECT_TYPE
        elif [ "$INJECT_TYPE" == hard-soft ] ; then
            if [ "$[$i % 2]" == "0" ] ; then
                injtype=hard-offline
            else
                injtype=soft-offline
            fi
        else
            echo "Invalid INJECT_TYPE"
            set_return_code INVALID_INJECT_TYPE
            return 1
        fi

		# echo "Start injection thread $i"
		if [ "$DIFFERENT_PFNS" == true ] ; then
			# echo_log "$MCEINJECT -e $injtype -a $[0x$target + i]"
			( while [ -e $TMPD/sync ] ; do true ; done ; $MCEINJECT -e $injtype -a $[0x$target + i] > /dev/null ) &
		else
			# echo_log "$MCEINJECT -e $injtype -a 0x$target"
			( while [ -e $TMPD/sync ] ; do true ; done ; $MCEINJECT -e $injtype -a 0x$target > /dev/null ) &
		fi
        # echo_log $!
    done

	echo -n "ready ... "
	sleep 1
	echo "go!"
    rm $TMPD/sync
    sleep 1
}

#
# Default definition. You can overwrite in each recipe
#
_control() {
	control_mce_test "$1" "$2"
}

_prepare() {
	prepare_mce_test || return 1
}

_cleanup() {
	cleanup_mce_test
}

_check() {
	check_mce_test
}
