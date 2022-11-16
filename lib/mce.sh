#!/bin/bash

MCEINJECT=$(dirname $(readlink -f $BASH_SOURCE))/mceinj.sh

SYSFS_MCHECK=/sys/devices/system/machinecheck

if [ "$UNPOISON" = true ] ; then
	all_unpoison() {
		page-types -b hwpoison -x -N;
	}
else
	all_unpoison() { true; }
fi

get_HWCorrupted() { grep "HardwareCorrupted" /proc/meminfo | tr -s ' ' | cut -f2 -d' '; }
save_nr_corrupted_before() { get_HWCorrupted   > $TMPD/hwcorrupted1; }
save_nr_corrupted_inject() { get_HWCorrupted   > $TMPD/hwcorrupted2; }
save_nr_corrupted_unpoison() { get_HWCorrupted > $TMPD/hwcorrupted3; }
save_nr_corrupted() { get_HWCorrupted > $TMPD/hwcorrupted"$1"; }
show_nr_corrupted() {
    if [ -e $TMPD/hwcorrupted"$1" ] ; then
        cat $TMPD/hwcorrupted"$1" | tr -d '\n'
    else
        echo -n 0
    fi
}

check_mce_capability() {
	if ! grep -q "mcgcap=" $GTMPD/cap_check 2> /dev/null ; then
		pushd $(dirname $BASH_SOURCE)/cap_check > /dev/null
		make check > $GTMPD/cap_check
		# TEMPORARY DIRTY HACK, SHOULD BE IMPROVED !!
		if [ $? -ne 0 ] ; then
			echo "failed to build cap_check module ... give up this testcase"
			MCE_SER_SUPPORTED=
		fi
		popd > /dev/null
	fi
	local mcgcap=$(grep "mcgcap=" $GTMPD/cap_check | cut -f2 -d= | tail -n1)
	local mce_ser=$(($mcgcap & (1 << 24)))
	if [ "$mce_ser" -gt 0 ] ; then
		echo "MCE_SER_P supported"
		MCE_SER_SUPPORTED=true
	else
		echo "MCE_SER_P NOT supported"
		MCE_SER_SUPPORTED=
		if [ "$ERROR_TYPE" = mce-srao ] ; then
			return 1
		fi
	fi
}

# if accounting corrupted, "HardwareCorrupted" value could be very large
# number, which bash cannot handle as numerical values. So we do here
# comparation as string
__check_nr_hwcorrupted() {
	local cnt1=$(show_nr_corrupted 1)
	local cnt2=$(show_nr_corrupted 2)
	local cnt3=$(show_nr_corrupted 3)

    count_testcount
    if [ "$cnt1" == "$cnt2" ] ; then
        count_failure "hwpoison inject didn't raise \"HardwareCorrupted\" value ($cnt1 -> $cnt2)"
    elif [ "$cnt1" != "$cnt3" ] ; then
        count_failure "accounting \"HardwareCorrupted\" did not back to original value ($cnt1 -> $cnt2 -> $cnt3)"
    else
        count_success "accounting \"HardwareCorrupted\" was raised and reduced back to original value ($cnt1 -> $cnt2 -> $cnt3)"
    fi
}

__check_nr_hwcorrupted_consistent() {
	local cnt1=$(show_nr_corrupted 1)
	local cnt3=$(show_nr_corrupted 3)
    count_testcount
    if [ "$cnt1" == "$cnt3" ] ; then
        count_success "accounting \"HardwareCorrupted\" consistently."
    else
        count_failure "accounting \"HardwareCorrupted\" did not back to original value ($cnt1 -> $cnt3)"
    fi
}

__check_nr_hwcorrupted_increased() {
    count_testcount
    if [ "$(show_nr_corrupted 1)" -lt "$(show_nr_corrupted 3)" ] ; then
        count_success "accounting \"HardwareCorrupted\" increased."
	else
        count_failure "accounting \"HardwareCorrupted\" not increased."
	fi
}

check_nr_hwcorrupted() {
	if [ "$UNPOISON" = true ] ; then
		if [ -s "$TMPD/hwcorrupted2" ] ; then
			__check_nr_hwcorrupted
		else
			__check_nr_hwcorrupted_consistent
		fi
	else
		__check_nr_hwcorrupted_increased
	fi
}

BASEVFN=0x700000000

# <2017-05-09 Tue 15:48> latest development kernel make /dev/mcelog character
# device as depricated, so we need turn on the config CONFIG_X86_MCE_INJECT
# and CONFIG_X86_MCELOG_LEGACY in your kernel.
if ! lsmod | grep mce_inject > /dev/null ; then
    if ! modprobe mce_inject ; then
		echo "You might have to enable CONFIG_X86_MCELOG_LEGACY in your kernel."
	fi
fi

if ! lsmod | grep hwpoison_inject > /dev/null ; then
    modprobe hwpoison_inject
fi

# <2020-10-24 Sat 22:03> Now mce-inject binary is placed on build/ so we
# should always skip this check, but keep this code in case.
if ! which mce-inject > /dev/null || [[ ! -s "$(which mce-inject)" ]] ; then
    echo "No mce-inject installed."
    # http://git.kernel.org/cgit/utils/cpu/mce/mce-inject.git
    rm -rf ./mce-inject
    git clone https://github.com/Naoya-Horiguchi/mce-inject
    pushd mce-inject
    make
    make install
    popd
fi

# clear all poison pages before starting test
all_unpoison
echo 0 > /proc/sys/vm/memory_failure_early_kill
