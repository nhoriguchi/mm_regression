#!/bin/bash

. $TCDIR/lib/mm.sh

get_vma_protection() { grep -A 2 700000000000 /proc/$pid/maps; }

prepare_hugepage_migration() {
	prepare_mm_generic || return 1

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

	return 0
}

cleanup_hugepage_migration() {
	cleanup_mm_generic

	if [ "$MIGRATE_TYPE" = hotremove ] ; then
		reonline_memblocks
	fi
}

check_hugepage_migration() {
	# migration from madv_soft allows page migration within the same node,
	# so it's meaningless to compare node statistics.
# 	if [ "$HUGETLB" ] && [[ "$EXPECTED_RETURN_CODE" =~ " MIGRATION_PASSED" ]] && \
# 		   [ -s $TMPD/numa_maps.2 ] && [ "$MIGRATE_SRC" != "madv_soft" ] ; then
# 		check_numa_maps
# 	fi

	if [ "$CGROUP" ] && [ -s $TMPD/memcg.2 ] ; then
		# TODO: meaningful check/
		diff -u $TMPD/memcg.0 $TMPD/memcg.1 | grep -e ^+ -e ^-
		diff -u $TMPD/memcg.1 $TMPD/memcg.2 | grep -e ^+ -e ^-
	fi
}

