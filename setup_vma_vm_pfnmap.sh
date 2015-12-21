#!/bin/bash

check_and_define_tp test_vma_vm_pfnmap

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

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "waiting")
            read_pagemap $pid 0x700000000 1 $TMPF.case1
            read_pagemap $pid 0x700000001 1 $TMPF.case2
            read_pagemap $pid 0x700000002 1 $TMPF.case3
            read_pagemap $pid 0x700000000 2 $TMPF.case4
            read_pagemap $pid 0x700000001 2 $TMPF.case5
            read_pagemap $pid 0x700000002 2 $TMPF.case6
            read_pagemap $pid 0x700000003 2 $TMPF.case7
            read_pagemap $pid 0x6ffffffff 8 $TMPF.case8
            cat /proc/$pid/smaps > $TMPF.smaps
            cat /proc/$pid/maps > $TMPF.maps
            cat /proc/$pid/numa_maps > $TMPF.numa_maps
            kill -SIGUSR1 $pid
            ;;
        "vma_vm_pfnmap exit")
            kill -SIGUSR1 $pid
            set_return_code "EXIT"
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
    if [ "$(cat $TMPF.case1)" -eq 0 ] ; then
        count_failure "case1 returned 0, but should >0"
        return 1
    fi
    if [ "$(cat $TMPF.case2)" -ne 0 ] ; then
        count_failure "case2 returned non-0, but should 0"
        return 1
    fi
    if [ "$(cat $TMPF.case3)" -eq 0 ] ; then
        count_failure "case3 returned 0, but should >0"
        return 1
    fi
    if [ "$(sed -n 1p $TMPF.case4)" -eq 0 ] ; then
        count_failure "case4 line 1 returned 0, but should >0"
        return 1
    fi
    if [ "$(sed -n 2p $TMPF.case4)" -ne 0 ] ; then
        count_failure "case4 line 2 returned non-0, but should 0"
        return 1
    fi
    if [ "$(sed -n 1p $TMPF.case5)" -ne 0 ] ; then
        count_failure "case5 line 1 returned non-0, but should 0"
        return 1
    fi
    if [ "$(sed -n 2p $TMPF.case5)" -eq 0 ] ; then
        count_failure "case5 line 2 returned 0, but should >0"
        return 1
    fi
    if [ "$(sed -n 1p $TMPF.case6)" -eq 0 ] ; then
        count_failure "case6 line 1 returned 0, but should >0"
        return 1
    fi
    if [ "$(sed -n 2p $TMPF.case6)" -ne 0 ] ; then
        count_failure "case6 line 2 returned non-0, but should 0"
        return 1
    fi
    if [ "$(sed -n 1p $TMPF.case7)" -ne 0 ] ; then
        count_failure "case7 line 1 returned non-0, but should 0"
        return 1
    fi
    if [ "$(sed -n 2p $TMPF.case7)" -ne 0 ] ; then
        count_failure "case7 line 2 returned non-0, but should 0"
        return 1
    fi
    count_success "pagemap stored data as expected."
}

check_smaps() {
    count_testcount
    if grep ^700000001000 $TMPF.smaps > /dev/null ; then
        count_success "smaps contains VM_PFNMAP area"
    else
        count_failure "smaps doesn't contain VM_PFNMAP area"
    fi
}

check_maps() {
    count_testcount
    if grep ^700000001000 $TMPF.maps > /dev/null ; then
        count_success "maps contains VM_PFNMAP area"
    else
        count_failure "maps doesn't contain VM_PFNMAP area"
    fi
}

check_numa_maps() {
    count_testcount
    if grep ^700000001000 $TMPF.numa_maps > /dev/null ; then
        count_success "numa_maps contains VM_PFNMAP area"
    else
        count_failure "numa_maps doesn't contain VM_PFNMAP area"
    fi
}
