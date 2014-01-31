#!/bin/bash

TCDIR=$(dirname $(readlink -f $BASH_SOURCE))
TESTNAME="test"
VERBOSE=""
FILTER=""

while getopts vs:t:f: OPT ; do
    case $OPT in
        "v" ) VERBOSE="-v" ;;
        "s" ) KERNEL_SRC="${OPTARG}" ;;
        "t" ) TESTCASE="${OPTARG}" ;;
        "f" ) FILTER="${OPTARG}" ;;
    esac
done

shift $[OPTIND-1]
RECIPEFILE=$1

# Test root directory
TRDIR=$(dirname $(readlink -f $RECIPEFILE))

. ${TCDIR}/setup_generic.sh
. ${TCDIR}/setup_test_core.sh

while read line ; do
    [ ! "$line" ] && continue
    [[ $line =~ ^# ]] && continue

    if [ "$line" = do_test_sync ] ; then
        if [ ! "$FILTER" ] || [ "$FILTER" == "$TESTCASE_TITLE" ] ; then
            do_test "$TESTCASE_TITLE" "$TESTCASE_PROGRAM -p ${PIPE} ${VERBOSE}" "$TESTCASE_CONTROL" "$TESTCASE_CHECKER"
        fi
        clear_testcase
    elif [ "$line" = do_test_async ] ; then
        if [ ! "$FILTER" ] || [ "$FILTER" == "$TESTCASE_TITLE" ] ; then
            do_test_async "$TESTCASE_TITLE" "$TESTCASE_CONTROL" "$TESTCASE_CHECKER"
        fi
        clear_testcase
    else
        eval $line
    fi
done < ${RECIPEFILE}

show_summary
