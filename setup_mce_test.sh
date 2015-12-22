#!/bin/bash

. $TCDIR/lib/mm.sh

set_monarch_timeout() {
    local value=$1

	[ ! "$value" ] && return

    find $SYSFS_MCHECK/ -type f -name monarch_timeout | while read line ; do
        echo $value > $line
    done
}

prepare_mce_test() {
	prepare_mm_generic || return 1

	if [ "$ERROR_TYPE" = mce-srao ] ; then
        check_mce_capability || return 1 # MCE SRAO not supported
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

    save_nr_corrupted_before
}

cleanup_mce_test() {
	# This chech is only meaningful only if test programs are run in sync mode.
	if [ "$TEST_PROGRAM" ] ; then
		save_nr_corrupted_inject
	fi
	cleanup_mm_generic

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
				set_return_code ACCESS
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
				set_return_code EXIT
				return 0
				;;
			"do_multi_backend_busyloop")
				# TODO: better flag
				if [ "$MULTIINJ_ITERATIONS" ] ; then
					echo "do_multi_inject"
					do_multi_inject $pid
				fi
				set_return_code EXIT
				kill -SIGUSR2 $pid
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
	echo "$PAGETYPES -p $pid -b $TARGET_PAGEFLAG -rNl -a $BASEVFN,"
	local target=$($PAGETYPES -p $pid -b $TARGET_PAGEFLAG -rNl -a $BASEVFN, | grep -v X | grep -v offset | head -n1 | cut -f2)
	$PAGETYPES -p $pid -b $TARGET_PAGEFLAG -rNl -a $BASEVFN, | grep -v X | head -n10
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
