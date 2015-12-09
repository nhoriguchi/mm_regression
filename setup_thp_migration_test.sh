#!/bin/bash

# requires numactl package

NUMNODE=$(numactl -H | grep available | cut -f2 -d' ')
[ "$NUMNODE" -eq 1 ] && echo "no numa node" >&2 && exit 1

check_and_define_tp test_alloc_thp
check_and_define_tp test_mlock_on_shared_thp
check_and_define_tp test_mprotect_on_shared_thp
check_and_define_tp test_thp_migration_race_with_gup
check_and_define_tp numa_maps
check_and_define_tp test_process_vm_access
check_and_define_tp test_mbind_hm
check_and_define_tp iterate_mmap_fault_munmap
check_and_define_tp test_fill_zone

get_numa_maps() { cat /proc/$1/numa_maps; }

kill_test_programs() {
    pkill -9 -f $test_alloc_thp
	pkill -9 -f $test_mlock_on_shared_thp
	pkill -9 -f $test_mprotect_on_shared_thp
	pkill -9 -f $numa_maps
	pkill -9 -f $test_thp_migration_race_with_gup
	pkill -9 -f $test_process_vm_access
    return 0
}

prepare_test() {
    kill_test_programs 2> /dev/null
    get_kernel_message_before
}

cleanup_test() {
    get_kernel_message_after
    get_kernel_message_diff | tee -a ${OFILE}
    kill_test_programs 2> /dev/null
}

control_thp_migration_auto_numa() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "before allocating thps")
            # collect all pages to node 1
            for node in $(seq $NUMNODE) ; do
                do_migratepages $pid $[node-1] 1
            done
            $numa_maps $pid
            kill -SIGUSR1 $pid
            ;;
        "entering busy loop")
            # most of the memory mapped on the process (except thps) is
            # on node 1, which should trigger numa balancin migration.
            $numa_maps $pid
            get_numa_maps ${pid}   > ${TMPF}.numa_maps1
            # get_numa_maps ${pid}
            $PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512]
            # expecting numa balancing migration
            sleep 1
            $numa_maps $pid
            $PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512]
            kill -SIGUSR1 $pid
            ;;
        "set mempolicy to default")
            $numa_maps $pid
            kill -SIGUSR1 $pid
            ;;
        "exited busy loop")
            get_numa_maps ${pid}   > ${TMPF}.numa_maps2
            kill -SIGUSR1 $pid
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_numa_maps() {
    count_testcount "CHECK /proc/pid/numa_maps"
    local map1=$(grep "^700000000000" ${TMPF}.numa_maps1 | sed -r 's/.* (N[0-9]*=[0-9]*).*/\1/g')
    local map2=$(grep "^700000000000" ${TMPF}.numa_maps2 | sed -r 's/.* (N[0-9]*=[0-9]*).*/\1/g')
    if [ "$map1" == "$map2" ] ; then
        count_failure "thp is not migrated."
        echo "map1=${map1}, map2=${map2}"
    else
        count_success "thp is migrated."
    fi
}

check_thp_migration_auto_numa() {
    check_kernel_message_nobug
    check_return_code "${EXPECTED_RETURN_CODE}"
    check_numa_maps
}

INIT_NUMA_BALANCING=$(cat /proc/sys/kernel/numa_balancing)

prepare_thp_migration_auto_numa() {
    sysctl vm.nr_hugepages=0
    prepare_test

    # numa balancing should be enabled
    echo 1 > /proc/sys/kernel/numa_balancing
    echo 1 > /proc/sys/kernel/numa_balancing_scan_delay_ms
    echo 100 > /proc/sys/kernel/numa_balancing_scan_period_max_ms
    echo 100 > /proc/sys/kernel/numa_balancing_scan_period_min_ms
    echo 1024 > /proc/sys/kernel/numa_balancing_scan_size_mb
}

