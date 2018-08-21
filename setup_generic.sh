#!/bin/bash

export TSTAMP=`date +%y%m%d_%H%M%S`

[ ! "$TESTNAME" ] && TESTNAME=$TSTAMP
export ODIR=${TRDIR}/results/$TESTNAME
[ ! -d "$ODIR" ] && mkdir -p $ODIR
export OFILE=$ODIR/result

export WDIR=$TRDIR/work
[ ! -d "$WDIR" ] && mkdir -p $WDIR

export GTMPD=$WDIR/$TESTNAME
[ ! -d "$GTMPD" ] && mkdir -p $GTMPD

echo -n 0 > $GTMPD/__testcount
echo -n 0 > $GTMPD/__success
echo -n 0 > $GTMPD/__failure
echo -n 0 > $GTMPD/__warning # might be problem but not affect the pass/fail judge
echo -n 0 > $GTMPD/__later # known failure
echo -n 0 > $GTMPD/__skipped # skip the testcase for a good reason

# These counters are independent between each testcase, commit_counts() does
# add values of per-testcase counters into total counters
reset_per_testcase_counters() {
	echo -n 0 > $TMPD/_testcount
	echo -n 0 > $TMPD/_success
	echo -n 0 > $TMPD/_failure
	echo -n 0 > $TMPD/_warning
	echo -n 0 > $TMPD/_later
}

add_counts() {
    local countfile=$1
    local value=$2
	[ ! -e "$countfile" ] && echo -n 0 > $countfile
    echo -n $[$(cat $countfile) + $value] > $countfile
}

commit_counts() {
	add_counts $GTMPD/__testcount $(cat $TMPD/_testcount)
	add_counts $GTMPD/__success   $(cat $TMPD/_success)
	add_counts $GTMPD/__failure   $(cat $TMPD/_failure)
	add_counts $GTMPD/__warning   $(cat $TMPD/_warning)
	add_counts $GTMPD/__later     $(cat $TMPD/_later)
}

FALSENEGATIVE=false

# print test output with copying into result file. Using tee command
# for example with "do_test | tee $OFILE" doesn't work because do_test
# runs in sub-process, and testcase/success/failure counts are broken.
echo_log() {
    if [ "$LOGLEVEL" -ge 1 ] ; then
		echo "$@" | tee -a $OFILE
	fi
}

echo_verbose() {
    if [ "$LOGLEVEL" -ge 2 ] ; then
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
    add_counts $TMPD/_testcount 1
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
        add_counts $TMPD/_later 1
        echo_log $nonewline "LATER: PASS: $@"
        return 0
    else
        add_counts $TMPD/_success 1
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
        add_counts $TMPD/_later 1
        echo_log $nonewline "LATER: FAIL: $@"
        return 0
    else
        add_counts $TMPD/_failure 1
        echo_log $nonewline "FAIL: $@"
        return 1
    fi
}

count_warning() {
    local nonewline=
    while true ; do
        case "$1" in
            -n) nonewline=-n ; shift ; break ;;
            *) break ;;
        esac
    done
    add_counts $TMPD/_warning 1
    echo_log $nonewline "WARN: $@"
    return 0
}

count_skipped() {
    local nonewline=
    while true ; do
        case "$1" in
            -n) nonewline=-n ; shift ; break ;;
            *) break ;;
        esac
    done

    add_counts $GTMPD/__skipped 1
    echo_log $nonewline "SKIPPED: $@"
    echo $TEST_TITLE >> $GTMPD/__skipped_testcases
    return 0
}

# TODO: testcases could be skipped, so searching PASS/FAIL count from OFILE is
# not a good idea. Need to record this in tmporary file.
show_fail_summary() {
    grep -e "--- testcase" -e "^PASS: " -e "^FAIL: " -e "^LATER: " ${OFILE} > $GTMPD/sum

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
                echo "# $test_title: $tmpline3" >> $GTMPD/sum2
            fi
        fi
    done < $GTMPD/sum
    if [ -f $GTMPD/sum2 ] ; then
        cat $GTMPD/sum2 | tee -a ${OFILE}
    fi
}

show_summary() {
    echo_log "$TESTNAME:"
    echo_log "$(cat $GTMPD/__testcount) checks: $(cat $GTMPD/__success) passes, $(cat $GTMPD/__failure) fails, $(cat $GTMPD/__warning) warns, $(cat $GTMPD/__later) laters."
    show_fail_summary
    if [ "$(cat $GTMPD/__skipped)" -ne 0 ] ; then
        echo_log "$(cat $GTMPD/__skipped) checks skipped."
        cat $GTMPD/__skipped_testcases | sed 's/^/ - /'
    fi
}

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
    export -f $func
done
