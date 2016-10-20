. $TRDIR/setup_mmgeneric.sh

THP=true

_prepare() {
	true
}

_cleanup() {
	[[ "$(jobs -p)" ]] || kill -9 $(jobs -p)
	cleanup_system_default
}

check_migration_pagemap() {
	local before=$1
	local after=$2

	diff -u1000000 $before $after > $TMPD/.mig.diff
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

check_migration_hugeness() {
	local before=$1
	local after=$2

	grep -e H_ -e _T $before | cut -f1,2 > $TMPD/.pagetypes.huge.1
	grep -e H_ -e _T $after  | cut -f1,2 > $TMPD/.pagetypes.huge.2
	diff -u1000000 $TMPD/.pagetypes.huge.1 $TMPD/.pagetypes.huge.2 > $TMPD/.pagetypes.huge.diff
	local before=$(grep "^-" $TMPD/.pagetypes.huge.diff | wc -l)
	local after=$(grep "^+" $TMPD/.pagetypes.huge.diff | wc -l)
	local unchange=$(grep "^ " $TMPD/.pagetypes.huge.diff | wc -l)

	echo_log "check hugepage migration"
	if [ ! -s $TMPD/.pagetypes.huge.1 ] ; then
		echo_log "no hugepage"
		return 3
	elif [ ! -s $TMPD/.pagetypes.huge.2 ] ; then
		echo_log "hugepage disappeared (maybe split?)"
		return 2
	elif [ "$before" -gt 0 ] && [ "$after" -gt 0 ] ; then
		if [ "$unchange" -ne 0 ] ; then
			echo_log "some hugepages migrated ($unchange hugepages failed)"
		else
			echo_log "all hugepages migrated"
		fi
		return 0
	else
		echo_log "no hugepage migrated"
		return 1
	fi
}

# assume before/after migration data is taken by "get_mm_stats 1 $pid"
# and "get_mm_stats 2 $pid"
check_migration_done() {
	local before=$1
	local after=$2

	if check_migration_pagemap $before $after ; then
		set_return_code MIGRATION_PASSED
	else
		set_return_code MIGRATION_FAILED
	fi
	check_migration_hugeness $before $after
	local ret=$?
	if [ "$ret" == 0 ] ; then
		set_return_code HUGEPAGE_MIGRATED
	elif [ "$ret" == 1 ] ; then
		set_return_code HUGEPAGE_NOT_MIGRATED
	elif [ "$ret" == 2 ] ; then
		set_return_code HUGEPAGE_DISAPPEARED
	elif [ "$ret" == 3 ] ; then
		set_return_code HUGEPAGE_NOT_EXIST
	fi
}

_control() {
    local pid="$1"
    local line="$2"

    echo_log "$line"
    case "$line" in
		"after_access")
			get_mm_stats 0 $pid $(pgrep -P $pid)
            kill -SIGUSR1 $pid
            ;;
        "after_fork")
			echo $pid > $TMPD/pid.parent
			pgrep -P $pid > $TMPD/pid.child
			get_mm_stats 1 $pid $(pgrep -P $pid) > /dev/null
            kill -SIGUSR1 $pid
            ;;
        "before_munmap")
			get_mm_stats 3 $pid $(pgrep -P $pid)

			if [ "$FORK" ] ; then
				check_migration_done $TMPD/pagetypes.2.$pid $TMPD/pagetypes.3.$pid
			else
				check_migration_done $TMPD/pagetypes.2 $TMPD/pagetypes.3
			fi

            kill -SIGUSR1 $pid
            ;;
        "after_noop")
			get_mm_stats 2 $pid $(pgrep -P $pid)
            kill -SIGUSR1 $pid
            ;;
        "before_exit")
            set_return_code "EXIT"
            kill -SIGUSR1 $pid
            return 0
            ;;
		"waiting for injection from outside")
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
		"waiting for migratepages")
			echo "calling do_migratepages for $pid"
			do_migratepages $pid
			kill -SIGUSR1 $pid
			;;
        *)
            ;;
    esac
    return 1
}

_check() {
	true
}
