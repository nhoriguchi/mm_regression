#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

TESTPROG=$(dirname $(readlink -f $BASH_SOURCE))/sample
sysctl vm.nr_hugepages=10

prepare_test() {
    get_kernel_message before
}

cleanup_test() {
    get_kernel_message after
    get_kernel_message_diff before after diff
}

control_sample() {
    local pid="$1"
    local line="$2"

    case "$line" in
        "busy loop to check pageflags")
            cat /proc/${pid}/numa_maps
            kill -SIGUSR1 ${pid}
            ;;
        "${TESTPROG} exit")
            kill -SIGUSR1 ${pid}
            set_return_code "PASS"
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

# inside checker you must tee output in you own.
check_sample() {
    local result="$1"
    check_kernel_message -v diff "failed"
    check_kernel_message_nobug diff
    check_sample_specific PASS $result

    # If you know some testcase fails for good reason, you can take it
    # as LATER (will be fixed later) instead of FAIL.
    FALSENEGATIVE=true
    check_kernel_message diff "LRU pages"
    check_sample_specific PASS "TIMEOUT"
    FALSENEGATIVE=false
}

check_sample_specific() {
    local expected="$1"
    local result="$2"

    count_testcount "sample specific test"
    if [ "$expected" = "$result" ] ; then
        count_success "good :)"
    else
        count_failure "bad :("
        return 1
    fi
}

control_sample_async() {
    set_return_code "FAIL"
}

check_sample_async() {
    local result="$1"
    check_kernel_message -v diff "failed"
    check_kernel_message_nobug diff
    check_sample_specific FAIL $(get_return_code)
}
