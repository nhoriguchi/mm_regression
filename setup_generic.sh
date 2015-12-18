#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

# global timestamp
export TSTAMP=`date +%y%m%d_%H%M%S`
export ODIR=${TRDIR}/results/$TSTAMP

[ ! -d "$ODIR" ] && mkdir -p $ODIR
export OFILE=$ODIR/$TESTNAME

export WDIR=${TRDIR}/work
[ ! -d "$WDIR" ] && mkdir -p $WDIR
# export TMPF=`mktemp --tmpdir=$WDIR`
export GTMPD=$WDIR/$TSTAMP/
mkdir -p $GTMPD
# export TMPD=$TMPF # for compatibility with older work/ format

echo -n 0 > ${GTMPD}/_testcount
echo -n 0 > ${GTMPD}/_success
echo -n 0 > ${GTMPD}/_failure
echo -n 0 > ${GTMPD}/_later # known failure
echo -n 0 > ${GTMPD}/_skipped # skip the testcase for a good reason

# These counters are independent between each testcase, commit_counts() does
# add values of per-testcase counters into total counters
reset_per_testcase_counters() {
	if [ ! "$1" ] ; then
		echo -n 0 > ${TMPD}/testcount
		echo -n 0 > ${TMPD}/success
		echo -n 0 > ${TMPD}/failure
		echo -n 0 > ${TMPD}/later
	fi
}

add_counts() {
    local countfile=$1
    local value=$2
	[ ! -e "$countfile" ] && echo -n 0 > $countfile
    echo -n $[$(cat $countfile) + $value] > $countfile
}

commit_counts() {
	add_counts ${GTMPD}/_testcount $(cat ${TMPD}/testcount)
	add_counts ${GTMPD}/_success   $(cat ${TMPD}/success)
	add_counts ${GTMPD}/_failure   $(cat ${TMPD}/failure)
	add_counts ${GTMPD}/_later     $(cat ${TMPD}/later)
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
    add_counts ${TMPD}/testcount 1
}

count_success() {
    local nonewline=
    while true ; do
        case "$1" in
            -n) nonewline=-n ; shift ; break ;;
            *) break ;;
        esac
    done
    if [ "$FALSENEGATIVE" = true ] ; then
        add_counts ${TMPD}/later 1
        echo_log $nonewline "LATER: PASS: $@"
        return 0
    else
        add_counts ${TMPD}/success 1
        echo_log $nonewline "PASS: $@"
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
    if [ "$FALSENEGATIVE" = true ] ; then
        add_counts ${TMPD}/later 1
        echo_log $nonewline "LATER: FAIL: $@"
        return 0
    else
        add_counts ${TMPD}/failure 1
        echo_log $nonewline "FAIL: $@"
        return 1
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

    add_counts ${GTMPD}/_skipped 1
    echo_log $nonewline "SKIPPED: $@"
    echo $TEST_TITLE >> ${GTMPD}/_skipped_testcases
    return 0
}

# TODO: testcases could be skipped, so searching PASS/FAIL count from OFILE is
# not a good idea. Need to record this in tmporary file.
show_fail_summary() {
    grep -e "--- testcase" -e "^PASS: " -e "^FAIL: " -e "^LATER: " ${OFILE} > ${GTMPD}/sum

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
                echo "# $test_title: $tmpline3" >> ${GTMPD}/sum2
            fi
        fi
    done < ${GTMPD}/sum
    if [ -f ${GTMPD}/sum2 ] ; then
        cat ${GTMPD}/sum2 | tee -a ${OFILE}
    fi
}

show_summary() {
    echo_log "$TESTNAME:"
    echo_log "$(cat ${GTMPD}/_testcount) test(s) ran, $(cat ${GTMPD}/_success) passed, $(cat ${GTMPD}/_failure) failed, $(cat ${GTMPD}/_later) laters."
    show_fail_summary
    if [ "$(cat ${GTMPD}/_skipped)" -ne 0 ] ; then
        echo_log "$(cat ${GTMPD}/_skipped) test(s) skipped."
        cat ${GTMPD}/_skipped_testcases | sed 's/^/ - /'
    fi
}

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
    export -f $func
done
