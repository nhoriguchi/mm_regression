#!/bin/bash

read_pagemap() {
    local pid=$1
    local vfn=$2
    local length=$3
    local outfile=$4
    ruby -e 'IO.read("/proc/'$pid'/pagemap", '$length'*8, '$vfn'*8).unpack("Q*").each {|i| printf("%d\n", i & 0xfffffffffff)}' > $outfile
}

control_vma_vm_pfnmap() {
    local pid="$1"
    local line="$2"

    echo_log "$line"
    case "$line" in
        # "waiting")
        "page_fault_done")
            read_pagemap $pid 0x700000000 1 $TMPD/case1
            read_pagemap $pid 0x700000001 1 $TMPD/case2
            read_pagemap $pid 0x700000002 1 $TMPD/case3
            read_pagemap $pid 0x700000000 2 $TMPD/case4
            read_pagemap $pid 0x700000001 2 $TMPD/case5
            read_pagemap $pid 0x700000002 2 $TMPD/case6
            read_pagemap $pid 0x700000003 2 $TMPD/case7
            read_pagemap $pid 0x6ffffffff 8 $TMPD/case8
            cat /proc/$pid/smaps > $TMPD/smaps
            cat /proc/$pid/maps > $TMPD/maps
            cat /proc/$pid/numa_maps > $TMPD/numa_maps
            set_return_code EXIT
            kill -SIGUSR1 $pid
			return 0;
            ;;
        "vma_vm_pfnmap exit")
            kill -SIGUSR1 $pid
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

check_vma_vm_pfnmap() {
    check_system_default
    check_pagemap
    check_smaps
    check_maps
    check_numa_maps
}

check_pagemap() {
    local check=fail

    count_testcount
    if [ "$(cat $TMPD/case1)" -eq 0 ] ; then
        count_failure "case1 returned 0, but should >0"
        return 1
    fi
    if [ "$(cat $TMPD/case2)" -ne 0 ] ; then
        count_failure "case2 returned non-0, but should 0"
        return 1
    fi
    if [ "$(cat $TMPD/case3)" -eq 0 ] ; then
        count_failure "case3 returned 0, but should >0"
        return 1
    fi
    if [ "$(sed -n 1p $TMPD/case4)" -eq 0 ] ; then
        count_failure "case4 line 1 returned 0, but should >0"
        return 1
    fi
    if [ "$(sed -n 2p $TMPD/case4)" -ne 0 ] ; then
        count_failure "case4 line 2 returned non-0, but should 0"
        return 1
    fi
    if [ "$(sed -n 1p $TMPD/case5)" -ne 0 ] ; then
        count_failure "case5 line 1 returned non-0, but should 0"
        return 1
    fi
    if [ "$(sed -n 2p $TMPD/case5)" -eq 0 ] ; then
        count_failure "case5 line 2 returned 0, but should >0"
        return 1
    fi
    if [ "$(sed -n 1p $TMPD/case6)" -eq 0 ] ; then
        count_failure "case6 line 1 returned 0, but should >0"
        return 1
    fi
    if [ "$(sed -n 2p $TMPD/case6)" -ne 0 ] ; then
        count_failure "case6 line 2 returned non-0, but should 0"
        return 1
    fi
    if [ "$(sed -n 1p $TMPD/case7)" -ne 0 ] ; then
        count_failure "case7 line 1 returned non-0, but should 0"
        return 1
    fi
    if [ "$(sed -n 2p $TMPD/case7)" -ne 0 ] ; then
        count_failure "case7 line 2 returned non-0, but should 0"
        return 1
    fi
    count_success "pagemap stored data as expected."
}

check_smaps() {
    count_testcount
    if grep ^700000001000 $TMPD/smaps > /dev/null ; then
        count_success "smaps contains VM_PFNMAP area"
    else
        count_failure "smaps doesn't contain VM_PFNMAP area"
    fi
}

check_maps() {
    count_testcount
    if grep ^700000001000 $TMPD/maps > /dev/null ; then
        count_success "maps contains VM_PFNMAP area"
    else
        count_failure "maps doesn't contain VM_PFNMAP area"
    fi
}

check_numa_maps() {
    count_testcount
    if grep ^700000001000 $TMPD/numa_maps > /dev/null ; then
        count_success "numa_maps contains VM_PFNMAP area"
    else
        count_failure "numa_maps doesn't contain VM_PFNMAP area"
    fi
}
