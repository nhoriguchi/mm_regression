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

get_return_code() {
    cat ${TMPF}.return_code
}

set_return_code() {
    echo "$@" > ${TMPF}.return_code
}

check_return_code() {
    local testnote="$1"
    local successnote="$2"
    local failurenote="$3"
    count_testcount "${testnote}"
    if [ "$(get_return_code)" == "PASS" ] ; then
        count_success "${successnote}."
    else
        count_failure "($(get_return_code)) ${failurenote}."
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

# Usage: do_test <testtitle> <external command> <test controller> <result checker>
# if you need other test program to reproduce the problem, use this function.
_do_test() {
    local title="$1"
    local cmd="$2"
    local controller="$3"
    local checker="$4"
    local line=

    set_return_code "FAIL"

    echo "---test '$title' start---------------------------------------------------------"
    echo "$FUNCNAME '$title' '$cmd' $controller $checker"

    prepare_test "$title"

    # Keep pipe open to hold the data on buffer after the writer program
    # is terminated.
    exec {fd}<>${PIPE}
    eval "( $cmd ) &"
    local pid=$!
    while true ; do
        if read -t${PIPETIMEOUT} line <> ${PIPE} ; then
            $controller $pid "$line"
            if [ $? -eq 0 ] ; then
                break
            fi
        else
            echo "time out, abort test" >&2
            kill -SIGINT $pid
            set_return_code "TIMEOUT"
            break
        fi
    done

    cleanup_test "$title"
}

# A wrapper of _do_test() to copy the test output into result file.
# note that $checker should 'tee' the output inside itself, because
# it updates global variables and shouldn't called in sub-process.
do_test() {
    local title="$1"
    local cmd="$2"
    local controller="$3"
    local checker="$4"

    _do_test "$title" "$cmd" "$controller" "$checker" | log
    $checker "$(get_return_code)"
    echo_log "---test '$title' end------------------------------------------------"
}

# Usage: do_test_async <testtitle> <test controller> <result checker>
# if you don't need any external program to reproduce the problem (IOW, you can
# reproduce in the test controller,) use this async function.
_do_test_async() {
    local title="$1"
    local controller="$2"
    local checker="$3"
    local result="FAIL"

    set_return_code "FAIL"

    echo "---test '$title' start---------------------------------------------------------"
    echo "$FUNCNAME '$title' $controller $checker"

    prepare_test "$title"
    $controller
    cleanup_test "$title"
}

# A wrapper of _do_test_async() to copy the test output into result file.
do_test_async() {
    local title="$1"
    local controller="$2"
    local checker="$3"
    _do_test_async "$title" "$controller" "$checker" | log
    $checker "$(get_return_code)"
    echo_log "---test '$title' end------------------------------------------------"
}

clear_testcase() {
    TESTCASE_TITLE=
    TESTCASE_PROGRAM=
    TESTCASE_CONTROL=
    TESTCASE_CHECKER=
}
