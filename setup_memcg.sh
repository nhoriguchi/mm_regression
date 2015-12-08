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
check_and_define_tp test_malloc_madv_willneed

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

prepare_memcg_move_task() {
    pkill -9 sleep
    __prepare_memcg || return 1
    prepare_system_default
}

cleanup_memcg_move_task() {
    pkill -P $$ -9 sleep
    __cleanup_memcg || return 1
    cleanup_system_default
}

control_memcg_move_task() {
    cgexec -g cpu,memory:test1 sleep 1000 &
    disown $!
    cgexec -g cpu,memory:test1 sleep 1000 &
    disown $!
    # take some time until created tasks are registered into the cgroup
    sleep 0.5
    cat $MEMCGDIR/test1/tasks > $TMPF.test1_tasks_1
    cat $MEMCGDIR/test2/tasks > $TMPF.test2_tasks_1
    cgclassify -g cpu,memory:test2 $(cat $MEMCGDIR/test1/tasks)
    [ $? -eq 0 ] && set_return_code MOVE_PASS || set_return_code MOVE_FAIL
    cat $MEMCGDIR/test1/tasks > $TMPF.test1_tasks_2
    cat $MEMCGDIR/test2/tasks > $TMPF.test2_tasks_2
    pkill -P $$ -9 sleep
    set_return_code "EXIT"
    return 0
}

check_memcg_move_task() {
    check_system_default
    count_testcount
    if diff $TMPF.test1_tasks_1 $TMPF.test2_tasks_2 2> /dev/null >&2 ; then
        count_success "processes moved from memory:test1 to memory:test2"
    else
        count_failure "processes failed to move from memory:test1 to memory:test2"
        echo "tasks before migration: test1 ($(cat $TMPF.test1_tasks_1)), test2 ($(cat $TMPF.test2_tasks_1))"
        echo "tasks after migration: test1 ($(cat $TMPF.test1_tasks_2)), test2 ($(cat $TMPF.test2_tasks_2))"
    fi
}

prepare_force_swapin_readahead() {
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
    cgset -r memory.limit_in_bytes=0x1000000 test1 || return 1
    [ $? -ne 0 ] && echo "failed to cgset memory.limit_in_bytes" && return 1
    cgset -r memory.memsw.limit_in_bytes=0x8000000 test1 || return 1
    [ $? -ne 0 ] && echo "failed to cgset memory.memsw.limit_in_bytes" && return 1
    set_thp_never
    return 0
}

cleanup_force_swapin_readahead() {
    set_thp_always
    swapoff $WDIR/swapfile
    rm -rf $WDIR/swapfile
    __cleanup_memcg
}

control_force_swapin_readahead() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "malloc_madv_willneed start")
            cgclassify -g cpu,memory:test1 $pid || set_return_code CGCLASSIFY_FAIL
            kill -SIGUSR1 $pid
            ;;
        "call madvise with MADV_WILLNEED")
            echo 3 > /proc/sys/vm/drop_caches
            gawk '
                BEGIN {gate=0;}
                /^[0-9]/ {
                    if ($0 ~ /^700000000000/) {
                        gate = 1;
                    } else {
                        gate = 0;
                    }
                }
                {if (gate==1) {print $0;}}
            ' /proc/$pid/smaps > $TMPF.smaps_before
            cp /proc/meminfo $TMPF.meminfo_before
            $PAGETYPES -r -p $pid -a 0x700000000,0x700003800 > $TMPF.page-types.1
            cgset -r memory.limit_in_bytes=0x8000000 test1 || set_return_code CGSET_FAIL
            kill -SIGUSR1 $pid
            ;;
        "malloc_madv_willneed exit")
            gawk '
                BEGIN {gate=0;}
                /^[0-9]/ {
                    if ($0 ~ /^700000000000/) {
                        gate = 1;
                    } else {
                        gate = 0;
                    }
                }
                {if (gate==1) {print $0;}}
            ' /proc/$pid/smaps > $TMPF.smaps_after
            cp /proc/meminfo $TMPF.meminfo_after
            $PAGETYPES -r -p $pid -a 0x700000000,0x700003800 > $TMPF.page-types.2
            kill -SIGUSR1 $pid
            set_return_code "EXIT"
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_force_swapin_readahead() {
    check_system_default

    FALSENEGATIVE=true
    count_testcount
    if [ "$(grep ^Swap: $TMPF.smaps_before 2> /dev/null | awk '{print $2}')" -gt 0 ] ; then
        count_success "swap used"
    else
        count_failure "swap not used"
    fi
    count_testcount
    if [ "$(grep ^Swap: $TMPF.smaps_after 2> /dev/null | awk '{print $2}')" -eq 0 ] ; then
        count_success "swapped in forcibly"
    else
        count_failure "swap still remains ($(grep ^Swap: $TMPF.smaps_after | awk '{print $2}') kB) after madvise(MADV_WILLNEED)"
    fi
    FALSENEGATIVE=false

    count_testcount
    local sc1=$(grep ^SwapCached: $TMPF.meminfo_before 2> /dev/null | awk '{print $2}')
    local sc2=$(grep ^SwapCached: $TMPF.meminfo_after 2> /dev/null | awk '{print $2}')
    if [ "$sc1" -lt "$sc2" ] ; then
        count_success "some swap data is loaded on swapcache forcibly"
    else
        count_failure "swapin didn't work (before $sc1, after $sc2)"
    fi
}
