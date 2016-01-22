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
		"after_start")
            kill -SIGUSR1 $pid
            ;;
        "after_access")
			get_mm_stats 1 $pid
            kill -SIGUSR1 $pid
            ;;
        "before_munmap")
			get_mm_stats 2 $pid

			if check_migration_pagemap ; then
				set_return_code MIGRATION_PASSED
			else
				set_return_code MIGRATION_FAILED
			fi

            kill -SIGUSR1 $pid
            ;;
        "before_exit")
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
