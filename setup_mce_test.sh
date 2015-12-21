#!/bin/bash

. $TCDIR/lib/mm.sh
. $TCDIR/lib/numa.sh
. $TCDIR/lib/mce.sh
. $TCDIR/lib/hugetlb.sh
. $TCDIR/lib/thp.sh
. $TCDIR/lib/ksm.sh

set_monarch_timeout() {
    local value=$1

	[ ! "$value" ] && return

    find $SYSFS_MCHECK/ -type f -name monarch_timeout | while read line ; do
        echo $value > $line
    done
}

prepare_mce_test() {
	if [ "$ERROR_TYPE" = mce-srao ] ; then
        check_mce_capability || return 1 # MCE SRAO not supported
		check_mce_capability
		echo "returned $?"
	fi

	if [ "$NUMA_NODE" ] ; then
		numa_check || return 1
	fi

	if [ "$HUGETLB" ] ; then
		hugetlb_support_check || return 1
		if [ "$HUGEPAGESIZE" ] ; then
			hugepage_size_support_check || return 1
		fi
		set_and_check_hugetlb_pool $HUGETLB || echo "### Hugetlb pool might not clean, be careful! ###"
	fi

	if [ "$HUGETLB_MOUNT" ] ; then # && [ "$HUGETLB_FILE" ] ; then
		rm -rf $HUGETLB_MOUNT/* > /dev/null 2>&1
		umount -f $HUGETLB_MOUNT > /dev/null 2>&1
		mkdir -p $HUGETLB_MOUNT > /dev/null 2>&1
		mount -t hugetlbfs none $HUGETLB_MOUNT || return 1
	fi

	if [ "$HUGETLB_OVERCOMMIT" ] ; then
		set_hugetlb_overcommit $HUGETLB_OVERCOMMIT
		set_return_code SET_OVERCOMMIT
	fi

	if [ "$THP" ] ; then
		# TODO: how can we make sure that there's no thp on the test system?
		set_thp_params_for_testing
		set_thp_madvise
		show_stat_thp
	fi

	if [ "$BACKEND" = ksm ] ; then
		ksm_on
		show_ksm_params | tee $TMPD/ksm_params1
	fi

	if [ "$MEMORY_HOTREMOVE" ] ; then
		reonline_memblocks
	fi

	if [ "$TESTFILE" ] && [ "$FILESIZE" ] ; then
		local f
		for f in $TESTFILE ; do
			dd if=/dev/zero of=$f bs=$FILESIZE count=1
		done
	fi

	if [ "$MONARCH_TIMEOUT" ] ; then
		set_monarch_timeout $MONARCH_TIMEOUT
	fi

	# TODO: better location?
	all_unpoison
	ipcrm --all > /dev/null 2>&1
    save_nr_corrupted_before
}

cleanup_mce_test() {
	# TODO: better location?
    save_nr_corrupted_inject
	all_unpoison
	ipcrm --all > /dev/null 2>&1

	if [ "$HUGETLB_MOUNT" ] ; then
		rm -rf $HUGETLB_MOUNT/* 2>&1 > /dev/null
		umount -f $HUGETLB_MOUNT 2>&1 > /dev/null
	fi

	if [ "$HUGETLB" ] ; then
		set_and_check_hugetlb_pool 0
	fi

	if [ "$HUGETLB_OVERCOMMIT" ] ; then
		set_hugetlb_overcommit 0
	fi

	if [ "$THP" ] ; then
		default_tuning_parameters
		show_stat_thp
	fi

	if [ "$BACKEND" = ksm ] ; then
		show_ksm_params | tee $TMPD/ksm_params2
		ksm_off
	fi

	if [ "$MEMORY_HOTREMOVE" ] ; then
		reonline_memblocks
	fi

	if [ "$TESTFILE" ] && [ "$FILESIZE" ] ; then
		local f
		for f in $TESTFILE ; do
			rm -f $f
		done
	fi

	if [ -f $WDIR/testfile ] ; then
		rm -f $WDIR/testfile*
	fi

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
			"waiting for injection from outside")
				$PAGETYPES -p $pid -rlN -a $BASEVFN+1310720 | tee $TMPD/pageflagcheck1 | head -n10

				if [ "$HUGETLB" ] ; then
					$PAGETYPES -p $pid -a $BASEVFN | grep huge > /dev/null 2>&1
					if [ $? -ne 0 ] ; then
						echo_log "Target address is NOT hugepage."
						set_return_code HUGEPAGE_ALLOC_FAILURE
						kill -SIGKILL $pid
						return 0
					fi
				fi

				if [ "$THP" ] ; then
					$PAGETYPES -p $pid -a $BASEVFN | grep thp > /dev/null 2>&1
					if [ $? -ne 0 ] ; then
						echo_log "Target address is NOT thp."
						set_return_code THP_ALLOC_FAILURE
						kill -SIGKILL $pid
						return 0
					fi
				fi

				if [ "$BACKEND" = zero ] && [ "$BACKEND" = huge_zero ] ; then
					$PAGETYPES -p $pid -a $BASEVFN | grep zero # > /dev/null 2>&1
					if [ $? -ne 0 ] ; then
						echo_log "Target address is NOT zero/huge_zero."
						set_return_code ZERO_PAGE_ALLOC_FAILURE
						kill -SIGKILL $pid
						return 0
					fi
				fi

				[ ! "$ERROR_OFFSET" ] && ERROR_OFFSET=0
				# cat /proc/$pid/numa_maps | tee -a ${OFILE}
				printf "Inject MCE ($ERROR_TYPE) to %lx.\n" $[BASEVFN + ERROR_OFFSET] | tee -a $OFILE >&2
				echo "$MCEINJECT -p $pid -e $ERROR_TYPE -a $[BASEVFN + ERROR_OFFSET]" # 2>&1
				$MCEINJECT -p $pid -e $ERROR_TYPE -a $[BASEVFN + ERROR_OFFSET] # 2>&1
				# /* TODO: return value? */
				$PAGETYPES -p $pid -rlN -a $BASEVFN+1310720 | head
				ps ax | grep $pid
				if ! kill -0 $pid 2> /dev/null ; then
					set_return_code KILLED_IN_INJECTION
					return 0
				else
					set_return_code INJECT
				fi
				kill -SIGUSR1 $pid
				;;
			"error injection with madvise")
				# tell cmd the page offset into which error is injected
				$PAGETYPES -p $pid -rlN -a $BASEVFN+1310720 | tee $TMPD/pageflagcheck1 | head
				echo $ERROR_OFFSET > $PIPE
				kill -SIGUSR1 $pid
				;;
			"after madvise injection")
				# TODO: return value?
				if ! kill -0 $pid 2> /dev/null ; then
					set_return_code KILLED_IN_INJECTION
					return 0
				else
					set_return_code INJECT
				fi
				kill -SIGUSR1 $pid
				;;
			"writing affected region")
				set_return_code "ACCESS"
				kill -SIGUSR1 $pid
				sleep 1
				if ! kill -0 $pid 2> /dev/null ; then
					set_return_code KILLED_IN_ACCESS
					return 0
				else
					set_return_code ACCESS_SUCCEEDED
				fi
				;;
			"memory_error_injection_done")
				$PAGETYPES -p $pid -rlN -a $BASEVFN+1310720 | tee $TMPD/pageflagcheck2 | head
				kill -SIGUSR1 $pid
				set_return_code "EXIT"
				return 0
				;;
			"do_multi_backend_busyloop")
				# TODO: better flag
				if [ "$MULTIINJ_ITERATIONS" ] ; then
					echo "do_multi_inject"
					do_multi_inject
				fi
				kill -SIGUSR1 $pid
				;;
			*)
				;;
		esac
		return 1
	fi
}

do_multi_inject() {
	local target=$($PAGETYPES -b $TARGET_PAGEFLAG -rNl | grep -v X | grep -v offset | head -n1 | cut -f1)
	$PAGETYPES -b $TARGET_PAGEFLAG -rNl | grep -v X | head -n10
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
		if [ "$DIFFERENT_PFNS" == true ] ; then
			# echo_log "$MCEINJECT -e $injtype -a $[0x$target + i]"
			( while [ -e $TMPD/sync ] ; do true ; done ; $MCEINJECT -e $injtype -a $[0x$target + i] > /dev/null ) &
		else
			# echo_log "$MCEINJECT -e $injtype -a 0x$target"
			( while [ -e $TMPD/sync ] ; do true ; done ; $MCEINJECT -e $injtype -a 0x$target > /dev/null ) &
		fi
        # echo_log $!
    done

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