cleanup_thp_migration_auto_numa() {
    echo $INIT_NUMA_BALANCING > /proc/sys/kernel/numa_balancing
    echo 1000 > /proc/sys/kernel/numa_balancing_scan_delay_ms
    echo 60000 > /proc/sys/kernel/numa_balancing_scan_period_max_ms
    echo 1000 > /proc/sys/kernel/numa_balancing_scan_period_min_ms
    echo 256 > /proc/sys/kernel/numa_balancing_scan_size_mb
    cleanup_test
}

control_mlock_on_shared_thp() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "before fork")
            echo "pid: $pid" | tee -a ${OFILE}
            $PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512] \
                | sed 's/^/  /' | tee -a ${OFILE}
            kill -SIGUSR1 $pid
            ;;
        "check shared thp")
            for ppid in $(pgrep -f $TESTMLOCKONSHAREDTHP) ; do
                echo "pid: $ppid ---" | tee -a ${OFILE}
                $PAGETYPES -p $ppid -Nl -a 0x700000000+$[NR_THPS * 512] \
                    | sed 's/^/  /' | tee -a ${OFILE}
            done
            for ppid in $(pgrep -f $TESTMLOCKONSHAREDTHP) ; do
                kill -SIGUSR1 $ppid
            done
            ;;
        "exited busy loop")
            for ppid in $(pgrep -f $TESTMLOCKONSHAREDTHP) ; do
                echo "pid: $ppid ---" | tee -a ${OFILE}
                $PAGETYPES -p $ppid -Nl -a 0x700000000+$[NR_THPS * 512] \
                    | sed 's/^/  /' | tee -a ${OFILE}
            done
            for ppid in $(pgrep -f $TESTMLOCKONSHAREDTHP) ; do
                kill -SIGUSR1 $ppid
            done
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_mlock_on_shared_thp() {
    check_kernel_message_nobug
    check_return_code "${EXPECTED_RETURN_CODE}"
}

prepare_mlock_on_shared_thp() {
    sysctl vm.nr_hugepages=0
    prepare_test
}

cleanup_mlock_on_shared_thp() {
    cleanup_test
}

get_vma_protection() {
    local pid=$1
    grep -A 2 700000000000 /proc/$pid/maps
}

CHECKED=

control_mprotect_on_shared_thp() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "before fork")
            echo "pid: $pid" | tee -a ${OFILE}
            $PAGETYPES -p $pid -Nl -a 0x700000000+$[NR_THPS * 512] \
                | sed 's/^/  /' | tee -a ${OFILE}
            get_vma_protection $pid
            kill -SIGUSR1 $pid
            ;;
        "just before mprotect")
            if [ "$CHECKED" != true ] ; then
                sleep 0.1
                CHECKED=true
                for ppid in $(pgrep -f $TESTMPROTECTONSHAREDTHP) ; do
                    echo "pid: $ppid ---" | tee -a ${OFILE}
                    $PAGETYPES -p $ppid -Nl -a 0x700000000+$[NR_THPS * 512] \
                        | sed 's/^/  /' | tee -a ${OFILE}
                    get_vma_protection $ppid
                done
                kill -SIGUSR1 $pid
            fi
            ;;
        "mprotect done")
            sleep 0.1
            for ppid in $(pgrep -f $TESTMPROTECTONSHAREDTHP) ; do
                echo "pid: $ppid ---" | tee -a ${OFILE}
                $PAGETYPES -p $ppid -Nl -a 0x700000000+$[NR_THPS * 512] \
                    | sed 's/^/  /' | tee -a ${OFILE}
                get_vma_protection $ppid
            done
            for ppid in $(pgrep -f $TESTMPROTECTONSHAREDTHP) ; do
                if [ "$ppid" = "$pid" ] ; then
                    kill -SIGUSR1 $ppid
                else
                    kill -9 $ppid
                fi
            done
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_mprotect_on_shared_thp() {
    check_kernel_message_nobug
    check_return_code "${EXPECTED_RETURN_CODE}"
}

prepare_mprotect_on_shared_thp() {
    sysctl vm.nr_hugepages=0
    prepare_test
}

