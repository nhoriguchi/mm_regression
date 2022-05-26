#!/bin/bash

SDIR=$(dirname $BASH_SOURCE)
PID=""
PFN=""
ERRORTYPE=""
DOUBLE=false
QUIET=
TARGET=
while getopts "p:a:e:Dqh" opt ; do
    case $opt in
        p) PID=$OPTARG ;;
        a) PFN=$OPTARG ;;
        e) ERRORTYPE=$OPTARG ;;
        D) DOUBLE=true ;;
        q) QUIET=true ;;
        h) usage 0 ;;
    esac
done

# new MCE injection interface since 4.12
SYSDIR=/sys/kernel/debug/mce-inject

usage() {
    local sname=`basename $BASH_SOURCE`
    echo "Usage: $sname [-p pid] -a pfn -e errortype [-Dv]"
    echo ""
    echo "Options:"
    echo "  -p: set process ID of the target process."
    echo "  -a: set memory address (in page unit). If -p option is given,"
    echo "      the given address is virtual one. Otherwise it's physical one."
    echo "  -e: set error type to be injected. It's one of the following:"
    echo "      mce-ce, mce-srao, hard-offline, soft-offline"
    echo "  -D: inject twice"
    echo "  -v: verbose"
    exit $1
}

inject_error() {
	local tmpd=$(mktemp -d)
	local cpu=`cat /proc/self/stat | cut -d' ' -f39`
	local bank=1

    if [ "$ERRORTYPE" = "hard-offline" ] ; then
        echo $[$TARGET * 4096] > /sys/devices/system/memory/hard_offline_page 2> /dev/null
    elif [ "$ERRORTYPE" = "soft-offline" ] ; then
        echo $[$TARGET * 4096] > /sys/devices/system/memory/soft_offline_page 2> /dev/null
    elif [ "$ERRORTYPE" = "mce-srao" ] ; then
		if [ -e /dev/mcelog ] ; then
			cat <<EOF > $tmpd/mce-inject
CPU $cpu BANK $bank
STATUS UNCORRECTED SRAO 0x17a
MCGSTATUS RIPV MCIP
ADDR $[$TARGET * 4096]
MISC 0x8c
RIP 0x73:0x1eadbabe
EOF
			mce-inject $tmpd/mce-inject
		elif [ -d "$SYSDIR" ] ; then
			echo $cpu               > $SYSDIR/cpu
			echo hw                 > $SYSDIR/flags
			echo $[$TARGET * 4096]  > $SYSDIR/addr
			echo 0xbd0000000000017a > $SYSDIR/status
			echo 0x8c               > $SYSDIR/misc
			echo 0                  > $SYSDIR/synd
			echo $bank              > $SYSDIR/bank
		else
			echo "No MCE injection interface found in this system." >&2
		fi
    elif [ "$ERRORTYPE" = "mce-srar" ] ; then
		if [ -e /dev/mcelog ] ; then
			cat <<EOF > $tmpd/mce-inject
CPU $cpu BANK $bank
STATUS UNCORRECTED SRAR 0x134
MCGSTATUS RIPV MCIP EIPV
ADDR $[$TARGET * 4096]
MISC 0x8c
RIP 0x73:0x3eadbabe
EOF
			mce-inject $tmpd/mce-inject
		elif [ -d "$SYSDIR" ] ; then
			echo $cpu               > $SYSDIR/cpu
			echo hw                 > $SYSDIR/flags
			echo $[$TARGET * 4096]  > $SYSDIR/addr
			echo 0xbd80000000000134 > $SYSDIR/status
			echo 0x8c               > $SYSDIR/misc
			echo 0                  > $SYSDIR/synd
			echo $bank              > $SYSDIR/bank
		else
			echo "No MCE injection interface found in this system." >&2
		fi
    elif [ "$ERRORTYPE" = "mce-ce" ] ; then
		if [ -e /dev/mcelog ] ; then
			cat <<EOF > $tmpd/mce-inject
CPU $cpu BANK $bank
STATUS CORRECTED 0xc0
ADDR $[$TARGET * 4096]
EOF
			mce-inject $tmpd/mce-inject
		elif [ ! -d "$SYSDIR" ] ; then
			echo $cpu               > $SYSDIR/cpu
			echo hw                 > $SYSDIR/flags
			echo $[$TARGET * 4096]  > $SYSDIR/addr
			echo 0x9c000000000000c0 > $SYSDIR/status
			echo 0x8c               > $SYSDIR/misc
			echo 0                  > $SYSDIR/synd
			echo $bank              > $SYSDIR/bank
		else
			echo "No MCE injection interface found in this system." >&2
		fi
    else
        echo "undefined injection type [$ERRORTYPE]. Abort" >&2
        return 1
    fi
    rm -rf ${tmpd}
    return 0
}

if [[ ! "$ERRORTYPE" =~ (mce-srao|mce-srar|mce-ce|hard-offline|soft-offline) ]] ; then
    echo "-e <ERRORTYPE> should be given." >&2
    exit 1
fi

if [ ! "$PFN" ] ; then
    echo "-a <PFN> should be given." >&2
    exit 1
fi

if [ "$PID" ] ; then
    TARGET=0x$(ruby -e 'printf "%x\n", IO.read("/proc/'$PID'/pagemap", 0x8, '$PFN'*8).unpack("Q")[0] & 0xfffffffffff')
	if [ "$TARGET" == 0x ] ; then
		echo failed to get target pfn from pagemap
		exit 1
	fi
    [ ! "$QUIET" ] && echo "Injecting MCE ($ERRORTYPE) to local process (pid:$PID) at vfn:$PFN, pfn:$TARGET"
else
    TARGET="$PFN"
    [ ! "$QUIET" ] && echo "Injecting MCE ($ERRORTYPE) to physical address pfn:$TARGET"
fi
inject_error $ERRORTYPE $TARGET 2>&1
ret=$?
if [ "$DOUBLE" = true ] ; then
	inject_error $ERRORTYPE $TARGET 2>&1
	ret=$?
fi
exit $ret
