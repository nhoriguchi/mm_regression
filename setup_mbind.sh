#!/bin/bash

. $TCDIR/lib/mm.sh

_control() { control_mbind "$1" "$2"; }
_prepare() { prepare_mbind; }
_cleanup() { cleanup_mbind; }

prepare_mbind() {
	prepare_mm_generic || return 1
}

cleanup_mbind() {
	cleanup_mm_generic
}

control_mbind() {
    local pid="$1"
    local line="$2"

    echo_log "$line"
    case "$line" in
		"just started")
            kill -SIGUSR1 $pid
            ;;
        "page_fault_done")
			get_mm_stats $pid 1
            kill -SIGUSR1 $pid
            ;;
        "before_free")
			get_mm_stats $pid 2

			if check_migration_pagemap ; then
				set_return_code MIGRATION_PASSED
			else
				set_return_code MIGRATION_FAILED
			fi

			check_migration_hugeness
			ret=$?
			if [ "$ret" == 0 ] ; then
				set_return_code HUGEPAGE_MIGRATED
			elif [ "$ret" == 1 ] ; then
				set_return_code HUGEPAGE_NOT_MIGRATED
			elif [ "$ret" == 2 ] ; then
				set_return_code HUGEPAGE_DISAPPEARED
			elif [ "$ret" == 3 ] ; then
				set_return_code HUGEPAGE_NOT_EXIST
			fi

            kill -SIGUSR1 $pid
            ;;
        "just before exit")
            kill -SIGUSR1 $pid
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_migration_pagemap() {
	diff -u1000000 $TMPD/.mig.1 $TMPD/.mig.2 > $TMPD/.mig.diff
	local before=$(grep "^-" $TMPD/.mig.diff | wc -l)
	local after=$(grep "^+" $TMPD/.mig.diff | wc -l)
	local unchange=$(grep "^ " $TMPD/.mig.diff | wc -l)

	echo_log "check pagemap"
	if [ "$before" -gt 0 ] && [ "$after" -gt 0 ] ; then
		if [ "$unchange" -ne 0 ] ; then
			echo_log "some pages migrated ($unchange pages failed)"
		else
			echo_log "all pages migrated"
		fi
		return 0
	else
		echo_log "no page migrated"
		return 1
	fi
}

# TODO: check with vmstat value
control_mbind_fuzz() {
    echo_log "start mbind_$FLAVOR"
    for i in $(seq $MBIND_FUZZ_THREADS) ; do
		$FUZZ_CMD > $TMPD/fuz.out 2>&1 &
    done

    echo_log "... (running $MBIND_FUZZ_DURATION secs)"
    sleep $MBIND_FUZZ_DURATION
    echo_log "Done, kill the processes"
    pkill -SIGUSR1 -f $test_alloc_generic
    set_return_code EXIT
}