cleanup_mprotect_on_shared_thp() {
    cleanup_test
}

control_migratepages_thp() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "entering_busy_loop")
            $PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
            $PAGETYPES -p $pid -r -b anon | grep total
			grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
			grep RssAnon /proc/$pid/status
            $PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPF.pagetypes1
			migratepages $pid 0 1
			# migratepages $pid 1 0
            kill -SIGUSR1 $pid
            ;;
        "exited_busy_loop")
            $PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
            $PAGETYPES -p $pid -r -b anon | grep total
			grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
			grep RssAnon /proc/$pid/status
            $PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPF.pagetypes2
            kill -SIGUSR1 $pid
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_thp_migration() {
	check_system_default
	check_thp_migrated
}

check_thp_migration_partial() {
	check_system_default
	check_thp_split_migrated
}

prepare_migratepages_thp() {
	set_thp_madvise
	kill_test_programs
	khpd_off
    echo 0 > /proc/sys/kernel/numa_balancing
	prepare_system_default
}

cleanup_migratepages_thp() {
	kill_test_programs
	set_thp_always
	khpd_on
    echo 1 > /proc/sys/kernel/numa_balancing
	cleanup_system_default
}

check_thp_migrated() {
	local before_head=$(sed -ne 1p $TMPF.pagetypes1 | cut -f2)
	local before_tail=$(sed -ne 2p $TMPF.pagetypes1 | cut -f2)
	local after_head=$(sed -ne 1p $TMPF.pagetypes2 | cut -f2)
	local after_tail=$(sed -ne 2p $TMPF.pagetypes2 | cut -f2)

	count_testcount "thp migration check"
	echo "$before_head/$before_tail => $after_head/$after_tail"
	if [ "$before_head" = "$after_head" ] ; then
		count_failure "thp not migrated (stay in a place)"
	else
		local ah16=$(printf "%d" 0x$after_head)
		local at16=$(printf "%d" 0x$after_tail)
		if [ "$[$ah16 + 1]" -eq "$at16" ] ; then
			count_success "thp migrated"
		else
			count_failure "maybe raw page migrated"
		fi
	fi
}

check_thp_split_migrated() {
	local before_head=$(sed -ne 1p $TMPF.pagetypes1 | cut -f2)
	local before_tail=$(sed -ne 2p $TMPF.pagetypes1 | cut -f2)
	local before_flag=$(sed -ne 1p $TMPF.pagetypes1 | cut -f4)
	local after_head=$(sed -ne 1p $TMPF.pagetypes2 | cut -f2)
	local after_tail=$(sed -ne 2p $TMPF.pagetypes2 | cut -f2)
	local after_flag=$(sed -ne 1p $TMPF.pagetypes2 | cut -f4)

 	count_testcount "thp split/migration check"
 	echo "$before_head/$before_tail => $after_head/$after_tail"
 	if ! [[ "$before_flag" =~ t ]] ; then
 		count_failure "Initial state is not a thp"
	elif [[ "$after_flag" =~ t ]] ; then
 		count_failure "The thp didn't split"
 	elif [ "$before_head" = "$after_head" ] || [ "$before_tail" = "$after_tail" ] ; then
 		count_failure "split raw pages did not migrated (stay in a place)"
	else
		count_success "thp split and migrated"
 	fi
}

control_migratepages_thp_race_with_gup() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "waiting_for_migration")
            $PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
            $PAGETYPES -p $pid -r -b anon | grep total
			ps ax | grep thp
			grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
			( for i in $(seq 10) ; do migratepages $pid 0 1 ; migratepages $pid 1 0 ; done ) &
            pkill -SIGUSR1 -f -P $$ test_thp_migration_race_with_gup
            ;;
        "done")
            pkill -SIGUSR1 -f -P $$ test_thp_migration_race_with_gup
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

control_migratepages_thp_race_with_process_vm_access() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "thp_allocated_and_forked")
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
        "done")
            pkill -SIGUSR1 -f -P $$ test_process_vm_access
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

