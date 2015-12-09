#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

if [ ! -d /sys/fs/cgroup/memory ] ; then
    echo "memory cgroup is not supported on this kernel $(uname -r)"
    return
fi

MEMCGDIR=/sys/fs/cgroup/memory
check_and_define_tp test_swap_shmem
check_and_define_tp test_thp_double_mapping

yum install -y libcgroup-tools

__prepare_memcg() {
    cgdelete cpu,memory:test1 2> /dev/null
    cgdelete cpu,memory:test2 2> /dev/null
    cgcreate -g cpu,memory:test1 || return 1
    cgcreate -g cpu,memory:test2 || return 1
    echo 1 > $MEMCGDIR/test1/memory.move_charge_at_immigrate || return 1
    echo 1 > $MEMCGDIR/test2/memory.move_charge_at_immigrate || return 1
}

__cleanup_memcg() {
    cgdelete cpu,memory:test1 || return 1
    cgdelete cpu,memory:test2 || return 1
}

prepare_swap_shmem() {
    local swapfile=$WDIR/swapfile
    __prepare_memcg || return 1
    [ $? -ne 0 ] && echo "failed to __prepare_memcg" && return 1
    dd if=/dev/zero of=$swapfile bs=4096 count=10240 > /dev/null 2>&1
    [ $? -ne 0 ] && echo "failed to create $swapfile" && return 1
    mkswap $swapfile
    chmod 0600 $swapfile
    swapon $swapfile
    count_testcount
    if swapon -s | grep ^$swapfile > /dev/null ; then
        count_success "create swapfile"
    else
        count_failure "create swapfile"
    fi
    echo 3 > /proc/sys/vm/drop_caches
	# 16M
    echo "cgset -r memory.limit_in_bytes=0x1000000 test1"
    cgset -r memory.limit_in_bytes=0x1000000 test1
    [ $? -ne 0 ] && echo "failed to cgset memory.limit_in_bytes" && return 1
	# 128M
    echo "cgset -r memory.memsw.limit_in_bytes=0x8000000 test1"
    cgset -r memory.memsw.limit_in_bytes=0x8000000 test1
    [ $? -ne 0 ] && echo "failed to cgset memory.memsw.limit_in_bytes" && return 1
    set_thp_never
    return 0
}

cleanup_swap_shmem() {
    set_thp_always
	ipcrm --all
    swapoff $WDIR/swapfile
    rm -rf $WDIR/swapfile
    __cleanup_memcg
}

__get_smaps_shmem() {
    gawk '
      BEGIN {gate=0;}
      /^[0-9]/ {
          if ($0 ~ /^7000000/) {
              gate = 1;
          } else {
              gate = 0;
          }
      }
      {if (gate==1) {print $0;}}
    ' /proc/$pid/smaps
}

__get_smaps_anon() {
    gawk '
      BEGIN {gate=0;}
      /^[0-9]/ {
          if ($0 ~ /^700000c/) {
              gate = 1;
          } else {
              gate = 0;
          }
      }
      {if (gate==1) {print $0;}}
    ' /proc/$pid/smaps
}

