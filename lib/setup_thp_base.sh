#!/bin/bash

DISTRO=""
THPDIR=""
KHPDDIR=""

# if grep "Red Hat Enterprise Linux.*release 6" /etc/system-release > /dev/null ; then
if uname -r  | grep "\.el6" > /dev/null ; then
    DISTRO="RHEL6"
    THPDIR="/sys/kernel/mm/redhat_transparent_hugepage"
    KHPDDIR="/sys/kernel/mm/redhat_transparent_hugepage/khugepaged"
elif uname -r  | grep "\.el7" > /dev/null ; then
    DISTRO="RHEL7"
    THPDIR="/sys/kernel/mm/transparent_hugepage"
    KHPDDIR="/sys/kernel/mm/transparent_hugepage/khugepaged"
elif uname -r  | grep "\.fc[12][0-9]" > /dev/null ; then
    DISTRO="Fedora"
    THPDIR="/sys/kernel/mm/transparent_hugepage"
    KHPDDIR="/sys/kernel/mm/transparent_hugepage/khugepaged"
else
    DISTRO="upstream"
    THPDIR="/sys/kernel/mm/transparent_hugepage"
    KHPDDIR="/sys/kernel/mm/transparent_hugepage/khugepaged"
fi

RHELOPT="" ; [ "$DISTRO" = "RHEL6" ] && RHELOPT="-R"

[ ! -d "$THPDIR" ] && echo "Kernel not support thp." >&2 && exit 1

ulimit -s unlimited

## routines

get_thp()         { cat $THPDIR/enabled | sed -r -e 's/.*\[(.*)\].*/\1/'; }
set_thp_always()  { echo "always" > $THPDIR/enabled; }
set_thp_madvise() {
    if [ "$DISTRO" == "Fedora" ] || [ "$DISTRO" == "upstream" ] ; then
        echo "madvise" > $THPDIR/enabled;
    fi
}
set_thp_never()   { echo "never" > $THPDIR/enabled; }
get_thp_defrag()  { cat $THPDIR/defrag | sed -r -e 's/.*\[(.*)\].*/\1/'; }
set_thp_defrag_always()  { echo "always" > $THPDIR/defrag; }
set_thp_defrag_madvise() { echo "madvise" > $THPDIR/defrag; }
set_thp_defrag_never()   { echo "never" > $THPDIR/defrag; }
khpd_on()  { echo 1 > $KHPDDIR/defrag; }
khpd_off() { echo 0 > $KHPDDIR/defrag; }
compact_memory() { echo 1 > /proc/sys/vm/compact_memory; }

get_khpd_alloc_sleep_millisecs() { cat $KHPDDIR/alloc_sleep_millisecs; }
get_khpd_defrag()                { cat $KHPDDIR/defrag; }
get_khpd_max_ptes_none()         { cat $KHPDDIR/max_ptes_none; }
get_khpd_pages_to_scan()         { cat $KHPDDIR/pages_to_scan; }
get_khpd_scan_sleep_millisecs()  { cat $KHPDDIR/scan_sleep_millisecs; }
get_khpd_full_scans()            { cat $KHPDDIR/full_scans; }
get_khpd_pages_collapsed()       { cat $KHPDDIR/pages_collapsed; }
set_khpd_alloc_sleep_millisecs() { echo $1 > $KHPDDIR/alloc_sleep_millisecs; }
set_khpd_defrag()                {
    local val=$1
    if [ "$DISTRO" = "RHEL6" ] ; then
        [ "$val" -eq 0 ] && val="no" || val="yes"
    fi
    echo $val > $KHPDDIR/defrag;
}
set_khpd_max_ptes_none()         { echo $1 > $KHPDDIR/max_ptes_none; }
set_khpd_pages_to_scan()         { echo $1 > $KHPDDIR/pages_to_scan; }
set_khpd_scan_sleep_millisecs()  { echo $1 > $KHPDDIR/scan_sleep_millisecs; }
default_khpd_alloc_sleep_millisecs=60000
default_khpd_defrag=1
default_khpd_max_ptes_none=511
default_khpd_pages_to_scan=4096
default_khpd_scan_sleep_millisecs=10000
default_tuning_parameters() {
    set_thp_madvise
    set_thp_defrag_always
    set_khpd_defrag 1
    set_khpd_alloc_sleep_millisecs $default_khpd_alloc_sleep_millisecs
    set_khpd_defrag                $default_khpd_defrag
    set_khpd_max_ptes_none         $default_khpd_max_ptes_none
    set_khpd_pages_to_scan         $default_khpd_pages_to_scan
    set_khpd_scan_sleep_millisecs  $default_khpd_scan_sleep_millisecs
}
set_thp_params_for_testing() {
    set_khpd_alloc_sleep_millisecs 100
    set_khpd_scan_sleep_millisecs  100
    set_khpd_pages_to_scan         $[4096*10]
}
show_current_tuning_parameters() {
    echo "thp                     : `get_thp`"
    echo "deflag                  : `get_thp_defrag`"
    echo "alloc_sleep_millices    : `get_khpd_alloc_sleep_millisecs`"
    echo "defrag (in khpd)        : `get_khpd_defrag               `"
    echo "max_ptes_none           : `get_khpd_max_ptes_none        `"
    echo "pages_to_scan           : `get_khpd_pages_to_scan        `"
    echo "scan_sleep_millisecs    : `get_khpd_scan_sleep_millisecs `"
}
show_current_tuning_parameters_compact() {
    echo "thp: `get_thp`, deflag: `get_thp_defrag`, alloc_sleep_millices: `get_khpd_alloc_sleep_millisecs`, defrag (in khpd): `get_khpd_defrag`, max_ptes_none: `get_khpd_max_ptes_none`, pages_to_scan: `get_khpd_pages_to_scan`, scan_sleep_millisecs: `get_khpd_scan_sleep_millisecs`"
}

thp_fault_alloc=0
thp_fault_fallback=0
thp_collapse_alloc=0
thp_collapse_alloc_failed=0
thp_split=0
get_vmstat_thp() {
    thp_fault_alloc=`grep thp_fault_alloc /proc/vmstat | cut -f2 -d' '`
    thp_fault_fallback=`grep thp_fault_fallback /proc/vmstat | cut -f2 -d' '`
    thp_collapse_alloc=`grep "thp_collapse_alloc " /proc/vmstat | cut -f2 -d' '`
    thp_collapse_alloc_failed=`grep thp_collapse_alloc_failed /proc/vmstat | cut -f2 -d' '`
    thp_split=`grep thp_split /proc/vmstat | cut -f2 -d' '`
}
show_stat_thp() {
    get_vmstat_thp
    echo   "        clpsd, fscan, fltal, fltfb, clpal, clpaf, split"
    printf "Result  %5s, %5s, %5s, %5s, %5s, %5s, %5s\n" `get_khpd_pages_collapsed` `get_khpd_full_scans` $thp_fault_alloc $thp_fault_fallback $thp_collapse_alloc $thp_collapse_alloc_failed $thp_split
}