prepare_change_cpuset_thp() {
	set_thp_madvise
	kill_test_programs
	khpd_off
    echo 0 > /proc/sys/kernel/numa_balancing
	prepare_system_default

    cgdelete cpu,cpuset,memory:test1 2> /dev/null
    cgcreate -g cpu,cpuset,memory:test1 || return 1
	cgset -r cpuset.memory_migrate=1 test1
	# TODO: confirm multiple mems
	cgset -r cpuset.cpus=0-1 test1
	cgset -r cpuset.mems=0 test1
}

cleanup_change_cpuset_thp() {
    # cgdelete cpu,cpuset,memory:test1 2> /dev/null
	
	kill_test_programs
	set_thp_always
	khpd_on
    echo 1 > /proc/sys/kernel/numa_balancing
	cleanup_system_default
}

control_change_cpuset_thp() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "entering_busy_loop")
			cgclassify -g cpu,cpuset,memory:test1 $pid
			[ $? -eq 0 ] && set_return_code CGCLASSIFY_PASS || set_return_code CGCLASSIFY_FAIL
			echo "cat /sys/fs/cgroup/memory/test1/tasks"
			cat /sys/fs/cgroup/memory/test1/tasks
			ls /sys/fs/cgroup/memory/test1/tasks
			cgget -r cpuset.mems -r cpuset.cpus -r cpuset.memory_migrate test1
            # $PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
            $PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPF.pagetypes1
			
			cgset -r cpuset.mems=0 test1
			cgset -r cpuset.mems=1 test1
			cgget -r cpuset.mems -r cpuset.cpus -r cpuset.memory_migrate test1
            kill -SIGUSR1 $pid
            ;;
        "exited_busy_loop")
            # $PAGETYPES -p $pid -r -b thp,compound_head=thp,compound_head
            $PAGETYPES -p $pid -r -b anon | grep total
			grep -A15 ^70000 /proc/$pid/smaps | grep -i anon
			grep RssAnon /proc/$pid/status
            $PAGETYPES -p $pid -rNl -a 0x700000000+$[NR_THPS * 512] | grep -v offset | head | tee -a $OFILE | tee $TMPF.pagetypes2
            kill -SIGUSR1 $pid
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

control_memory_hotremove_migration_thp() {
    local pid="$1"
    local line="$2"

    echo_log "$line"
    case "$line" in
        "before memory_hotremove"* )
            echo $line | sed "s/before memory_hotremove: *//" > ${TMPF}.preferred_memblk
            echo_log "preferred memory block: $targetmemblk"
            $PAGETYPES -rNl -p ${pid} -a 0x700000000+0xf0000000 | grep -v offset | tee ${TMPF}.pagetypes1
            $PAGETYPES -rNl -p ${pid}
            get_numa_maps ${pid} | tee -a $OFILE > ${TMPF}.numa_maps1
            kill -SIGUSR1 $pid
            ;;
        "entering busy loop")
			cat /sys/kernel/mm/transparent_hugepage/enabled
            echo_log "do memory hotplug ($(cat ${TMPF}.preferred_memblk))"
            echo_log "echo offline > /sys/devices/system/memory/memory$(cat ${TMPF}.preferred_memblk)/state"
            echo offline > /sys/devices/system/memory/memory$(cat ${TMPF}.preferred_memblk)/state
            if [ $? -ne 0 ] ; then
                set_return_code MEMHOTREMOVE_FAILED
                echo_log "do_memory_hotremove failed."
            fi
            kill -SIGUSR1 $pid
            ;;
        "exited busy loop")
            $PAGETYPES -rNl -p ${pid} -a 0x700000000+0xf0000000 | grep -v offset | tee ${TMPF}.pagetypes2
            get_numa_maps ${pid} | tee -a $OFILE  > ${TMPF}.numa_maps2
            kill -SIGUSR1 $pid
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

