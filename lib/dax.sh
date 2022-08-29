check_dax() {
	local pfn="$1"
	
	if [ "$pfn" ] ; then
		pfn=$[pfn*4096]
		for regdir in $(find /sys/bus/nd/devices/ndbus0/ -name "region*") ; do
			local start=$(cat $regdir/resource)
			local size=$(cat $regdir/size)

			# echo "start:$start, size=$size, pfn:$pfn"
			if [ "$[start]" -gt "$[pfn]" ] ; then
				# echo "$[start] > $[pfn]"
				continue
			fi
			if [ "$[start + size]" -le "$[pfn]" ] ; then
				# echo "$[start + size] <= $[pfn]"
				continue
			fi
			printf "pfn:%lx is on pmem (start:%lx, size=%lx)\n" $[pfn>>12] $start $size
			return 0
		done
		printf "pfn:%lx is not on pmem\n" $[pfn>>12]
	fi
	return 1
}
