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

do_memory_hotremove() { bash memory_hotremove.sh ${PAGETYPES} $1; }

reonline_memblocks() {
    local block=""
    local memblocks="$(find /sys/devices/system/memory/ -maxdepth 1 -type d | grep "memory/memory" | sed 's/.*memory//')"
    for mb in $memblocks ; do
        if [ "$(cat /sys/devices/system/memory/memory${mb}/state)" == "offline" ] ; then
            block="$block $mb"
        fi
    done
    echo "offlined memory blocks: $block"
    for mb in $block ; do
        echo "Re-online memory block $mb"
        echo online > /sys/devices/system/memory/memory${mb}/state
    done
}

yum install -y numactl* > /dev/null