check_migration_pagemap() {
	diff -u1000000 $TMPD/mig.1 $TMPD/mig.2 > $TMPD/mig.diff
	local before=$(grep "^-" $TMPD/mig.diff | wc -l)
	local after=$(grep "^+" $TMPD/mig.diff | wc -l)
	local unchange=$(grep "^ " $TMPD/mig.diff | wc -l)

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
	grep H $TMPD/pagetypes.1 | cut -f1,2 > $TMPD/.pagetypes.huge.1
	grep H $TMPD/pagetypes.2 | cut -f1,2 > $TMPD/.pagetypes.huge.2
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

check_thp_split() {
	local pmd_split_before=$(grep "thp_split_pmd " $TMPD/vmstat.1 | cut -f2 -d' ')
	local pmd_split_after=$(grep "thp_split_pmd " $TMPD/vmstat.2 | cut -f2 -d' ')
	local thp_split_before=$(grep "thp_split_page " $TMPD/vmstat.1 | cut -f2 -d' ')
	local thp_split_after=$(grep "thp_split_page " $TMPD/vmstat.2 | cut -f2 -d' ')

	echo_log "check thp split from /proc/vmstat"
	if [ "$pmd_split_before" -eq "$pmd_split_after"  ] ; then
		echo_log "pmd not split"
		return 2
	elif [ "$thp_split_before" -eq "$thp_split_before" ] ; then
		echo_log "pmd split ($pmd_split_before -> $pmd_split_after)"
		echo_log "thp not split"
		return 1
	else
		echo_log "pmd split ($pmd_split_before -> $pmd_split_after)"
		echo_log "thp split ($thp_split_before -> $thp_split_after)"
		return 0
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
				show_hugetlb_pool > $TMPD/hugetlb_pool.0

				if [ "$CGROUP" ] ; then
					cgclassify -g $CGROUP $pid
					cgget -g $CGROUP > $TMPD/memcg.0
				fi

				kill -SIGUSR1 $pid
				;;
			"page_fault_done")
				show_hugetlb_pool > $TMPD/hugetlb_pool.1
				get_numa_maps $pid > $TMPD/numa_maps.1
				get_smaps_block $pid smaps.1 700000 > /dev/null
				get_pagetypes $pid pagetypes.1 -Nrla 0x700000000+0x10000000
				get_pagemap $pid mig.1 -NrLa 0x700000000+0x10000000 > /dev/null
				cp /proc/vmstat $TMPD/vmstat.1

				# TODO: better condition check
				if [ "$RACE_SRC" == "race_with_gup" ] ; then
					$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
					$PAGETYPES -p $pid -r -b anon | grep total
					ps ax | grep thp
					grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
					( for i in $(seq 10) ; do migratepages $pid 0 1 ; migratepages $pid 1 0 ; done ) &
				fi

				# TODO: better condition check
				if [ "$RACE_SRC" == "race_with_fork" ] ; then
					$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
					$PAGETYPES -p $pid -r -b anon | grep total
					ps ax | grep thp
					grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
					( for i in $(seq 10) ; do migratepages $pid 0 1 ; migratepages $pid 1 0 ; done ) &
				fi

				if [ "$MIGRATE_SRC" = auto_numa ] ; then
					echo "current CPU: $(ps -o psr= $pid)"
					taskset -p $pid
				fi

				# if [ "$MIGRATE_SRC" = change_cpuset ] ; then
				# 	cgclassify -g cpu,cpuset,memory:test1 $pid
				# 	[ $? -eq 0 ] && set_return_code CGCLASSIFY_PASS || set_return_code CGCLASSIFY_FAIL
				# 	echo "cat /sys/fs/cgroup/memory/test1/tasks"
				# 	cat /sys/fs/cgroup/memory/test1/tasks
				# 	ls /sys/fs/cgroup/memory/test1/tasks
				# 	cgget -r cpuset.mems -r cpuset.cpus -r cpuset.memory_migrate test1
				# 	# $PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
				# 	$PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPD/pagetypes1

				# 	cgset -r cpuset.mems=0 test1
				# 	cgset -r cpuset.mems=1 test1
				# 	cgget -r cpuset.mems -r cpuset.cpus -r cpuset.memory_migrate test1
				# fi

				if [ "$CGROUP" ] ; then
					cgget -g $CGROUP > $TMPD/memcg.1
				fi

				kill -SIGUSR1 $pid
				;;
			"before_free") # dup with "exited busy loop"?
				show_hugetlb_pool > $TMPD/hugetlb_pool.2
				get_numa_maps $pid > $TMPD/numa_maps.2
				get_smaps_block $pid smaps.2 700000 > /dev/null
				get_pagetypes $pid pagetypes.2 -Nrla 0x700000000+0x10000000
				get_pagemap $pid mig.2 -NrLa 0x700000000+0x10000000 > /dev/null
				cp /proc/vmstat $TMPD/vmstat.2

				if [ "$CGROUP" ] ; then
					cgget -g $CGROUP > $TMPD/memcg.2
				fi

				if [ "$MIGRATE_SRC" ] ; then
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
				fi

				# TODO: flag check enough?
				if [ "$OPERATION_TYPE" == mlock ] ; then
					get_pagetypes $pid pagetypes.2.mlocked -Nrla 0x700000000+0x10000000 -b mlocked > /dev/null
					if [ -s "$TMPD/pagetypes.2.mlocked" ] ; then
						set_return_code MLOCKED
					else
						set_return_code MLOCKED_FAILED
					fi
				fi

				if [ "$THP" ] ; then
					check_thp_split
					ret=$?
					if [ "$ret" == 0 ] ; then
						set_return_code THP_SPLIT
					elif [ "$ret" == 1 ] ; then
						set_return_code PMD_SPLIT
					elif [ "$ret" == 2 ] ; then
						set_return_code THP_NOT_SPLIT
					fi
				fi

				kill -SIGUSR1 $pid
				;;
			"just before exit")
				kill -SIGUSR1 $pid
				set_return_code EXIT
				return 0
				;;
			"waiting for migratepages")
				echo "calling do_migratepages for $pid"
				do_migratepages $pid
				kill -SIGUSR1 $pid
				;;
			"waiting for change_cpuset")
				cgclassify -g cpu,cpuset,memory:test1 $pid
				[ $? -eq 0 ] && set_return_code CGCLASSIFY_PASS || set_return_code CGCLASSIFY_FAIL
				echo "cat /sys/fs/cgroup/memory/test1/tasks"
				cat /sys/fs/cgroup/memory/test1/tasks
				ls /sys/fs/cgroup/memory/test1/tasks
				cgget -r cpuset.mems -r cpuset.cpus -r cpuset.memory_migrate test1
				# $PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
				$PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPD/pagetypes1

				cgset -r cpuset.mems=0 test1
				cgset -r cpuset.mems=1 test1
				cgget -r cpuset.mems -r cpuset.cpus -r cpuset.memory_migrate test1

				if [ "$CGROUP" ] ; then
					cgget -g $CGROUP > $TMPD/memcg.1
				fi

				$PAGETYPES -p $pid -r -b anon | grep total
				grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
				grep RssAnon /proc/$pid/status
				$PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPD/pagetypes2
				kill -SIGUSR1 $pid
				;;
			"waiting for auto_numa")
				# Current CPU/Memory should be NUMA non-optimal to kick
				# auto NUMA.
				echo "current CPU: $(ps -o psr= $pid)"
				taskset -p $pid
				# get_numa_maps $pid | tee $TMPD/numa_maps.1 | grep ^70000
				# get_numa_maps ${pid}
				# $PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512]
				# grep numa_hint_faults /proc/vmstat
				# expecting numa balancing migration
				sleep 3
				echo "current CPU: $(ps -o psr= $pid)"
				taskset -p $pid
				get_numa_maps $pid | tee $TMPD/numa_maps.2 | grep ^70000
				$PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512]
				grep numa_hint_faults /proc/vmstat
				kill -SIGUSR2 $pid
				;;
			"waiting for memory_hotremove"*)
				echo $line | sed "s/waiting for memory_hotremove: *//" > $TMPD/preferred_memblk
				targetmemblk=$(cat $TMPD/preferred_memblk)
				echo_log "preferred memory block: $targetmemblk"
				echo_log "echo offline > /sys/devices/system/memory/memory$targetmemblk/state"
				echo offline > /sys/devices/system/memory/memory$targetmemblk/state
				# if [ $? -ne 0 ] ; then
				# 	set_return_code MEMHOTREMOVE_FAILED
				# 	echo_log "do_memory_hotremove failed."
				# fi

				# $PAGETYPES -rNl -p ${pid} -b huge,compound_head=huge,compound_head > $TMPD/pagetypes1 | head
				# show_hugetlb_pool
				# find /sys -type f | grep hugepage | grep node | grep 2048
				# find /sys -type f | grep hugepage | grep node | grep 2048 | xargs cat
				# get_numa_maps ${pid} | tee -a $OFILE > $TMPD/numa_maps.1
				kill -SIGUSR1 $pid
				;;
			"waiting for process_vm_access")
				local cpid=$(pgrep -P $pid .)
				echo "$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head -Nl"
				$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head -Nl
				echo "$PAGETYPES -p $cpid -r -b thp,compound_head=thp,compound_head -Nl"
				$PAGETYPES -p $cpid -r -b thp,compound_head=thp,compound_head -Nl
				( for i in $(seq 20) ; do
						migratepages $pid 0 1  2> /dev/null
						migratepages $pid 1 0  2> /dev/null
						migratepages $cpid 0 1 2> /dev/null
						migratepages $cpid 1 0 2> /dev/null
						done ) &
				kill -SIGUSR1 $pid
				;;
			"entering busy loop")
				# sysctl -a | grep huge

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

				if [ "$OPERATION_TYPE" == mlock ] ; then
					$PAGETYPES -p $pid -Nrl -a 0x700000000+$[THP * 512] | head
				fi

				if [ "$OPERATION_TYPE" == mprotect ] ; then
					get_vma_protection
					$PAGETYPES -p $pid -Nrl -a 0x700000000+$[THP * 512] | head
				fi

				if [ "$MIGRATE_SRC" = auto_numa ] ; then
					# Current CPU/Memory should be NUMA non-optimal to kick
					# auto NUMA.
					echo "current CPU: $(ps -o psr= $pid)"
					taskset -p $pid
					get_numa_maps $pid | tee $TMPD/numa_maps.1 | grep ^70000
					# get_numa_maps ${pid}
					$PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512]
					grep numa_hint_faults /proc/vmstat
					# expecting numa balancing migration
					sleep 3
					echo "current CPU: $(ps -o psr= $pid)"
					taskset -p $pid
					get_numa_maps $pid | tee $TMPD/numa_maps.2 | grep ^70000
					$PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512]
					grep numa_hint_faults /proc/vmstat
				fi

				if [ "$MIGRATE_SRC" = change_cpuset ] ; then
					$PAGETYPES -p $pid -r -b anon | grep total
					grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
					grep RssAnon /proc/$pid/status
					$PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPD/pagetypes2
				fi

				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -NrL | grep -v offset | cut -f1,2 > $TMPD/mig2
				# count diff stats
				diff -u0 $TMPD/mig1 $TMPD/mig2 > $TMPD/mig3
				diffsize=$(grep -c -e ^+ -e ^- $TMPD/mig3)
				if [ "$diffsize" -eq 0 ] ; then
					set_return_code MIGRATION_FAILED
					echo "page migration failed."
				else
					echo "pfn/vaddr shows $diffsize diff lines"
					set_return_code MIGRATION_PASSED
				fi

				kill -SIGUSR2 $pid
				;;
			"exited busy loop")
				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -Nrl | grep -v offset | tee $TMPD/pagetypes2 | head -n 30
				get_numa_maps $pid   > $TMPD/numa_maps.2

				if [ "$CGROUP" ] ; then
					cgget -g $CGROUP > $TMPD/memcg.2
				fi
				kill -SIGUSR1 $pid
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
