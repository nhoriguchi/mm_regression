. $TRDIR/setup_mmgeneric.sh
. $TRDIR/setup_hugepage_migration.sh

THP=true
NUMA_NODE=2

_prepare() {
	prepare_mmgeneric || return 1
}

_cleanup() {
	cleanup_mmgeneric || return 1
}

_control() {
    local pid="$1"
    local line="$2"

    echo_log "$line"
    case "$line" in
		"after_access")
			# get_mm_stats 0 $pid $(pgrep -P $pid)
            kill -SIGUSR1 $pid
            ;;
        "after_fork")
			echo $pid > $TMPD/pid.parent
			pgrep -P $pid > $TMPD/pid.child
			# get_mm_stats 1 $pid $(pgrep -P $pid) > /dev/null

            kill -SIGUSR1 $pid
            ;;
        "before_munmap")
			get_mm_stats 3 $pid $(pgrep -P $pid) > /dev/null

			if [ "$SHMEM_DIR" ] ; then
				$PAGETYPES -f $SHMEM_DIR/testfile -rlN > $TMPD/shmem.pagemap.3
			fi

			if [ "$SHMEM_DIR" ] ; then
				check_migration_done $TMPD/shmem.pagemap.2 $TMPD/shmem.pagemap.3
			elif [ "$FORK" ] ; then
				check_migration_done $TMPD/pagetypes.2.$pid $TMPD/pagetypes.3.$pid
			else
				check_migration_done $TMPD/pagetypes.2 $TMPD/pagetypes.3
			fi

            kill -SIGUSR1 $pid
            ;;
        "after_noop")
			get_mm_stats 2 $pid $(pgrep -P $pid) > /dev/null

			if [ "$SHMEM_DIR" ] ; then
				$PAGETYPES -f $SHMEM_DIR/testfile -rlN > $TMPD/shmem.pagemap.2
			fi

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
		"waiting for memory_hotremove"*)
			echo $line | sed "s/waiting for memory_hotremove: *//" > $TMPD/preferred_memblk
			MEMBLK_SIZE=0x$(cat /sys/devices/system/memory/block_size_bytes)
			MEMBLK_SIZE=$[MEMBLK_SIZE / 4096]

			targetmemblk=$(cat $TMPD/preferred_memblk)
			echo_log "preferred memory block: $targetmemblk"
			echo_log "echo offline > /sys/devices/system/memory/memory$targetmemblk/state"

			echo offline > /sys/devices/system/memory/memory$targetmemblk/state
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
