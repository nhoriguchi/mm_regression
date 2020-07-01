#!/bin/bash

ls -1 /proc | grep ^[0-9] | sort -n | tail -n10 | while read pid ; do
    if grep ^VmFlags: /proc/$pid/smaps | grep "pf" > /dev/null ; then
        # echo $pid "$(cat /proc/$pid/cmdline)"
        grep -hr -e ^VmFlags -e ^[0-9] /proc/$pid/smaps | grep -B1 -e "pf" | grep ^[0-9] | cut -f1 -d' ' | tr '-' ' ' > $TMPD/$pid.pfnmap_ranges
        cmd="page-types -p $pid -Nl"

        while read spfn epfn ; do
            cmd=$(printf "$cmd -a 0x%lx,0x%lx" $[0x$spfn / 4096] $[0x$epfn / 4096])
        done < $TMPD/$pid.pfnmap_ranges
        eval $cmd                > $TMPD/$pid.pagemap
        cat /proc/$pid/smaps     > $TMPD/$pid.smaps
        cat /proc/$pid/maps      > $TMPD/$pid.maps
        cat /proc/$pid/numa_maps > $TMPD/$pid.numa_maps
    fi
done 2> /dev/null
