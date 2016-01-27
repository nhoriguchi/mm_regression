HUGETLBDIR=`grep hugetlbfs /proc/mounts | head -n1 | cut -f2 -d' '`

hugetlb_support_check() {
	if [ ! -d /sys/kernel/mm/hugepages ] ; then
		echo_log "hugetlbfs not supported on your system."
		return 1
	fi

	if [ ! -d "$HUGETLBDIR" ] ; then
		echo_log "hugetlbfs not mounted"
		return 1
	fi

	return 0
}

hugepage_size_support_check() {
	if [ ! -d /sys/kernel/mm/hugepages/hugepages-${HUGEPAGESIZE}kB ] ; then
		echo_log "$HUGEPAGESIZE kB hugepage is not supported"
		return 1
	fi

	return 0
}

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

get_available_pool_size() {
	find /sys/devices/system/ -type d | grep hugepages- | cut -f2 -d'-' | sort -ur -k1n
}

get_hugepage_total_node() {
	cat /sys/devices/system/node/node$1/hugepages/hugepages-$2/nr_hugepages
}

get_hugepage_free_node() {
	cat /sys/devices/system/node/node$1/hugepages/hugepages-$2/free_hugepages
}

get_hugepage_surplus_node() {
	cat /sys/devices/system/node/node$1/hugepages/hugepages-$2/surplus_hugepages
}

get_hugepage_inuse_node() {
	echo $[$(get_hugepage_total_node $1 $2) + $(get_hugepage_surplus_node $1 $2) - $(get_hugepage_free_node $1 $2)]
}

show_hugetlb_pool() {
	local total=$(get_hugepage_total)
	local free=$(get_hugepage_free)
	local reserved=$(get_hugepage_reserved)
	local surplus=$(get_hugepage_surplus)

    echo "hugetlb pool (total/free/rsvd/surp): $total/$free/$reserved/$surplus"
	if [ ! "$NUMNODE" ] || [ "$NUMNODE" -eq 0 ] ; then
		return
	fi
	if [ "$total" -ne 0 ] || [ "$free" -ne 0 ] || [ "$reserved" -ne 0 ] || [ "$surplus" -ne 0 ] ; then
		for size in $(get_available_pool_size) ; do
			for i in $(seq 0 $[NUMNODE - 1]) ; do
				echo "node:$i, size:$size (total/free/inuse/surp): $(get_hugepage_total_node $i $size)/$(get_hugepage_free_node $i $size)/$(get_hugepage_inuse_node $i $size)/$(get_hugepage_surplus_node $i $size)"
			done
		done
	fi
}

# make sure that hugetlb pool is empty at the beginning/ending of the testcase
__hugetlb_empty_check() {
    [ $(get_hugepage_total) -eq 0 ] || return 1
    [ $(get_hugepage_free) -eq 0 ] || return 1
    [ $(get_hugepage_reserved) -eq 0 ] || return 1
    [ $(get_hugepage_surplus) -eq 0 ] || return 1
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

__set_and_check_hugetlb_pool() {
    local expected_total=$1
    local expected_free=$2
    local expected_reserved=$3
    local expected_surplus=$4

    [ ! "$expected_total" ] && echo "$FUNCNAME: expected_total is not specified." && return 1
    [ ! "$expected_free" ] && expected_free=$expected_total
    [ ! "$expected_reserved" ] && expected_reserved=0
    [ ! "$expected_surplus" ] && expected_surplus=0

    sysctl -q vm.nr_hugepages=$expected_total
    [ $(get_hugepage_total)    -eq $expected_total ]    || return 1
    [ $(get_hugepage_free)     -eq $expected_free ]     || return 1
    [ $(get_hugepage_reserved) -eq $expected_reserved ] || return 1
    [ $(get_hugepage_surplus)  -eq $expected_surplus ]  || return 1
    return 0
}

set_and_check_hugetlb_pool() {
    count_testcount
    if __set_and_check_hugetlb_pool $1 $2 $3 $4 ; then
        count_success "set hugetlb pool size to $1: OK"
        return 0
    else
        count_failure "set hugetlb pool size to $1: NG"
        show_hugetlb_pool
        return 1
    fi
}

set_hugetlb_overcommit() {
    sysctl vm.nr_overcommit_hugepages=$1
}

cleanup_hugetlb_config() {
	if [ "$WDIR/hugetlbfs" ] ; then
		rm -rf $WDIR/hugetlbfs/* 2>&1 > /dev/null
		umount -f $WDIR/hugetlbfs 2>&1 > /dev/null
	fi
	sysctl -q vm.nr_hugepages=0
	kill_all_subprograms
	all_unpoison
	ipcrm --all > /dev/null 2>&1
	show_hugetlb_pool
}
