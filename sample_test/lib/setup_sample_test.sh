#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

prepare_sample() {
    sysctl vm.nr_hugepages=10
    get_kernel_message_before
}

cleanup_sample() {
    get_kernel_message_after
    get_kernel_message_diff
    sysctl vm.nr_hugepages=0
}

control_sample() {
    local pid="$1"
    local line="$2"

    echo "$line"
    case "$line" in
        "busy loop to check pageflags")
            cat /proc/${pid}/numa_maps
            kill -SIGUSR1 ${pid}
            ;;
        "$test_sample exit")
            kill -SIGUSR1 ${pid}
            set_return_code "EXIT"
            return 0
            ;;
        *)
            ;;
    esac
    return 1
}

# inside checker you must tee output in you own.
check_sample() {
    check_kernel_message -v "failed"
    check_kernel_message_nobug
    check_return_code "${EXPECTED_RETURN_CODE}"

    # If you know some testcase fails for good reason, you can take it
    # as LATER (will be fixed later) instead of FAIL.
    FALSENEGATIVE=true
    check_kernel_message "LRU pages"
    FALSENEGATIVE=false
}

control_sample_async() {
    set_return_code "SOME_TEST_CODE"
}

check_sample_async() {
    local result="$1"
    check_kernel_message -v "failed"
    check_kernel_message_nobug
    check_return_code "${EXPECTED_RETURN_CODE}"
}

check_sample_false_negative() {
    check_kernel_message "NO_SUCH_STRINGS"
    check_return_code "${EXPECTED_RETURN_CODE}"
}

prepare_sample_test_skipped() {
    count_testcount
    count_success "just success"
    count_testcount
    count_failure "just failure"
    # This test is skipped, so ignore any success/failure recorded before this
    count_skipped "do skip"
    return 1
}

control_sample_test_skipped() {
    set_return_code THIS_SHOULD_NOT_HAPPEN
}

check_sample_test_skipped() {
    echo "BUG: this check should not run, because it's supposed to be skipped."
}

prepare_sample_test_skipped_unfixed() {
    count_testcount
    count_failure "This should never be run."
}

control_sample_test_skipped_unfixed() {
    count_testcount
    count_failure "This should never be run."
}

prepare_sample_test_unskipped_patch_matched() {
    prepare_system_default
}

control_sample_test_unskipped_patch_matched() {
    set_return_code EXIT
}

check_sample_test_unskipped_patch_matched() {
    check_return_code "${EXPECTED_RETURN_CODE}"
}

control_use_simple_tp_both_for_sync_and_async_mode() {
    local pid="$1"
    local line="$2"

    if [ "$pid" ] ; then # sync mode
        echo "-- $line"
        case "$line" in
            "checkpoint_1")
                cat /proc/$pid/numa_maps
                kill -SIGUSR1 $pid
                ;;
            "checkpoint_2")
                kill -SIGUSR1 $pid
                ;;
            "checkpoint_3")
                kill -SIGUSR1 $pid
                ;;
            "checkpoint_4")
                kill -SIGUSR1 $pid
                set_return_code "EXIT"
                return 0
                ;;
            *)
                ;;
        esac
        return 1
    else # async mode
        lib/test_sample_for_both_mode &
        pid=$!
        sleep 0.2
        # for checkpoint_1
        echo "pkill -SIGUSR1 -f lib/test_sample_for_both_mode"
        pkill -SIGUSR1 -f lib/test_sample_for_both_mode
        cat /proc/$pid/numa_maps
        # for checkpoint_2
        echo "pkill -SIGUSR1 -f lib/test_sample_for_both_mode"
        pkill -SIGUSR1 -f lib/test_sample_for_both_mode
        # for checkpoint_3
        echo "pkill -SIGUSR1 -f lib/test_sample_for_both_mode"
        pkill -SIGUSR1 -f lib/test_sample_for_both_mode
        # for checkpoint_4
        echo "pkill -SIGUSR1 -f lib/test_sample_for_both_mode"
        pkill -SIGUSR1 -f lib/test_sample_for_both_mode
        set_return_code "EXIT"
        return 0
    fi
}
