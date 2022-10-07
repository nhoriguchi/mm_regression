HUGETLBFSDIR=tmp/hugetlbfs

prepare_1GB_hugetlb() {
	if [ ! -f "/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages" ] ; then
		echo "no 1GB hugetlb directory. abort." >&2
		return 1
	fi

	echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages || return 1
	echo 10 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages || return 1
	echo 0 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_overcommit_hugepages

	[ ! -d "$HUGETLBFSDIR" ] && mkdir -p "$HUGETLBFSDIR"
	mount -t hugetlbfs -o pagesize=1G,size=1G none "$HUGETLBFSDIR"
	find /sys/kernel/mm/hugepages/hugepages-1048576kB -type f | grep hugepages$ | while read f ; do
		echo "$f $(cat $f)"
	done

	if [ "$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)" -lt 2 ] ; then
		echo "enough 1GB hugetlb not allocated. abort." >&2
		return 1
	fi

	return 0
}

cleanup_1GB_hugetlb() {
	rm -rf $HUGETLBFSDIR/*
	umount "$HUGETLBFSDIR"
	echo 0 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
}

show_1GB_pool() {
	local vm=$1

	if [ "$vm" ] ; then
		ssh $vm "cat /sys/kernel/mm/hugepages/hugepages-1048576kB/{nr_hugepages,free_hugepages,resv_hugepages,surplus_hugepages}"
	else
		echo "total: $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)"
		echo "free: $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages)"
		echo "resv: $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/resv_hugepages)"
		echo "surp: $(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/surplus_hugepages)"
	fi
}
