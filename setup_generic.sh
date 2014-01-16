#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

[ ! "$TSTAMP" ] &&  TSTAMP=`date +%y%m%d_%H%M`
ODIR=${TRDIR}/results/$TSTAMP
[ ! -d "$ODIR" ] && mkdir -p $ODIR
OFILE=$ODIR/$TESTNAME

WDIR=${TRDIR}/work
[ ! -d "$WDIR" ] && mkdir -p $WDIR
TMPF=`mktemp --tmpdir=$WDIR`

TESTCOUNT=0
SUCCESS=0
FAILURE=0
LATER=0   # known failure
FALSENEGATIVE=false

# print test output with copying into result file. Using tee command
# for example with "do_test | tee $OFILE" doesn't work because do_test
# runs in sub-process, and testcase/success/failure counts are broken.
echo_log() {
    echo "$@" | tee -a $OFILE
}

log() {
    perl -ne 'print "$_"' | tee -a ${OFILE}
}

echo_verbose() {
    if [ "$VERBOSE" ] ; then
        echo "$@"
    else
        echo "$@" > /dev/null
    fi
}

verbose() {
    if [ "$VERBOSE" ] ; then
        perl -ne 'print "$_"'
    else
        perl -ne 'print "$_"' > /dev/null
    fi
}

count_testcount() {
    local nonewline=
    while true ; do
        case "$1" in
            -n) nonewline=-n ; shift ; break ;;
            *) break ;;
        esac
    done
    [ "$@" ] && echo_log $nonewline "$@"
    TESTCOUNT=$((TESTCOUNT+1))
}

count_success() {
    local nonewline=
    while true ; do
        case "$1" in
            -n) nonewline=-n ; shift ; break ;;
            *) break ;;
        esac
    done
    if [ "$FALSENEGATIVE" = false ] ; then
        SUCCESS=$((SUCCESS+1))
        echo_log $nonewline "PASS: $@"
        return 0
    else
        LATER=$((LATER+1))
        echo_log $nonewline "LATER: PASS: $@"
        return 0
    fi
}

count_failure() {
    local nonewline=
    while true ; do
        case "$1" in
            -n) nonewline=-n ; shift ; break ;;
            *) break ;;
        esac
    done
    if [ "$FALSENEGATIVE" = false ] ; then
        FAILURE=$((FAILURE+1))
        echo_log $nonewline "FAIL: $@"
        return 1
    else
        LATER=$((LATER+1))
        echo_log $nonewline "LATER: FAIL: $@"
        return 0
    fi
}

show_summary() {
    echo_log "$TESTNAME:"
    echo_log "$TESTCOUNT test(s) ran, $SUCCESS passed, $FAILURE failed, $LATER laters."
}
