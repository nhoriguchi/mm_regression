#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

TESTPROG=$(dirname $(readlink -f $BASH_SOURCE))/sample
sysctl vm.nr_hugepages=10

prepare_test() {
    get_kernel_message_before
}

cleanup_test() {
    get_kernel_message_after
    get_kernel_message_diff
}

control_sample() {
    local pid="$1"
    local line="$2"

    echo "$line" | tee -a ${OFILE}
    case "$line" in
        "busy loop to check pageflags")
            cat /proc/${pid}/numa_maps | tee -a ${OFILE}
            kill -SIGUSR1 ${pid}
            ;;
        "${TESTPROG} exit")
            kill -SIGUSR1 ${pid}
            set_return_code "EXIT"
            return 0
            ;;
        "PROCESS_KILLED")
            set_return_code "KILLED"
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

# inside checker you must tee output in you own.
check_sample() {
    check_kernel_message -v diff "failed"
    check_kernel_message_nobug diff
    check_return_code "${EXPECTED_RETURN_CODE}"

    # If you know some testcase fails for good reason, you can take it
    # as LATER (will be fixed later) instead of FAIL.
    FALSENEGATIVE=true
    check_kernel_message diff "LRU pages"
    FALSENEGATIVE=false
}

control_sample_async() {
    set_return_code "SOME_TEST_CODE"
}

check_sample_async() {
    local result="$1"
    check_kernel_message -v diff "failed"
    check_kernel_message_nobug diff
    check_return_code "${EXPECTED_RETURN_CODE}"
}
