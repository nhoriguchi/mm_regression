#!/bin/bash

. $TCDIR/lib/mm.sh

get_vma_protection() { grep -A 2 700000000000 /proc/$pid/maps; }

prepare_hugepage_migration() {
	prepare_mm_generic || return 1

	if [ "$RESERVE_HUGEPAGE" ] ; then
		echo_log "$test_alloc_generic -B hugetlb_anon -N $RESERVE_HUGEPAGE -L \"mmap:wait_after\" &"
		$test_alloc_generic -B hugetlb_anon -N $RESERVE_HUGEPAGE -L "mmap:wait_after" &
		set_return_code RESERVE
		sleep 1 # TODO: properly wait for reserve completion
	fi

	if [ "$ALLOCATE_HUGEPAGE" ] ; then
		echo_log "$test_alloc_generic -B hugetlb_anon -N $ALLOCATE_HUGEPAGE -b -L \"mmap access busyloop\" &"
		$test_alloc_generic -B hugetlb_anon -N $ALLOCATE_HUGEPAGE -b -L "mmap access busyloop" &
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

	# kernel is older before thp refcount redesign, so use "thp_split" field.
	if [ ! "$thp_split_before" ] ; then
		thp_split_before=$(grep "thp_split " $TMPD/vmstat.1 | cut -f2 -d' ')
		thp_split_after=$(grep "thp_split " $TMPD/vmstat.2 | cut -f2 -d' ')
	fi

	echo_log "check thp split from /proc/vmstat"

	if [ ! -e $TMPD/vmstat.1 ] || [ ! -e $TMPD/vmstat.2 ] ; then
		echo_log "vmstat log not exist."
		return 3
	fi

	if [ ! "$pmd_split_before" ] || [ ! "$pmd_split_after" ] ; then
		echo_log "pmd_split not supported in this kernel ($(uname -r))"
	else
		if [ "$pmd_split_before" -eq "$pmd_split_after" ] ; then
			echo_log "pmd not split"
			return 2
		else
			echo_log "pmd split ($pmd_split_before -> $pmd_split_after)"
		fi
	fi

	if [ "$thp_split_before" -eq "$thp_split_after" ] ; then
		echo_log "thp not split"
		return 1
	else
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
			"after_start")
				get_mm_stats 0 $pid

				if [ "$CGROUP" ] ; then
					cgclassify -g $CGROUP $pid
					if [ $? -eq 0 ] ; then
						set_return_code CGCLASSIFY_PASS
					else
						set_return_code CGCLASSIFY_FAIL
					fi
				fi

				kill -SIGUSR1 $pid
				;;
			"after_access")
				get_mm_stats 1 $pid

				# TODO: better condition check
				if [ "$RACE_SRC" == "race_with_gup" ] && [ "$MIGRATE_SRC" == "migratepages" ] ; then
					( for i in $(seq 10) ; do
						  migratepages $pid 0 1 > /dev/null 2>&1
						  migratepages $pid 1 0 > /dev/null 2>&1
					  done ) &
				fi

				# TODO: better condition check
				if [ "$RACE_SRC" == "race_with_fork" ] ; then
					$PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
					$PAGETYPES -p $pid -r -b anon | grep total
					ps ax | grep thp
					grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
					( for i in $(seq 10) ; do migratepages $pid 0 1 ; migratepages $pid 1 0 ; done ) &
				fi

				kill -SIGUSR1 $pid
				;;
			"before_munmap")
				get_mm_stats 2 $pid

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
				if [[ "$OPERATION_TYPE" =~ ^mlock ]] ; then
					get_pagetypes $pid pagetypes.2.mlocked -Nrla 0x700000000+0x10000000 -b mlocked
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
			"before_exit")
				kill -SIGUSR1 $pid
				set_return_code EXIT
				return 0
				;;
			"waiting for migratepages")
				echo "calling do_migratepages for $pid"
				do_migratepages $pid
				echo $?
				kill -SIGUSR1 $pid
				;;
			"waiting for change_cpuset")
				echo "changing cpuset.mems 0 to 1"
				cgset -r cpuset.mems=0 test1
				cgset -r cpuset.mems=1 test1
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
				kill -SIGUSR1 $pid
				;;
			"waiting for memory_hotremove"*)
				echo $line | sed "s/waiting for memory_hotremove: *//" > $TMPD/preferred_memblk
				MEMBLK_SIZE=0x8000 # in page

				targetmemblk=$(cat $TMPD/preferred_memblk)
				echo_log "preferred memory block: $targetmemblk"
				echo_log "echo offline > /sys/devices/system/memory/memory$targetmemblk/state"

				if [ "$OPERATION_SRC" == hwpoison ] ; then
					echo_log "$PAGETYPES -a $[$targetmemblk * $MEMBLK_SIZE] -X"
					$PAGETYPES -a $[$targetmemblk * $MEMBLK_SIZE] -X
				fi

				echo offline > /sys/devices/system/memory/memory$targetmemblk/state
				kill -SIGUSR1 $pid
				;;
			"waiting for process_vm_access")
				local cpid=$(pgrep -P $pid .)
				( for i in $(seq 10) ; do
					  migratepages $pid 0 1 > /dev/null 2>&1
					  migratepages $pid 1 0 > /dev/null 2>&1
					  migratepages $cpid 0 1 > /dev/null 2>&1
					  migratepages $cpid 1 0 > /dev/null 2>&1
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

				$PAGETYPES -p $pid -a 0x700000000+0x10000000 -NrL | grep -v offset | cut -f1,2 > $TMPD/.mig2
				# count diff stats
				diff -u0 $TMPD/.mig1 $TMPD/.mig2 > $TMPD/.mig3
				diffsize=$(grep -c -e ^+ -e ^- $TMPD/.mig3)
				if [ "$diffsize" -eq 0 ] ; then
					set_return_code MIGRATION_FAILED
					echo "page migration failed."
				else
					echo "pfn/vaddr shows $diffsize diff lines"
					set_return_code MIGRATION_PASSED
				fi

				kill -SIGUSR1 $pid
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
