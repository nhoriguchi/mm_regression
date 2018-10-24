. $TRDIR/lib/setup_mmgeneric.sh

THP=true

_prepare() {
	true
}

_cleanup() {
	[[ "$(jobs -p)" ]] || kill -9 $(jobs -p)
	cleanup_system_default
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

			# if [ "$FORK" ] ; then
			# 	check_migration_done $TMPD/pagetypes.2.$pid $TMPD/pagetypes.3.$pid
			# else
			# 	check_migration_done $TMPD/pagetypes.2 $TMPD/pagetypes.3
			# fi

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
        *)
            ;;
    esac
    return 1
}

_check() {
	true
}
