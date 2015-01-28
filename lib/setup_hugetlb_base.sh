#!/bin/bash

get_hugepage_total() {
    awk '/^HugePages_Total:/ {print $2}' /proc/meminfo
}

get_hugepage_free() {
    awk '/^HugePages_Free:/ {print $2}' /proc/meminfo
}

get_hugepage_reserved() {
    awk '/^HugePages_Rsvd:/ {print $2}' /proc/meminfo
}

get_hugepage_surplus() {
    awk '/^HugePages_Surp:/ {print $2}' /proc/meminfo
}

show_hugetlb_pool() {
    echo "hugetlb pool (total/free/rsvd/surp): $(get_hugepage_total)/$(get_hugepage_free)/$(get_hugepage_reserved)/$(get_hugepage_surplus)"
}

# make sure that hugetlb pool is empty at the beginning/ending of the testcase
__hugetlb_empty_check() {
    [ $(get_hugepage_total) -ne 0 ] && return 1
    [ $(get_hugepage_free) -ne 0 ] && return 1
    [ $(get_hugepage_reserved) -ne 0 ] && return 1
    [ $(get_hugepage_surplus) -ne 0 ] && return 1
    return 0
}

hugetlb_empty_check() {
    count_testcount
    if __hugetlb_empty_check ; then
        count_success "hugetlb pool empty check"
    else
        count_failure "hugetlb pool empty check"
        show_hugetlb_pool
    fi
}
