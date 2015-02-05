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
echo -n 0 > ${TMPF}.skipped # skip the testcase for a good reason

# These counters are independent between each testcase, commit_counts do
# add values of per-testcase counters into total counters
reset_per_testcase_counters() {
    echo -n 0 > ${TMPF}.testcount_tmp
    echo -n 0 > ${TMPF}.success_tmp
    echo -n 0 > ${TMPF}.failure_tmp
    echo -n 0 > ${TMPF}.later_tmp
    echo -n 0 > ${TMPF}.skipped_tmp
}

add_counts() {
    local countfile=$1
    local value=$2
    echo -n $[$(cat $countfile) + $value] > $countfile
}

commit_counts() {
    add_counts ${TMPF}.testcount $(cat ${TMPF}.testcount_tmp)
    add_counts ${TMPF}.success   $(cat ${TMPF}.success_tmp)
    add_counts ${TMPF}.failure   $(cat ${TMPF}.failure_tmp)
    add_counts ${TMPF}.later     $(cat ${TMPF}.later_tmp)
    add_counts ${TMPF}.skipped   $(cat ${TMPF}.skipped_tmp)
}

FALSENEGATIVE=false

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
    add_counts ${TMPF}.testcount_tmp 1
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
        add_counts ${TMPF}.success_tmp 1
        echo_log $nonewline "PASS: $@"
        return 0
    else
        add_counts ${TMPF}.later_tmp 1
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
        add_counts ${TMPF}.failure_tmp 1
        echo_log $nonewline "FAIL: $@"
        return 1
    else
        add_counts ${TMPF}.later_tmp 1
        echo_log $nonewline "LATER: FAIL: $@"
        return 0
    fi
}

count_skipped() {
    local nonewline=
    while true ; do
        case "$1" in
            -n) nonewline=-n ; shift ; break ;;
            *) break ;;
        esac
    done

    add_counts ${TMPF}.skipped_tmp 1
    echo_log $nonewline "SKIPPED: $@"
    return 0
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
    if [ -f ${TMPF}.sum2 ] ; then
        cat ${TMPF}.sum2 | tee -a ${OFILE}
    fi
}

show_summary() {
    echo_log "$TESTNAME:"
    echo_log "$(cat ${TMPF}.testcount) test(s) ran, $(cat ${TMPF}.success) passed, $(cat ${TMPF}.failure) failed, $(cat ${TMPF}.later) laters."
    show_fail_summary
}

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
    export -f $func
done
