#!/bin/bashp

MCEINJECT=$(dirname $(readlink -f $BASH_SOURCE))/mceinj.sh

SYSFS_MCHECK=/sys/devices/system/machinecheck

all_unpoison() { $PAGETYPES -b hwpoison -x -N; }

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
	# If user explicitly said the system support MCE_SER, let's believe it.
	if [ "$MCE_SER_SUPPORTED" ] ; then
		return 0
	else
		echo "If you really do mce-srao testcase, please define environment"
		echo "variable MCE_SER_SUPPORTED"
		return 1
	fi

	# TODO: need more elegant solution
    if [ ! -e check_mce_capability.ko ] ; then
        stap -p4 -g -m check_mce_capability.ko check_mce_capability.stp
        if [ $? -ne 0 ] ; then
            echo "Failed to build stap script" >&2
            return 1
        fi
    fi
    local cap=$(staprun check_mce_capability.ko | cut -f2 -d' ')
    [ ! "$cap" ] && echo "Failed to retrieve MCE CAPABILITY info. SKIPPED." && return 1
    # check 1 << 24 (MCG_SER_P)
    if [ $[ $cap & 16777216 ] -eq 16777216 ] ; then
        return 0
    else
        echo "MCE_SER_P is cleared in the current system."
        return 1
    fi
}

# if accounting corrupted, "HardwareCorrupted" value could be very large
# number, which bash cannot handle as numerical values. So we do here
# comparation as string
__check_nr_hwcorrupted() {
    count_testcount
    if [ "$(show_nr_corrupted 1)" == "$(show_nr_corrupted 2)" ] ; then
        count_failure "hwpoison inject didn't raise \"HardwareCorrupted\" value ($(show_nr_corrupted 1) -> $(show_nr_corrupted 2))"
    elif [ "$(show_nr_corrupted 1)" != "$(show_nr_corrupted 3)" ] ; then
        count_failure "accounting \"HardwareCorrupted\" did not back to original value ($(show_nr_corrupted 1) -> $(show_nr_corrupted 2) -> $(show_nr_corrupted 3))"
    else
        count_success "accounting \"HardwareCorrupted\" was raised and reduced back to original value ($(show_nr_corrupted 1) -> $(show_nr_corrupted 2) -> $(show_nr_corrupted 3))"
    fi
}

__check_nr_hwcorrupted_consistent() {
    count_testcount
    if [ "$(show_nr_corrupted 1)" == "$(show_nr_corrupted 3)" ] ; then
        count_success "accounting \"HardwareCorrupted\" consistently."
    else
        count_failure "accounting \"HardwareCorrupted\" did not back to original value ($(show_nr_corrupted 1) -> $(show_nr_corrupted 3))"
    fi
}

check_nr_hwcorrupted() {
	if [ -s "$TMPD/hwcorrupted2" ] ; then
		__check_nr_hwcorrupted
	else
		__check_nr_hwcorrupted_consistent
	fi
}

BASEVFN=0x700000000

if ! lsmod | grep mce_inject > /dev/null ; then
    modprobe mce_inject
fi

if ! lsmod | grep hwpoison_inject > /dev/null ; then
    modprobe hwpoison_inject
fi

check_install_package expect
check_install_package ruby

if ! which mce-inject > /dev/null || [[ ! -s "$(which mce-inject)" ]] ; then
    echo "No mce-inject installed."
    check_install_package bison
    check_install_package flex
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
