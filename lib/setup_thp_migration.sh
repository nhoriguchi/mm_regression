. $TRDIR/lib/setup_mmgeneric.sh
. $TRDIR/lib/setup_page_migration.sh

THP=always
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
			get_mm_stats 0 $pid $(pgrep -P $pid) > /dev/null

			if [ "$SHMEM_DIR" ] ; then
				page-types -f $SHMEM_DIR/testfile -rlN | grep ___ > $TMPD/shmem.pagemap.0
			fi

            kill -SIGUSR1 $pid
            ;;
        "after_fork")
			echo $pid > $TMPD/pid.parent
			pgrep -P $pid > $TMPD/pid.child
			get_mm_stats 1 $pid $(pgrep -P $pid) > /dev/null

            kill -SIGUSR1 $pid
            ;;
        "before_munmap")
			get_mm_stats 3 $pid $(pgrep -P $pid) > /dev/null

			if [ "$SHMEM_DIR" ] ; then
				# '-f' provides some file metadata, so need to filter with '___'
				# echo page-types -f $SHMEM_DIR/testfile -rlN
				# page-types -f $SHMEM_DIR/testfile -rlN
				page-types -f $SHMEM_DIR/testfile -rlN | grep ___ > $TMPD/shmem.pagemap.3
			fi

			if [ "$SHMEM_DIR" ] ; then
				check_migration_done $TMPD/shmem.pagemap.0 $TMPD/shmem.pagemap.3
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
				page-types -f $SHMEM_DIR/testfile -rlN | grep ___ > $TMPD/shmem.pagemap.2
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
			sleep 1 # need to finish migration
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
			if [ $? -eq 0 ] ; then
				set_return_code OFFLINE_SUCCEEDED
			else
				set_return_code OFFLINE_FAILED
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

check_thp_migration() {
	local before=$1
	local after=$2

	grep _t_ $before | cut -f1,2 > $TMPD/.pagetypes.huge.before
	grep _t_ $after  | cut -f1,2 > $TMPD/.pagetypes.huge.after

	if [ -s $TMPD/.pagetypes.huge.after ] ; then # thp exists before migration
		if diff -q $TMPD/.pagetypes.huge.before $TMPD/.pagetypes.huge.after > /dev/null ; then
			set_return_code HUGEPAGE_NOT_MIGRATED
		elif [ -s $TMPD/.pagetypes.huge.after ] ; then
			set_return_code HUGEPAGE_MIGRATED
		else
			set_return_code HUGEPAGE_SPLIT
		fi
	else
		if diff -q <(cut -f1,2 $before) <(cut -f1,2 $after) > /dev/null ; then
			set_return_code PAGE_NOT_MIGRATED
		elif [ -s $TMPD/.pagetypes.huge.after ] ; then
			set_return_code HUGEPAGE_CREATED
		else
			set_return_code PAGE_MIGRATED
		fi
	fi
}

control_split_retry() {
	local pid=$1

	pgrep -f test_alloc_generic > $TMPD/pids

	if read -t60 line <> $TMPD/.tmp_pipe ; then
		get_mm_stats 0 $pid > /dev/null
		echo "1 after_access"

		kill -SIGUSR1 $pid
		sleep 0.1
		grep ^700000000 /proc/$pid/numa_maps
		head -n5 $TMPD/pagetypes.0 | sed "s/^/[$pid] /"
	else
		return 1
	fi

	if [ "$FORK" ] ; then
		if read -t60 line <> $TMPD/.tmp_pipe ; then
			echo "1.5 after_fork"

			pgrep -f test_alloc_generic > $TMPD/pids

			for p in $(cat $TMPD/pids) ; do
				page-types -p $p -rlN -a 0x700000000+0x10000000 | grep -v offset > $TMPD/pagetypes.1.$p
				head -n5 $TMPD/pagetypes.1.$p | sed "s/^/[$p] /"
			done

			kill -SIGUSR1 $pid
		else
			return 1
		fi
	fi

	echo "PIDs: $(cat $TMPD/pids | tr '\n' ' ')"

	if read -t60 line <> $TMPD/.tmp_pipe ; then
		get_mm_stats 2 $pid $(pgrep -P $pid) > /dev/null
		echo "2 after_noop"

		for p in $(cat $TMPD/pids) ; do
			page-types -p $p -rlN -a 0x700000000+0x10000000 | grep -v offset > $TMPD/pagetypes.2.$p
			echo "--- num_maps of PID:$p"
			grep ^700000000 /proc/$p/numa_maps
			head -n5 $TMPD/pagetypes.2.$p | sed "s/^/[$p] /"
		done

		kill -SIGUSR1 $pid
	else
		return 1
	fi
	grep ^700000000 /proc/$pid/numa_maps

	if read -t60 line <> $TMPD/.tmp_pipe ; then
		get_mm_stats 3 $pid $(pgrep -P $pid) > /dev/null
		echo "3 before_munmap"
		for p in $(cat $TMPD/pids) ; do
			page-types -p $p -rlN -a 0x700000000+0x10000000 | grep -v offset > $TMPD/pagetypes.3.$p
			grep ^700000000 /proc/$p/numa_maps
			check_thp_migration $TMPD/pagetypes.2.$p $TMPD/pagetypes.3.$p
			head -n5 $TMPD/pagetypes.3.$p | sed "s/^/[$p] /"
		done

		kill -SIGUSR1 $pid
	else
		return 1
	fi

	set_return_code EXIT
}
