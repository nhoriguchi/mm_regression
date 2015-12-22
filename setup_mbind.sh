#!/bin/bash

. $TCDIR/lib/mm.sh

_control() { control_mbind "$1" "$2"; }
_prepare() { prepare_mbind; }
_cleanup() { cleanup_mbind; }

prepare_mbind() {
	prepare_mm_generic || return 1

	if [ "$TESTFILE" ] ; then
		dd if=/dev/urandom of=$TESTFILE bs=4096 count=$[512*10]
	fi
}

cleanup_mbind() {
	cleanup_mm_generic
}

control_mbind() {
    local pid="$1"
    local line="$2"

    echo_log "$line"
    case "$line" in
        "before mbind")
            $PAGETYPES -p $pid -a 0x700000000+0x2000 -Nrl >> ${OFILE}
            cat /proc/$pid/numa_maps | grep "^70" > $TMPD/numa_maps1
            kill -SIGUSR1 $pid
            ;;
        "entering busy loop")
            sleep 0.5
            kill -SIGUSR1 $pid
            ;;
        "mbind exit")
            $PAGETYPES -p $pid -a 0x700000000+0x2000 -Nrl >> ${OFILE}
            cat /proc/$pid/numa_maps | grep "^70" > $TMPD/numa_maps2
            kill -SIGUSR1 $pid
            set_return_code EXIT
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

# inside cheker you must tee output in you own.
check_mbind() {
    check_mbind_numa_maps "700000000000"  || return 1
    check_mbind_numa_maps "700000200000"  || return 1
    check_mbind_numa_maps "700000400000"  || return 1
}

get_numa_maps_nodes() {
    local numa_maps=$1
    local vma_start=$2
    grep "^${vma_start} " ${numa_maps} | tr ' ' '\n' | grep -E "^N[0-9]=" | tr '\n' ' '
}

check_mbind_numa_maps() {
    local address=$1
    local node1=$(get_numa_maps_nodes $TMPD/numa_maps1 ${address})
    local node2=$(get_numa_maps_nodes $TMPD/numa_maps2 ${address})

    count_testcount
    if [ ! -f $TMPD/numa_maps1 ] || [ ! -f $TMPD/numa_maps2 ] ; then
        count_failure "numa_maps file not exist."
        return 1
    fi

    if [ "$node1" == "$node2" ] ; then
        count_failure "vaddr ${address} is not migrated. map1=${node1}, map2=${node2}."
        return 1
    else
        count_success "vaddr ${address} is migrated."
    fi
}

control_mbind_fuzz() {
    echo_log "start mbind_fuzz"
    eval ${test_mbind_fuzz} -f $TESTFILE -n 10 -N $MBIND_FUZZ_HP_NR -t $MBIND_FUZZ_TYPE > $TMPD/fuz.out 2>&1 &
    local pid=$!
    echo_log "10 processes running"
    sleep $MBIND_FUZZ_DURATION
    grep -i ^huge /proc/meminfo
    pkill -SIGUSR1 $pid
    grep -i ^huge /proc/meminfo
    echo_log "Done, kill the processes"
    set_return_code EXIT
}

control_mbind_fuzz_normal_heavy() {
    echo_log "start mbind_$FLAVOR"
    for i in $(seq $MBIND_FUZZ_THREADS) ; do
        $test_mbind_fuzz -f $TESTFILE -n $MBIND_FUZZ_NR_PG \
						 -t $MBIND_FUZZ_TYPE > $TMPD/fuz.out 2>&1 &
    done

    echo_log "... (running $MBIND_FUZZ_DURATION secs)"
    sleep $MBIND_FUZZ_DURATION
    echo_log "Done, kill the processes"
    pkill -SIGUSR1 -f $test_mbind_fuzz
    set_return_code EXIT
}

control_mbind_unmap_race() {
    echo_log "start mbind_unmap_race"
    for i in $(seq $MBIND_FUZZ_THREADS) ; do
        $test_mbind_unmap_race -f $TESTFILE -n $MBIND_FUZZ_NR_PG \
						 -t $MBIND_FUZZ_TYPE -N 2 > $TMPD/fuz.out 2>&1 &
    done

    echo_log "... (running $MBIND_FUZZ_DURATION secs)"
    sleep $MBIND_FUZZ_DURATION
    echo_log "Done, kill the processes"
    pkill -SIGUSR1 -f $test_mbind_unmap_race
    set_return_code EXIT
}
