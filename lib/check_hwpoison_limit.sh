#!/bin/bash

check_hwpoison_limit() {
	local memtotal=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')
	local hwcorrupted=$(grep ^HardwareCorrupted: /proc/meminfo | awk '{print $2}')
	local threshold=$1

	if [ "$[100*hwcorrupted/memtotal]" -ge "$threshold" ] ; then
		return 0
	else
		return 1
	fi
}

check_hwpoison_limit_in_buddy() {
	local threshold=$1
	local order=$2
	local tmpf=$(mktemp)

	[ ! "$order" ] && order=10

	local kpageflags_size=$(wc -c /proc/kpageflags | cut -f1 -d' ')
	local maxpfn=$[kpageflags_size>>3]
	local block=$[2<<order]

	ruby -e 'count=0; block = '$block'; tmp=-1; IO.read("/proc/kpageflags", '$maxpfn'*8, 0).unpack("Q*").each_with_index {|entry, pfn|
  if entry & 0x80000 > 0
    tmp2 = pfn - (pfn % block)
	if tmp != tmp2
      tmp = tmp2
      count += 1
    end
  end
}; printf("%d\n", 100 * count * block / '$maxpfn')' > $tmpf

	local ret=1
	if [ "$(cat $tmpf)" -ge "$threshold" ] ; then
		echo "hwpoison pages affect $(cat $tmpf) % of total memory, that's over threshold ($threshold %)"
		ret=0
	else
		echo "hwpoison pages affect $(cat $tmpf) % of total memory, that's under threshold ($threshold %)"
	fi
	rm $tmpf
	return $ret
}

if [ "$1" = test ] ; then
	check_hwpoison_limit 0 && echo OK || echo NG
	check_hwpoison_limit 3 && echo OK || echo NG
	check_hwpoison_limit_in_buddy 10 1 && echo OK || echo NG
	check_hwpoison_limit_in_buddy 10 10 && echo OK || echo NG
fi