prepare_memory_hotremove_migration_thp() {
    reonline_memblocks
	set_thp_madvise
    prepare_system_default
	echo 3 > /proc/sys/vm/drop_caches
    PIPETIMEOUT=30
}

cleanup_memory_hotremove_migration_thp() {
    reonline_memblocks
	set_thp_always
    cleanup_system_default
    PIPETIMEOUT=5
}

check_memory_hotremove_migration_thp() {
    check_system_default
	check_thp_migrated
}

control_race_migratepages_and_map_fault_unmap() {
    for i in $(seq 5) ; do
        $iterate_mmap_fault_munmap -n 10 -t &
        local pid=$!
		sleep 0.3
        for j in $(seq 100) ; do
			# $PAGETYPES -p $pid -Nl -b thp,compound_head=thp,compound_head | grep -v offset > $TMPF.pagetypes1
            do_migratepages $pid 0 1
			# $PAGETYPES -p $pid -Nl -b thp,compound_head=thp,compound_head | grep -v offset > $TMPF.pagetypes2
            do_migratepages $pid 1 0
			# echo $j
			# cat $TMPF.pagetypes1 $TMPF.pagetypes2
			# diff -u $TMPF.pagetypes1 $TMPF.pagetypes2 >&2
        done
        kill -SIGUSR1 $pid 2> /dev/null
    done
    set_return_code EXIT
}

check_race_migratepages_and_map_fault_unmap() {
    check_system_default
}

calc_large_pool_size() {
	grep "^Node 1" /proc/buddyinfo | tr -s ' ' > $TMPF.buddyinfo
	if [ "$(cat $TMPF.buddyinfo | wc -l)" -ne 1 ] ; then
		echo "/proc/buddyinfo shows multiple line for Node 1?" >&2
		exit 1
	fi
	local o0=$(cut -d' ' -f5 $TMPF.buddyinfo)
	local o1=$(cut -d' ' -f6 $TMPF.buddyinfo)
	local o2=$(cut -d' ' -f7 $TMPF.buddyinfo)
	local o3=$(cut -d' ' -f8 $TMPF.buddyinfo)
	local o4=$(cut -d' ' -f9 $TMPF.buddyinfo)
	local o5=$(cut -d' ' -f10 $TMPF.buddyinfo)
	local o6=$(cut -d' ' -f11 $TMPF.buddyinfo)
	local o7=$(cut -d' ' -f12 $TMPF.buddyinfo)
	local o8=$(cut -d' ' -f13 $TMPF.buddyinfo)
	local o9=$(cut -d' ' -f14 $TMPF.buddyinfo)
	local o10=$(cut -d' ' -f15 $TMPF.buddyinfo)
	local free=$(echo "$o0 + $o1 * 2 + $o2 * 4 + $o3 * 8 + $o4 * 16 + $o5 * 32 + $o6 * 64 + $o7 * 128 + $o8 * 256 + $o9 * 512 + $o10 * 1024" | bc)
	echo $[$free/512*99/100]
}

fill_node_1() {
	local psize=$(calc_large_pool_size)
	if [ ! "$psize" ] ; then
		set_return_code FAILED_TO_FILL_NODE1
	else
		echo "echo $psize > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages"
		echo $psize > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages
		set_return_code FILLED_NODE1
	fi
}

prepare_move_pages_thp_migration_fail() {
    prepare_system_default
	set_and_check_hugetlb_pool 0
}

cleanup_move_pages_thp_migration_fail() {
	set_and_check_hugetlb_pool 0
    cleanup_system_default
}

control_compaction_dropcache_poolallocation_race() {
    # reonline_memblocks
	# set_thp_madvise
    # prepare_system_default
	# echo 2000 > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages
	echo 0 > /proc/sys/vm/nr_hugepages
	# echo 1 > /proc/sys/vm/compact_memory
	# echo 3 > /proc/sys/vm/drop_caches
	# echo 20000 > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages

	echo $free , $target
	# $test_fill_zone $target
	echo "echo $(calc_large_pool_size) > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages"
	set_return_code EXIT
}
