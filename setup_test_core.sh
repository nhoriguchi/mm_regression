#!/bin/bash

export PIPE=${TMPF}.pipe
mkfifo ${PIPE} 2> /dev/null
[ ! -p ${PIPE} ] && echo_log "Fail to create pipe." >&2 && exit 1
chmod a+x ${PIPE}
export PIPETIMEOUT=5

get_kernel_message_before() { dmesg > ${TMPF}.dmesg_before; }
get_kernel_message_after() { dmesg > ${TMPF}.dmesg_after; }

get_kernel_message_diff() {
    echo "####### DMESG #######"
    diff ${TMPF}.dmesg_before ${TMPF}.dmesg_after | grep -v '^< ' | \
        tee ${TMPF}.dmesg_diff
    echo "####### DMESG END #######"
}

check_kernel_message() {
    [ "$1" = -v ] && local inverse=true && shift
    local word="$1"
    if [ "$word" ] ; then
        count_testcount
        grep "$word" ${TMPF}.dmesg_diff > /dev/null 2>&1
        if [ $? -eq 0 ] ; then
            if [ "$inverse" ] ; then
                count_failure "kernel message shows unexpected word '$word'."
            else
                count_success "kernel message shows expected word '$word'."
            fi
        else
            if [ "$inverse" ] ; then
                count_success "kernel message does not show unexpected word '$word'."
            else
                count_failure "kernel message does not show expected word '$word'."
            fi
        fi
    fi
}

check_kernel_message_nobug() {
    count_testcount
    grep -e " BUG " -e " WARNING " ${TMPF}.dmesg_diff > /dev/null 2>&1
    if [ $? -eq 0 ] ; then
        count_failure "Kernel 'BUG:'/'WARNING:' message"
    else
        count_success "No Kernel 'BUG:'/'WARNING:' message"
    fi
}

check_console_output() {
    [ "$1" = -v ] && local inverse=true && shift
    local word="$1"
    if [ "$word" ] ; then
        count_testcount
        grep "$word" ${TMPF}.dmesgafterinjectdiff > /dev/null 2>&1
        if [ $? -eq 0 ] ; then
            if [ "$inverse" ] ; then
                count_failure "host kernel message shows unexpected word '$word'."
            else
                count_success "host kernel message shows expected word '$word'."
            fi
        else
            if [ "$inverse" ] ; then
                count_success "host kernel message does not show unexpected word '$word'."
            else
                count_failure "host kernel message does not show expected word '$word'."
            fi
        fi
    fi
}

init_return_code() {
    rm -f ${TMPF}.return_code*
}

get_return_code() {
    cat ${TMPF}.return_code
}

get_return_code_seq() {
    cat ${TMPF}.return_code_seq | tr '\n' ' ' | sed 's/ *$//g'
}

set_return_code() {
    echo "$@" > ${TMPF}.return_code
    echo "$@" >> ${TMPF}.return_code_seq
}

check_return_code() {
    local expected="$1"
    [ ! "${expected}" ] && return
    count_testcount
    if [ "$(get_return_code_seq)" == "$expected" ] ; then
        count_success "return code: $(get_return_code_seq)"
    else
        count_failure "return code: $(get_return_code_seq) (expected ${expected})"
    fi
}

prepare() {
    local prepfunc
    if [ "$TEST_PREPARE" ] ; then
        prepfunc=$TEST_PREPARE
        $TEST_PREPARE
    elif [ "$DEFAULT_TEST_PREPARE" ] ; then
        prepfunc=$DEFAULT_TEST_PREPARE
        $DEFAULT_TEST_PREPARE
    fi
    if [ $? -ne 0 ] ; then
        echo "test preparation failed ($prepfunc) check your environment." >&2
        return 1
    fi
}

run_controller() {
    local pid="$1"
    local msg="$2"
    if [ "$TEST_CONTROLLER" ] ; then
        $TEST_CONTROLLER "$pid" "$msg"
    elif [ "$DEFAULT_TEST_CONTROLLER" ] ; then
        $DEFAULT_TEST_CONTROLLER "$pid" "$msg"
    fi
}

cleanup() {
    local cleanfunc
    if [ "$TEST_CLEANUP" ] ; then
        cleanfunc=$TEST_CLEANUP
        $TEST_CLEANUP
    elif [ "$DEFAULT_TEST_CLEANUP" ] ; then
        cleanfunc=$DEFAULT_TEST_CLEANUP
        $DEFAULT_TEST_CLEANUP
    fi
}

check() {
    if [ "$TEST_CHECKER" ] ; then
        $TEST_CHECKER
    elif [ "$DEFAULT_TEST_CHECKER" ] ; then
        $DEFAULT_TEST_CHECKER
    fi
}

# TESTCASE_FILTER can contain multiple filter items (like "test1 test2 perf*")
# so we need to do matching on each filter item.
check_testcase_filter_one() {
    local filter_item=$1
    if echo "$filter_item" | grep "*" > /dev/null ; then
        if echo "$TEST_TITLE" | grep "$filter_item" > /dev/null ; then
            return 1
        else
            return 0
        fi
    else
        if [ "$filter_item" == "$TEST_TITLE" ] ; then
            return 1
        else
            return 0
        fi
    fi
}

