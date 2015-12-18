#!/bin/bash

# requires numactl package

. $TCDIR/lib/mm.sh
. $TCDIR/lib/numa.sh
. $TCDIR/lib/setup_hugetlb_base.sh
. $TCDIR/lib/setup_mce_tools.sh

prepare_hugepage_migration() {
	if [ "$NUMA_NODE" ] ; then
		numa_check || return 1
	fi

	if [ "$HUGETLB" ] ; then
		hugetlb_support_check || return 1
		if [ "$HUGEPAGESIZE" ] ; then
			hugepage_size_support_check || return 1
		fi
		set_and_check_hugetlb_pool $HUGETLB || return 1
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

	# TODO: better location?
	all_unpoison
	ipcrm --all > /dev/null 2>&1

	if [ "$RESERVE_HUGEPAGE" ] ; then
		$hog_hugepages -m private -n $RESERVE_HUGEPAGE -r &
		set_return_code RESERVE
		sleep 1 # TODO: properly wait for reserve completion
	fi

	if [ "$ALLOCATE_HUGEPAGE" ] ; then
		$hog_hugepages -m private -n $ALLOCATE_HUGEPAGE -N $ALLOCATE_NODE &
		set_return_code ALLOCATE
		sleep 1 # TODO: properly wait for reserve completion
	fi

	if [ "$MIGRATE_TYPE" = hotremove ] ; then
		reonline_memblocks
	fi

	if [ "$CGROUP" ] ; then
		cgdelete $CGROUP 2> /dev/null
		cgcreate -g $CGROUP || return 1
		echo 1 > $MEMCGDIR/test1/memory.move_charge_at_immigrate || return 1
	fi

	return 0
}

cleanup_hugepage_migration() {
	# TODO: better location?
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

	if [ "$MIGRATE_TYPE" = hotremove ] ; then
		reonline_memblocks
	fi

	if [ "$CGROUP" ] ; then
		cgdelete $CGROUP 2> /dev/null
	fi
}

check_hugepage_migration() {
	# migration from madv_soft allows page migration within the same node,
	# so it's meaningless to compare node statistics.
	if [[ "$EXPECTED_RETURN_CODE" =~ " MIGRATION_PASSED" ]] && \
		   [ -s $TMPD/numa_maps2 ] && [ "$MIGRATE_SRC" != "madv_soft" ] ; then
		check_numa_maps
	fi

	if [ "$CGROUP" ] && [ -s $TMPD/memcg2 ] ; then
		# TODO: meaningful check/
		diff -u $TMPD/memcg0 $TMPD/memcg1
		diff -u $TMPD/memcg1 $TMPD/memcg2
	fi
}

check_numa_maps() {
    local map1="$(grep " huge " $TMPD/numa_maps1 | sed -r 's/.* (N[0-9]*=[0-9]*).*/\1/g' | tr '\n' ' ')"
    local map2="$(grep " huge " $TMPD/numa_maps2 | sed -r 's/.* (N[0-9]*=[0-9]*).*/\1/g' | tr '\n' ' ')"

    count_testcount "CHECK /proc/pid/numa_maps"
    if [ "$map1" == "$map2" ] ; then
        count_failure "hugepage is not migrated ($map1, $map2)"
    else
        count_success "hugepage is migrated. ($map1 -> $map2)"
    fi
}

