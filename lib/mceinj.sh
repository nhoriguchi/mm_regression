#!/bin/bash

SDIR=`dirname $BASH_SOURCE`
PID=""
PFN=""
ERRORTYPE=""
DOUBLE=false
VERBOSE=false
TARGET=
while getopts "p:a:e:Dvh" opt ; do
    case $opt in
        p) PID=$OPTARG ;;
        a) PFN=$OPTARG ;;
        e) ERRORTYPE=$OPTARG ;;
        D) DOUBLE=true ;;
        v) VERBOSE=true ;;
        h) usage 0 ;;
    esac
done

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

    if [ "$ERRORTYPE" = "hard-offline" ] ; then
        echo $[$TARGET * 4096] > /sys/devices/system/memory/hard_offline_page 2> /dev/null
    elif [ "$ERRORTYPE" = "soft-offline" ] ; then
        echo $[$TARGET * 4096] > /sys/devices/system/memory/soft_offline_page 2> /dev/null
    elif [ "$ERRORTYPE" = "mce-srao" ] ; then
        cat <<EOF > $tmpd/mce-inject
CPU `cat /proc/self/stat | cut -d' ' -f39` BANK 2
STATUS UNCORRECTED SRAO 0x17a
MCGSTATUS RIPV MCIP
ADDR $[$TARGET * 4096]
MISC 0x8c
RIP 0x73:0x1eadbabe
EOF
        mce-inject $tmpd/mce-inject
    elif [ "$ERRORTYPE" = "mce-srar" ] ; then
        cat <<EOF > $tmpd/mce-inject
CPU `cat /proc/self/stat | cut -d' ' -f39` BANK 1
STATUS UNCORRECTED SRAR 0x134
MCGSTATUS RIPV MCIP EIPV
ADDR $[$TARGET * 4096]
MISC 0x8c
RIP 0x73:0x3eadbabe
EOF
        mce-inject $tmpd/mce-inject
    elif [ "$ERRORTYPE" = "mce-ce" ] ; then
        cat <<EOF > $tmpd/mce-inject
CPU `cat /proc/self/stat | cut -d' ' -f39` BANK 2
STATUS CORRECTED 0xc0
ADDR $[$TARGET * 4096]
EOF
        mce-inject $tmpd/mce-inject
    else
        echo "undefined injection type [$ERRORTYPE]. Abort"
        return 1
    fi
    rm -rf ${tmpd}
    return 0
}

if [[ ! "$ERRORTYPE" =~ (mce-srao|mce-srar|mce-ce|hard-offline|soft-offline) ]] ; then
    echo "-e <ERRORTYPE> should be given."
    exit 1
fi

if [ ! "$PFN" ] ; then
    echo "-a <PFN> should be given."
    exit 1
fi

if [ "$PID" ] ; then
    TARGET=0x$(ruby -e 'printf "%x\n", IO.read("/proc/'$PID'/pagemap", 0x8, '$PFN'*8).unpack("Q")[0] & 0xfffffffffff')
    echo "Injecting MCE ($ERRORTYPE) to local process (pid:$PID) at vfn:$PFN, pfn:$TARGET"
else
    TARGET="$PFN"
    echo "Injecting MCE ($ERRORTYPE) to physical address pfn:$TARGET"
fi
inject_error $ERRORTYPE $TARGET 2>&1
[ "$DOUBLE" = true ] && inject_error $ERRORTYPE $TARGET 2>&1