# "return 1" means we run the current testcase $TEST_TITLE
check_testcase_filter() {
    [ ! "$TESTCASE_FILTER" ] && return 1
    local filter_item=
    for filter_item in $TESTCASE_FILTER ; do
        check_testcase_filter_one $filter_item
        [ $? -eq 1 ] && return 1
    done
    # Didn't match, so we skip the current testcase
    clear_testcase
    return 0
}

# If the current testcase is not stable (so we are sure that the test should
# not pass on routine testing yet), we can set TEST_FLAGS in your recipe file.
# Then, the testcase is executed only when you set environment variable TEST_DEVEL.
# "return 1" means we run the current testcase. See also sample_test/sample.rc.
check_test_flag() {
    [ ! "$TEST_FLAGS" ] && return 1
    [ "$TEST_DEVEL" ] && return 1
    # Didn't match, so we skip the current testcase
    echo_log "Testcase $TEST_TITLE is skipped because it's not stable yet. If you"
    echo_log "really want to run the testcase, please set environment variable TEST_DEVEL"
    clear_testcase
    return 0
}

# return 1 if test (cmd) didn't run, otherwise return 0 even if test itself
# failed.
__do_test() {
    local cmd="$1"
    local line=

    init_return_code
    set_return_code "START"

    prepare
    if [ $? -ne 0 ] ; then
        cleanup
        return 1
    fi
    [ "$VERBOSE" ] && echo_log "$cmd"

    exec 2> >( tee -a ${OFILE} )
    # Keep pipe open to hold the data on buffer after the writer program
    # is terminated.
    exec 11<>${PIPE}
    eval "( $cmd ) &"
    local pid=$!
    while true ; do
        if ! pgrep -f "$cmd" 2> /dev/null >&2 ; then
            set_return_code "KILLED"
            break
        elif read -t${PIPETIMEOUT} line <> ${PIPE} ; then
            run_controller $pid "$line"
            if [ $? -eq 0 ] ; then
                break
            fi
        else
            if ! pgrep -f "$cmd" 2> /dev/null >&2 ; then
                set_return_code "KILLED"
                break
            else
                echo_log "time out, abort test"
                set_return_code "TIMEOUT"
                break
            fi
        fi
    done
    pkill -9 -f "$cmd" | tee -a ${OFILE}
    exec 11<&-
    exec 11>&-

    cleanup
    check
    return 0
}

do_test() {
    local i=
    local retryable=$TEST_RETRYABLE

    check_testcase_filter && return
    check_test_flag && return

    echo_log "--- testcase '$TEST_TITLE' start --------------------"
    while true ; do
        reset_per_testcase_counters
        __do_test "$@"
        # test aborted due to the preparation failure
        if [ $? -ne 0 ] ; then
            break
        fi
        if [ "$(cat ${TMPF}.failure_tmp)" -gt 0 ] ; then
            if [ ! "$TEST_RETRYABLE" ] ; then
                # don't care about retry.
                break
            elif [ "$TEST_RETRYABLE" -eq 0 ] ; then
                echo_log "### retried $retryable, but still failed."
                break
            else
                echo_log "### failed, so let's retry ($[retryable - TEST_RETRYABLE + 1])"
                TEST_RETRYABLE=$[TEST_RETRYABLE-1]
            fi
        else
            break
        fi
    done
    echo_log "--- testcase '$TEST_TITLE' end --------------------"
    commit_counts
    clear_testcase
}

__do_test_async() {
    init_return_code
    set_return_code "START"
    prepare
    if [ $? -ne 0 ] ; then
        cleanup
        return 1
    fi
    run_controller
    cleanup
    check
    return 0
}

# Usage: do_test_async <testtitle> <test controller> <result checker>
# if you don't need any external program to reproduce the problem (IOW, you can
# reproduce in the test controller,) use this async function.
do_test_async() {
    local i=
    local retryable=$TEST_RETRYABLE

    check_testcase_filter && return
    check_test_flag && return

    echo_log "--- testcase '$TEST_TITLE' start --------------------"
    while true ; do
        reset_per_testcase_counters
        __do_test_async
        # test aborted due to the preparation failure
        if [ $? -ne 0 ] ; then
            break
        fi
        if [ "$(cat ${TMPF}.failure_tmp)" -gt 0 ] ; then
            if [ ! "$TEST_RETRYABLE" ] ; then
                # don't care about retry.
                break
            elif [ "$TEST_RETRYABLE" -eq 0 ] ; then
                echo_log "### retried $retryable, but still failed."
                break
            else
                echo_log "### failed, so let's retry ($[retryable - TEST_RETRYABLE + 1])"
                TEST_RETRYABLE=$[TEST_RETRYABLE-1]
            fi
        else
            break
        fi
    done
    echo_log "--- testcase '$TEST_TITLE' end --------------------"
    commit_counts
    clear_testcase
}

# common initial value
TEST_RETRYABLE=0
clear_testcase() {
    TEST_TITLE=
    TEST_PROGRAM=
    TEST_CONTROLLER=
    TEST_CHECKER=
    TEST_PREPARE=
    TEST_CLEANUP=
    TEST_FLAGS=
    TEST_RETRYABLE=
    FALSENEGATIVE=false
    reset_per_testcase_counters
}

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
    export -f $func
done