control_hugepage_migration() {
    local pid="$1"
    local line="$2"

	if [ "$pid" ] ; then # sync mode
		echo_log "$line"
		case "$line" in
			"just started")
				# TODO: Need better data output
				get_numa_maps $pid | grep 700000
				grep ^Huge /proc/meminfo
				cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/free_hugepages
				cat /sys/devices/system/node/node1/hugepages/hugepages-2048kB/free_hugepages

				if [ "$CGROUP" ] ; then
					cgclassify -g $CGROUP $pid
					cgget -g $CGROUP > $TMPD/memcg0
				fi

				kill -SIGUSR1 $pid
				;;
			"page_fault_done")
				grep ^Huge /proc/meminfo
				get_numa_maps $pid | tee $TMPD/numa_maps1 | grep ^700000
				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -Nrl | grep -v offset | tee $TMPD/pagetypes1 | head
				cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/free_hugepages
				cat /sys/devices/system/node/node1/hugepages/hugepages-2048kB/free_hugepages
				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -NrL | grep -v offset | cut -f1,2 > $TMPD/mig1
				kill -SIGUSR1 $pid
				;;
			"entering busy loop")
				# sysctl -a | grep huge

				if [ "$CGROUP" ] ; then
					cgget -g $CGROUP > $TMPD/memcg1
				fi

				# check migration pass/fail now.
				if [ "$MIGRATE_SRC" = migratepages ] ; then
					echo "do migratepages"
					do_migratepages $pid
					# if [ $? -ne 0 ] ; then
					# 	set_return_code MIGRATEPAGES_FAILED
					# else
					# 	set_return_code MIGRATEPAGES_PASSED
					# fi
					sleep 1
				fi

				if [ "$MIGRATE_SRC" = hotremove ] ; then
					echo_log "do memory hotplug ($(cat $TMPD/preferred_memblk))"
					echo_log "echo offline > /sys/devices/system/memory/memory$(cat $TMPD/preferred_memblk)/state"
					echo offline > /sys/devices/system/memory/memory$(cat $TMPD/preferred_memblk)/state
					if [ $? -ne 0 ] ; then
						set_return_code MEMHOTREMOVE_FAILED
						echo_log "do_memory_hotremove failed."
					fi
				fi

				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -NrL | grep -v offset | cut -f1,2 > $TMPD/mig2
				# count diff stats
				diff -u0 $TMPD/mig1 $TMPD/mig2 > $TMPD/mig3
				diffsize=$(grep -c -e ^+ -e ^- $TMPD/mig3)
				if [ "$diffsize" -eq 0 ] ; then
					set_return_code MIGRATION_FAILED
					echo "do_migratepages failed."
				else
					echo "pfn/vaddr shows $diffsize diff lines"
					set_return_code MIGRATION_PASSED
				fi

				kill -SIGUSR2 $pid
				;;
			"exited busy loop")
				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -Nrl | grep -v offset | tee $TMPD/pagetypes2 | head
				get_numa_maps $pid   > $TMPD/numa_maps2

				if [ "$CGROUP" ] ; then
					cgget -g $CGROUP > $TMPD/memcg2
				fi
				kill -SIGUSR1 $pid
				set_return_code EXIT
				return 0
				;;
			"mbind failed")
				# TODO: how to handle returncode?
				# set_return_code MBIND_FAILED
				kill -SIGUSR1 $pid
				;;
			"move_pages failed")
				# TODO: how to handle returncode?
				# set_return_code MOVE_PAGES_FAILED
				kill -SIGUSR1 $pid
				;;
			"madvise(MADV_SOFT_OFFLINE) failed")
				kill -SIGUSR1 $pid
				;;
			"before memory_hotremove"* )
				echo $line | sed "s/before memory_hotremove: *//" > $TMPD/preferred_memblk
				echo_log "preferred memory block: $targetmemblk"
				$PAGETYPES -rNl -p ${pid} -b huge,compound_head=huge,compound_head > $TMPD/pagetypes1 | head
				grep -i huge /proc/meminfo
				# find /sys -type f | grep hugepage | grep node | grep 2048
				# find /sys -type f | grep hugepage | grep node | grep 2048 | xargs cat
				get_numa_maps ${pid} | tee -a $OFILE > $TMPD/numa_maps1
				kill -SIGUSR1 $pid
				;;
			"need unpoison")
				$PAGETYPES -b hwpoison,huge,compound_head=hwpoison,huge,compound_head -x -N | head
				kill -SIGUSR2 $pid
				;;
			"start background migration")
				run_background_migration $pid &
				BG_MIGRATION_PID=$!
				kill -SIGUSR2 $pid
				;;
			"exit")
				kill -SIGUSR1 $pid
				kill -SIGKILL "$BG_MIGRATION_PID"
				set_return_code EXIT
				return 0
				;;
			*)
				;;
		esac
		return 1
	else # async mode
		true
	fi
}

run_background_migration() {
    local tp_pid=$1
    while true ; do
        echo migratepages $tp_pid 0 1 >> $TMPD/run_background_migration
        migratepages $tp_pid 0 1 2> /dev/null
        get_numa_maps $tp_pid    2> /dev/null | grep " huge " >> $TMPD/run_background_migration
        grep HugeP /proc/meminfo >> $TMPD/run_background_migration
        echo migratepages $tp_pid 1 0 >> $TMPD/run_background_migration
        migratepages $tp_pid 1 0 2> /dev/null
        get_numa_maps $tp_pid    2> /dev/null | grep " huge " >> $TMPD/run_background_migration
        grep HugeP /proc/meminfo >> $TMPD/run_background_migration
    done
}

_control() {
	control_hugepage_migration "$1" "$2"
}

_prepare() {
	prepare_hugepage_migration || return 1
}

_cleanup() {
	cleanup_hugepage_migration
}

_check() {
	check_hugepage_migration
}
