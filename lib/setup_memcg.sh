# CGROUPVER=v1
CGDIR=/sys/fs/cgroup
MEMCGDIR=/sys/fs/cgroup/memory
CPUCGDIR=/sys/fs/cgroup/cpu
CPUSETCGDIR=/sys/fs/cgroup/cpuset

# TODO: better way to get current operating cgroup version?
if [ -d "$MEMCGDIR" ] ; then
	CGROUPVER=v1
else
	CGROUPVER=v2
fi

create_cgroup() {
	delete_cgroup 2> /dev/null
	if [ "$CGROUPVER" = v1 ] ; then
		mkdir -p $MEMCGDIR/test1 $MEMCGDIR/test2 || return 1
		mkdir -p $CPUCGDIR/test1 $CPUCGDIR/test2 || return 1
		mkdir -p $CPUSETCGDIR/test1 $CPUSETCGDIR/test2 || return 1
	elif [ "$CGROUPVER" = v2 ] ; then
		echo "+cpu +cpuset +memory" > $CGDIR/cgroup.subtree_control
		mkdir -p $CGDIR/test1 $CGDIR/test2 || return 1
	fi
}

delete_cgroup() {
	if [ "$CGROUPVER" = v1 ] ; then
		rmdir $MEMCGDIR/test1 $MEMCGDIR/test2
		rmdir $CPUCGDIR/test1 $CPUCGDIR/test2
		rmdir $CPUSETCGDIR/test1 $CPUSETCGDIR/test2
	elif [ "$CGROUPVER" = v2 ] ; then
		rmdir $CGDIR/test1 $CGDIR/test2
	fi
}

set_cgroup_value() {
	if [ "$CGROUPVER" = v1 ] ; then
		local cnt=$1
		local cg=$2
		local file=$3
		local val=$4

		echo "echo $val > $CGDIR/$cnt/$cg/$file"
		echo $val > $CGDIR/$cnt/$cg/$file || return 1
	elif [ "$CGROUPVER" = v2 ] ; then
		local cg=$1
		local file=$2
		local val=$3

		echo "echo $val > $CGDIR/$cg/$file"
		echo $val > $CGDIR/$cg/$file || return 1
	fi
}

move_process_cgroup() {
	local cg=$1
	shift 1
	local pids="$@"

	echo "CGROUP $FUNCNAME: $@ $CGROUPVER"
	if [ "$CGROUPVER" = v1 ] ; then
		echo "echo $pids > $MEMCGDIR/$cg/cgroup.procs"
		echo $pids > $CGDIR/cpu/$cg/cgroup.procs || return 1
		# echo $pids > $CGDIR/cpuset/$cg/cgroup.procs || return 1
		echo $pids > $CGDIR/memory/$cg/cgroup.procs || return 1
		cat $MEMCGDIR/$cg/cgroup.procs
	elif [ "$CGROUPVER" = v2 ] ; then
		echo "echo $pids > $CGDIR/$cg/cgroup.procs"
		echo $pids > $CGDIR/$cg/cgroup.procs || return 1
		cat $CGDIR/$cg/cgroup.procs
	fi
}

SWAPFILE=$TDIR/swapfile

__prepare_swap_device() {
	local count=$1
	[ $? -ne 0 ] && echo "failed to __prepare_memcg" && return 1
	rm -f $SWAPFILE
	dd if=/dev/zero of=$SWAPFILE bs=4096 count=$count > /dev/null 2>&1
	[ $? -ne 0 ] && echo "failed to create $SWAPFILE" && return 1
	chmod 0600 $SWAPFILE
	mkswap $SWAPFILE
	echo "swapon $SWAPFILE"
	swapon $SWAPFILE || return 1
	swapon -s
}

__cleanup_swap_device() {
	swapon -s
	swapoff $SWAPFILE
	ipcrm --all
	rm -rf $SWAPFILE
}

get_tasks_cgroup() {
	local cg=$1

	if [ "$CGROUPVER" = v1 ] ; then
		cat $MEMCGDIR/$cg/cgroup.procs
	elif [ "$CGROUPVER" = v2 ] ; then
		cat $CGDIR/$cg/cgroup.procs
	fi
}