control_swap_shmem() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "swap_shmem start")
            cgclassify -g cpu,memory:test1 $pid || set_return_code CGCLASSIFY_FAIL
            kill -SIGUSR1 $pid
            ;;
        "shmem allocated")
            kill -SIGUSR1 $pid
            ;;
        "shmem attached")
            kill -SIGUSR1 $pid
            ;;
        "shmem faulted-in")
			__get_smaps_shmem | tee -a $OFILE > $TMPF.smaps_shmem.1
			__get_smaps_anon | tee -a $OFILE > $TMPF.smaps_anon.1
			grep ^Swap: /proc/$pid/smaps > $TMPF.smaps_swap.1
            $PAGETYPES -r -p $pid -a 0x700000000+8192 > $TMPF.page_type.1
			cat /proc/$pid/status > $TMPF.proc_status.1
            kill -SIGUSR1 $pid
            ;;
        "swap_shmem exit")
			__get_smaps_shmem | tee -a $OFILE > $TMPF.smaps_shmem.2
			__get_smaps_anon | tee -a $OFILE > $TMPF.smaps_anon.2
			grep ^Swap: /proc/$pid/smaps > $TMPF.smaps_swap.2
            $PAGETYPES -r -p $pid -a 0x700000000+8192 > $TMPF.page_type.2
			cat /proc/$pid/status > $TMPF.proc_status.2
            set_return_code "EXIT"
            kill -SIGUSR1 $pid
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_swap_shmem() {
    check_system_default

	# grep -e ^Swap: -e ^Size: -e ^Rss: $TMPF.smaps_shmem.1
	# grep -e ^Swap: -e ^Size: -e ^Rss: $TMPF.smaps_shmem.2
	# grep -e ^Swap: -e ^Size: -e ^Rss: $TMPF.smaps_anon.1
	# grep -e ^Swap: -e ^Size: -e ^Rss: $TMPF.smaps_anon.2
	# echo '---'
	# grep -e ^Vm $TMPF.proc_status.1
	# echo '---'
	# grep -e ^Vm $TMPF.proc_status.2
	# echo '---'
	# cat $TMPF.smaps_swap.1
	# echo '---'
	# cat $TMPF.smaps_swap.2

	local shmsize="$(grep ^Size: $TMPF.smaps_shmem.2 2> /dev/null | awk '{print $2}')"
	local shmrss="$(grep ^Rss: $TMPF.smaps_shmem.2 2> /dev/null | awk '{print $2}')"
	local shmswap="$(grep ^Swap: $TMPF.smaps_shmem.2 2> /dev/null | awk '{print $2}')"
	local anonsize="$(grep ^Size: $TMPF.smaps_anon.2 2> /dev/null | awk '{print $2}')"
	local anonrss="$(grep ^Rss: $TMPF.smaps_anon.2 2> /dev/null | awk '{print $2}')"
	local anonswap="$(grep ^Swap: $TMPF.smaps_anon.2 2> /dev/null | awk '{print $2}')"
	local vmrss="$(grep ^VmRSS: $TMPF.proc_status.2 2> /dev/null | awk '{print $2}')"
	local vmrss="$(grep ^VmSwap: $TMPF.proc_status.2 2> /dev/null | awk '{print $2}')"

	count_testcount
	if [ "$[$anonsize - $anonrss - $anonswap]" -eq 0 ] ; then
        count_success "anonsize - anonrss - anonswap == 0"
    else
        count_failure "anonsize - anonrss - anonswap != 0"
    fi

    FALSENEGATIVE=true
	count_testcount
	if [ "$[$shmsize - $shmrss - $shmswap]" -eq 0 ] ; then
        count_success "shmsize - shmrss - shmswap == 0"
    else
        count_failure "shmsize - shmrss - shmswap != 0"
    fi
    FALSENEGATIVE=false
}

prepare_thp_double_mapping() {
	prepare_system_default
}

cleanup_thp_double_mapping() {
	[[ "$(jobs -p)" ]] || kill -9 $(jobs -p)
	cleanup_system_default
}

__show_page_types() {
	local pid=$1

	if [ "$(pgrep -P $pid)" ] ; then
		echo "after fork: parent"
		$PAGETYPES -r -p $pid -a 0x700000000+1024 -Nl # > $TMPF.page_type.1
		echo "after fork: child"
		$PAGETYPES -r -p $(pgrep -P $pid) -a 0x700000000+1024 -Nl # > $TMPF.page_type.1
	else
		echo "after fork:"
		$PAGETYPES -r -p $pid -a 0x700000000+1024 -Nl # > $TMPF.page_type.1
	fi
}

control_thp_double_mapping() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "thp allocated")
            kill -SIGUSR1 $pid
            ;;
        "forked")
			__show_page_types $pid
			grep thp /proc/vmstat
			grep -i anon /proc/meminfo
            kill -SIGUSR1 $pid
            ;;
        "pmd_split")
			__show_page_types $pid
			grep thp /proc/vmstat
			grep -i anon /proc/meminfo
            kill -SIGUSR1 $pid $(pgrep -P $pid)
            ;;
        "waiting_migratepages")
			migratepages $pid 0 1
            kill -SIGUSR1 $pid $(pgrep -P $pid)
            ;;
        "thp_split")
			__show_page_types $pid
			grep thp /proc/vmstat
			grep -i anon /proc/meminfo
            kill -SIGUSR1 $pid
            ;;
        "done")
            set_return_code "EXIT"
            kill -SIGUSR1 $pid
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_thp_double_mapping() {
	check_system_default
}

#
# idle page tracking
#
check_and_define_tp test_idle_page_tracking
check_and_define_tp mark_idle_all
prepare_idle_page_tracking() {
	pkill -9 -P $$ -f $test_idle_page_tracking
	pkill -9 memhog
    dd if=/dev/zero of=$WDIR/testfile bs=4096 count=$EACH_BUFSIZE_IN_PAGE > /dev/null 2>&1
    [ $? -ne 0 ] && echo "failed to create $swapfile" && return 1
	set_and_check_hugetlb_pool 100
	prepare_system_default
	memhog -r100000000 $[$(grep ^MemTotal: /proc/meminfo | awk '{print $2}') * 3 / 4]k > /dev/null &
	sleep 3
	free
}

