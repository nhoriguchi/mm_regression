#!/bin/bash

PIPE=${TMPF}.pipe
mkfifo ${PIPE} 2> /dev/null
[ ! -p ${PIPE} ] && echo_log "Fail to create pipe." >&2 && exit 1
chmod a+x ${PIPE}
PIPETIMEOUT=5

get_kernel_message() {
    local tag="$1"
    dmesg > ${TMPF}.dmesg_${tag}
}

get_kernel_message_diff() {
    local tag1="$1"
    local tag2="$2"
    local tag3="$3"
    echo "####### DMESG #######"
    diff ${TMPF}.dmesg_${tag1} ${TMPF}.dmesg_${tag2} | grep -v '^< ' | \
        tee ${TMPF}.dmesg_${tag3}
    echo "####### DMESG END #######"
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

check_kernel_message() {
    [ "$1" = -v ] && local inverse=true && shift
    local tag="$1"
    local word="$2"
    if [ "$word" ] ; then
        count_testcount
        grep "$word" ${TMPF}.dmesg_${tag} > /dev/null 2>&1
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

check_kernel_message_nobug() {
    local tag="$1"
    count_testcount
    grep -e " BUG: " -e " WARNING: " ${TMPF}.dmesgafterinjectdiff > /dev/null 2>&1
    if [ $? -eq 0 ] ; then
        count_failure "Kernel 'BUG:'/'WARNING:' message"
    else
        count_success "No Kernel 'BUG:'/'WARNING:' message"
    fi
}

prepare() {
    if [ "$TEST_PREPARE" ] ; then
        $TEST_PREPARE
    elif [ "$DEFAULT_TEST_PREPARE" ] ; then
        $DEFAULT_TEST_PREPARE
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
    if [ "$TEST_CLEANUP" ] ; then
        $TEST_CLEANUP
    elif [ "$DEFAULT_TEST_CLEANUP" ] ; then
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

do_test() {
    local cmd="$1"
    local line=

    init_return_code
    set_return_code "START"

    echo_log "--- testcase '$TEST_TITLE' start --------------------"
    prepare

    exec 2> >( tee -a ${OFILE} )
    # Keep pipe open to hold the data on buffer after the writer program
    # is terminated.
    exec {fd}<>${PIPE}
    eval "( $cmd ) &"
    local pid=$!
    while true ; do
        if ! pgrep -f "$cmd" 2> /dev/null >&2 ; then
            run_controller $pid "PROCESS_KILLED"
            break
        elif read -t${PIPETIMEOUT} line <> ${PIPE} ; then
            run_controller $pid "$line"
            if [ $? -eq 0 ] ; then
                break
            fi
        else
            echo "time out, abort test" | tee -a ${OFILE}
            set_return_code "TIMEOUT"
            break
        fi
    done

    pkill -f "$cmd" | tee -a ${OFILE}
    cleanup
    check
    echo_log "--- testcase '$TEST_TITLE' end --------------------"
}

# Usage: do_test_async <testtitle> <test controller> <result checker>
# if you don't need any external program to reproduce the problem (IOW, you can
# reproduce in the test controller,) use this async function.
do_test_async() {
    init_return_code
    set_return_code "START"

    echo_log "--- testcase '$TEST_TITLE' start --------------------"
    prepare
    run_controller
    cleanup
    check
    echo_log "--- testcase '$TEST_TITLE' end --------------------"
}

clear_testcase() {
    TEST_TITLE=
    TEST_PROGRAM=
    TEST_CONTROLLER=
    TEST_CHECKER=
    TEST_PREPARE=
    TEST_CLEANUP=
}
