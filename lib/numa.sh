NUMNODE=$(numactl -H | grep available | cut -f2 -d' ')

numa_check() {
	if ! [ "$NUMNODE" -gt 1 ] ; then
		echo_log "No NUMA system"
		return 1
	fi
	return 0
}

get_numa_maps() { cat /proc/$1/numa_maps; }

do_migratepages() {
	if [ $# -ne 3 ] ; then
		migratepages $1 0 1;
	else
		migratepages "$1" "$2" "$3";
	fi
}

do_memory_hotremove() { bash memory_hotremove.sh page-types $1; }

reonline_memblocks() {
	local block=""
	local memblocks="$(find /sys/devices/system/memory/ -maxdepth 1 -type d | grep "memory/memory" | sed 's/.*memory//')"
	for mb in $memblocks ; do
		if [ "$(cat /sys/devices/system/memory/memory${mb}/state)" == "offline" ] ; then
			block="$block $mb"
		fi
	done
	[ "$block" ] && echo "offlined memory blocks: $block"
	for mb in $block ; do
		echo "Re-online memory block $mb"
		echo online > /sys/devices/system/memory/memory${mb}/state
	done
}

enable_auto_numa() {
	echo 1 > /proc/sys/kernel/numa_balancing
	echo 1 > /proc/sys/kernel/numa_balancing_scan_delay_ms
	echo 100 > /proc/sys/kernel/numa_balancing_scan_period_max_ms
	echo 100 > /proc/sys/kernel/numa_balancing_scan_period_min_ms
	echo 1024 > /proc/sys/kernel/numa_balancing_scan_size_mb
}

disable_auto_numa() {
	echo 0 > /proc/sys/kernel/numa_balancing
	echo 1000 > /proc/sys/kernel/numa_balancing_scan_delay_ms
	echo 60000 > /proc/sys/kernel/numa_balancing_scan_period_max_ms
	echo 1000 > /proc/sys/kernel/numa_balancing_scan_period_min_ms
	echo 256 > /proc/sys/kernel/numa_balancing_scan_size_mb
}

get_numa_maps_node_stat() {
	local pid=$1
	local tmpf=$(mktemp)

	cat <<EOF > $tmpf
res = {}
File.read("/proc/$pid/numa_maps").split("\n").each do |line|
  line.scan(/\bN(\d+)=(\d+)\b/).each do |set|
	if res[set[0]]
      res[set[0]] += set[1].to_i
    else
      res[set[0]] = set[1].to_i
	end
  end
end
p res
EOF
	ruby $tmpf $pid
	rm -f $tmpf
}