cleanup_idle_page_tracking() {
	cleanup_system_default
	set_and_check_hugetlb_pool 0
    rm -rf $WDIR/testfile
	pkill -9 -P $$ -f $test_idle_page_tracking
	pkill -9 memhog
}

control_idle_page_tracking() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a $OFILE
    case "$line" in
        "test_idle_page_tracking start")
            kill -SIGUSR1 $pid
            ;;
        "test_idle_page_tracking exit")
            set_return_code "EXIT"
            kill -SIGUSR1 $pid
			return 0
            ;;
        "faulted-in")
			sleep 1
			echo $mark_idle_all write | tee -a $OFILE
			$mark_idle_all write
			# echo "$PAGETYPES -r -p $pid -a 0x700000000+$[4*$EACH_BUFSIZE_IN_PAGE]" | tee -a $OFILE
			# $PAGETYPES -r -p $pid -a 0x700000000+$[4*$EACH_BUFSIZE_IN_PAGE] | tee -a $OFILE

            echo "$PAGETYPES -r -b idle_page | grep total" | tee -a $OFILE
            $PAGETYPES -r -b idle_page | grep total | tee -a $OFILE
            kill -SIGUSR1 $pid
            ;;
        "busyloop")
			sleep 2
			echo $mark_idle_all read | tee -a $OFILE
            echo "$PAGETYPES -r -p $pid -a 0x700000000+$[4*$EACH_BUFSIZE_IN_PAGE]" | tee -a $OFILE
			$PAGETYPES -r -p $pid -a 0x700000000+$[4*$EACH_BUFSIZE_IN_PAGE] | tee -a $OFILE

            echo "$PAGETYPES -r -b idle_page | grep total" | tee -a $OFILE
            $PAGETYPES -r -b idle_page | grep total | tee -a $OFILE
            kill -SIGUSR1 $pid
            ;;
        "referenced")
			sleep 1
			echo $mark_idle_all read | tee -a $OFILE
            echo "$PAGETYPES -r -p $pid -a 0x700000000+$[4*$EACH_BUFSIZE_IN_PAGE]" | tee -a $OFILE
			$PAGETYPES -r -p $pid -a 0x700000000+$[4*$EACH_BUFSIZE_IN_PAGE] | tee -a $OFILE

            echo "$PAGETYPES -r -b idle_page | grep total" | tee -a $OFILE
            $PAGETYPES -r -b idle_page | grep total | tee -a $OFILE
            kill -SIGUSR1 $pid
            ;;
        *)
            ;;
    esac
    return 1
}

check_idle_page_tracking() {
	check_system_default
}

check_and_define_tp test_memory_compaction
prepare_memory_compaction() {
	pkill -9 -P $$ -f $test_memory_compaction
	# pkill -9 memhog
    # dd if=/dev/zero of=$WDIR/testfile bs=4096 count=$EACH_BUFSIZE_IN_PAGE > /dev/null 2>&1
    # [ $? -ne 0 ] && echo "failed to create $swapfile" && return 1
	# set_and_check_hugetlb_pool 100
	prepare_system_default
	# free
	# echo "set_khpd_pages_to_scan $[4096 * 10]"
	# set_khpd_pages_to_scan $[4096 * 10]
	# echo "set_khpd_scan_sleep_millisecs 0"
	# set_khpd_scan_sleep_millisecs 0
	# echo "set_khpd_alloc_sleep_millisecs 0"
	# set_khpd_alloc_sleep_millisecs 0
	set_thp_always
	show_current_tuning_parameters
	show_current_tuning_parameters_compact
}

cleanup_memory_compaction() {
	cleanup_system_default
	set_and_check_hugetlb_pool 0
    rm -rf $WDIR/testfile
	pkill -9 -P $$ -f $test_memory_compaction
	pkill -9 memhog
	default_tuning_parameters
}

control_memory_compaction() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a $OFILE
    case "$line" in
        "test_memory_compaction start")
			show_current_tuning_parameters_compact
			grep -e comp -e thp /proc/vmstat
			show_stat_thp
            kill -SIGUSR1 $pid
            ;;
        "test_memory_compaction exit")
            set_return_code "EXIT"
            kill -SIGUSR1 $pid
			return 0
            ;;
        "busyloop")
			for i in $(seq 12) ; do
				sleep 1
				$PAGETYPES -r -p $pid -a 0x700000000+$EACH_BUFSIZE_IN_PAGE -Nl
			done
            kill -SIGUSR1 $pid
            ;;
        "referenced")
			$PAGETYPES -r -p $pid -a 0x700000000+$EACH_BUFSIZE_IN_PAGE -Nl
			grep -e comp -e thp /proc/vmstat
			show_stat_thp
            kill -SIGUSR1 $pid
            ;;
        *)
            ;;
    esac
    return 1
}

check_memory_compaction() {
	check_system_default
}
