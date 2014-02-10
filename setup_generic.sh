#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

export TSTAMP=`date +%y%m%d_%H%M`
export ODIR=${TRDIR}/results/$TSTAMP

[ ! -d "$ODIR" ] && mkdir -p $ODIR
export OFILE=$ODIR/$TESTNAME

export WDIR=${TRDIR}/work
[ ! -d "$WDIR" ] && mkdir -p $WDIR
export TMPF=`mktemp --tmpdir=$WDIR`

echo -n 0 > ${TMPF}.testcount
echo -n 0 > ${TMPF}.success
echo -n 0 > ${TMPF}.failure
echo -n 0 > ${TMPF}.later # known failure

export FALSENEGATIVE=false

# print test output with copying into result file. Using tee command
# for example with "do_test | tee $OFILE" doesn't work because do_test
# runs in sub-process, and testcase/success/failure counts are broken.
echo_log() {
    echo "$@" | tee -a $OFILE
}

echo_verbose() {
    if [ "$VERBOSE" ] ; then
        echo "$@"
    else
        echo "$@" > /dev/null
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
    echo -n $[$(cat ${TMPF}.testcount) + 1] > ${TMPF}.testcount
    # TESTCOUNT=$((TESTCOUNT+1))
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
        echo -n $[$(cat ${TMPF}.success) + 1] > ${TMPF}.success
        # SUCCESS=$((SUCCESS+1))
        echo_log $nonewline "PASS: $@"
        return 0
    else
        echo -n $[$(cat ${TMPF}.later) + 1] > ${TMPF}.later
        # LATER=$((LATER+1))
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
        echo -n $[$(cat ${TMPF}.failure) + 1] > ${TMPF}.failure
        # FAILURE=$((FAILURE+1))
        echo_log $nonewline "FAIL: $@"
        return 1
    else
        echo -n $[$(cat ${TMPF}.later) + 1] > ${TMPF}.later
        # LATER=$((LATER+1))
        echo_log $nonewline "LATER: FAIL: $@"
        return 0
    fi
}

show_summary() {
    echo_log "$TESTNAME:"
    # echo_log "$TESTCOUNT test(s) ran, $SUCCESS passed, $FAILURE failed, $LATER laters."
    echo_log "$(cat ${TMPF}.testcount) test(s) ran, $(cat ${TMPF}.success) passed, $(cat ${TMPF}.failure) failed, $(cat ${TMPF}.later) laters."
}

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
    export -f $func
done
