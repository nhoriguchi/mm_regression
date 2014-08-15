#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

export TSTAMP=`date +%y%m%d_%H%M%S`
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
        echo_log $nonewline "PASS: $@"
        return 0
    else
        echo -n $[$(cat ${TMPF}.later) + 1] > ${TMPF}.later
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
        echo_log $nonewline "FAIL: $@"
        return 1
    else
        echo -n $[$(cat ${TMPF}.later) + 1] > ${TMPF}.later
        echo_log $nonewline "LATER: FAIL: $@"
        return 0
    fi
}

show_fail_summary() {
    grep -e "--- testcase" -e "^PASS: " -e "^FAIL: " -e "^LATER: " ${OFILE} > ${TMPF}.sum

    local test_title=
    local tmpline3=
    while read line ; do
        local tmpline1="$(echo $line | sed "s/-* testcase '\(.*\)' start -*/\1/")"
        local tmpline2="$(echo $line | sed "s/-* testcase '\(.*\)' end -*/\1/")"
        if [ "$line" != "$tmpline1" ] ; then
            test_title="$tmpline1"
        elif [ "$line" != "$tmpline2" ] ; then
            test_title=
        else
            tmpline3="$(echo $line | grep -e "^FAIL: " -e "^LATER: FAIL: ")"
            if [ "$test_title" ] && [ "$tmpline3" ] ; then
                echo "# $test_title: $tmpline3" >> ${TMPF}.sum2
            fi
        fi
    done < ${TMPF}.sum
    cat ${TMPF}.sum2 | tee -a ${OFILE}
}

show_summary() {
    echo_log "$TESTNAME:"
    echo_log "$(cat ${TMPF}.testcount) test(s) ran, $(cat ${TMPF}.success) passed, $(cat ${TMPF}.failure) failed, $(cat ${TMPF}.later) laters."
    show_fail_summary
}

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
    export -f $func
done
