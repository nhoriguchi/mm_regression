#!/bin/bash

get_kernel_message_before() { dmesg > $TMPD/_dmesg_before; }
get_kernel_message_after() { dmesg > $TMPD/_dmesg_after; }

__dmesg_filter1() {
	grep -v "\(MCE\|Unpoison\): Page was already unpoisoned"
}
__dmesg_filter2() {
	grep -v "\(MCE\|Unpoison\): Software-unpoisoned "
}
__dmesg_filter3() {
	grep -v "Soft offlining page"
}

DMESG_FILTER_SWITCH=on
dmesg_filter() {
	if [ "$DMESG_FILTER_SWITCH" ] ; then
		__dmesg_filter1 | __dmesg_filter2 | __dmesg_filter3
	else
		cat <&0 >&1
	fi
}

get_kernel_message_diff() {
	diff $TMPD/_dmesg_before $TMPD/_dmesg_after 2> /dev/null | grep -v '^< ' | \
		dmesg_filter > $TMPD/_dmesg_diff
	# expecting environment format DMESG_DIFF_LIMIT is like "head -n10" or "tail -20"
	if [ -s $TMPD/_dmesg_diff ] ; then
		echo "####### DMESG #######"
		if [ "$DMESG_DIFF_LIMIT" ] ; then
			$DMESG_DIFF_LIMIT $TMPD/_dmesg_diff
		else
			cat $TMPD/_dmesg_diff
		fi
		echo "####### DMESG END #######"
	fi
	rm $TMPD/_dmesg_before $TMPD/_dmesg_after 2> /dev/null
}

# Confirm that kernel message does contain the specified words
# With -v option, negate the confirmation.
check_kernel_message() {
	[ "$1" = -v ] && local inverse=true && shift
	local word="$1"
	if [ "$word" ] ; then
		count_testcount
		grep "$word" $TMPD/_dmesg_diff > /dev/null 2>&1
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
	grep -e "BUG:" -e "WARNING:" $TMPD/_dmesg_diff > /dev/null 2>&1
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
		grep "$word" $GTMPD/dmesgafterinjectdiff > /dev/null 2>&1
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
	rm -f $TMPD/_return_code*

	# Even if current testcase is skipped, we need an empty _return_code_seq
	# file because test_summary.rb script want it to be able to tell that the
	# testcase is started or just skipped.
	touch $TMPD/_return_code_seq
}

get_return_code() {
	cat $TMPD/_return_code
}

get_return_code_seq() {
	cat $TMPD/_return_code_seq | tr '\n' ' ' | sed 's/ *$//g'
}

set_return_code() {
	echo "$@" >> $TMPD/_return_code_seq
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

set_return_code_start() {
	set_return_code START
	# making sure return code START is written on the disk because if current
	# testcase causes kernel panic or power reset, the return code is used to
	# skip the same testcode in the next run after reboot.
	sync
}

# Return false if AGAIN is true, so this testcase will run anyway. If AGAIN is
# not true, then return true only when current testcase does not run yet.
check_testcase_already_run() {
	[ "$AGAIN" == true ] && return 1
	[ ! -s "$TMPD/run_status" ] && return 1

	[ "$(cat $TMPD/run_status)" == SKIPPED ] && return 0
	[ "$(cat $TMPD/run_status)" == FINISHED ] && return 0
	return 1
}

prepare_system_default() {
	get_kernel_message_before
	run_beaker_environment_checker
}

cleanup_unimportant_temporal_files() {
	find $TMPD/ -name ".*" | xargs rm -rf
}

run_beaker_environment_checker() {
	# No need to run check in non-beaker environment
	if [ ! "$JOBID" ] || [ ! "$TASKNAME" ] ; then
		return
	fi

	# If already checker running, no need to kick again
	if pgrep -f beaker_environment_checker > /dev/null ; then
		return
	fi

	if [ ! -s "$GTMPD/.beaker_environment_checker" ] ; then
		cat <<EOF > $GTMPD/.beaker_environment_checker
while true ; do
	reboot=
	sleep 10
	! pgrep -f /usr/bin/beah-srv > /dev/null 2>&1            && reboot=beah-srv
	! pgrep -f /usr/bin/beah-fwd-backend > /dev/null 2>&1    && reboot=beah-fwd-backend
	! pgrep -f /usr/bin/beah-beaker-backend > /dev/null 2>&1 && reboot=beah-beaker-backend

	if [ "\$reboot" ] ; then
		echo "### beaker service \$reboot is not running, reboot." | tee /dev/kmsg
		reboot
		sleep 10
		systemctl restart beah-srv
		sleep 10
		if [ "\$BMCNAME" ] ; then
			ipmitool -I lanplus -H "\$BMCNAME" -U Administrator -P "Administrator" power reset
		fi
		break
	fi
done
EOF
	fi

	( exec -a beaker_environment_checker bash $GTMPD/.beaker_environment_checker ) &
}

cleanup_system_default() {
	get_kernel_message_after
	get_kernel_message_diff
	cleanup_unimportant_temporal_files
}

check_system_default() {
	check_kernel_message_nobug
	if [ "$EXPECTED_RETURN_CODE" ] ; then
		check_return_code "$(echo $EXPECTED_RETURN_CODE | tr -s ' ')"
	fi
}

prepare() {
	local prepfunc
	local ret=0

	while true ; do # mocking goto
		if [ "$TEST_PREPARE" ] ; then
			prepfunc=$TEST_PREPARE
			$TEST_PREPARE
			[ $? -ne 0 ] && ret=1 && break;
		elif [ "$DEFAULT_TEST_PREPARE" ] ; then
			prepfunc=$DEFAULT_TEST_PREPARE
			$DEFAULT_TEST_PREPARE
			[ $? -ne 0 ] && ret=1 && break;
		elif [ "$(type -t _prepare)" = "function" ] ; then
			prepfunc=_prepare
			_prepare
			[ $? -ne 0 ] && ret=1 && break;
			prepare_system_default
			[ $? -ne 0 ] && ret=1 && break;
		else
			prepare_system_default
			[ $? -ne 0 ] && ret=1 && break;
		fi
		break;
	done

	if [ $ret -ne 0 ] ; then
		echo "test preparation failed ($prepfunc) check your environment." >&2
		count_skipped
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
	elif [ "$(type -t _control)" = "function" ] ; then
		_control "$pid" "$msg"
	fi
}

cleanup() {
	# TODO: unneccessary?
	local cleanfunc

	if [ "$TEST_CLEANUP" ] ; then
		cleanfunc=$TEST_CLEANUP
		$TEST_CLEANUP
	elif [ "$DEFAULT_TEST_CLEANUP" ] ; then
		cleanfunc=$DEFAULT_TEST_CLEANUP
		$DEFAULT_TEST_CLEANUP
	elif [ "$(type -t _cleanup)" = "function" ] ; then
		_cleanup
		cleanup_system_default
	else
		cleanup_system_default
	fi
}

check() {
	if [ "$TEST_CHECKER" ] ; then
		$TEST_CHECKER
	elif [ "$DEFAULT_TEST_CHECKER" ] ; then
		$DEFAULT_TEST_CHECKER
	elif [ "$(type -t _check)" = "function" ] ; then
		_check
		check_system_default
	else
		check_system_default
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
	# Didn't match, so we skip the current testcase, no need to call count_skipped
	# because if TESTCASE_FILTER is set, user knows they skip all filtered-out tests.
	clear_testcase
	return 0
}

# If the current testcase is not stable (so we are sure that the test should
# not pass on routine testing yet), we can set TEST_TYPE (to devel or debug)
# in your recipe file.
# Then, the testcase is executed only when you set environment variable RUN_MODE=devel.
# "return 1" means we run the current testcase. See also sample_test/sample.rc.
check_test_flag() {
	if [ ! "$TEST_TYPE" ] || [ "$TEST_TYPE" == stable ] ; then
		return 1
	fi
	[ "$RUN_MODE" == devel ] && return 1
	# Didn't match, so we skip the current testcase
	echo_log "Testcase $TEST_TITLE is skipped because it's not stable yet. If you"
	echo_log "really want to run the testcase, please set environment variable RUN_MODE=devel"
	count_skipped
	return 0
}

check_inclusion_of_fixedby_patch() {
	# no filter of inclusion of the FIXEDBY patch.
	[ ! "$FIXEDBY_SUBJECT" ] && [ ! "$FIXEDBY_COMMITID" ] && [ ! "$FIXEDBY_AUTHOR" ] && return 1
	# in 'devel' mode, caller should knows that this testcase could cause
	# system unstability like kernel panic
	[ "$RUN_MODE" == devel ] && return 1
	local cbranch=$(uname -r)
	if [ ! -d "$KERNEL_SRC" ] ; then
		echo_log "kernel source directory KERNEL_SRC $KERNEL_SRC not found"
		echo_log "Let's skip this testcase for safety"
		count_skipped
		return 0
	else
		cbranch=$(cd $KERNEL_SRC ; git log -n1 --pretty=format:%H)
	fi
	# explicit setting from recipe
	[ "$CURRENT_KERNEL" ] && cbranch="$CURRENT_KERNEL"
	pushd $KERNEL_SRC
	check_patch_applied "$cbranch" "$FIXEDBY_SUBJECT" "$FIXEDBY_COMMITID" "$FIXEDBY_AUTHOR" "$FIXEDBY_PATCH_SEARCH_DATE"
	local ret=$?
	popd > /dev/null
	[ $ret -eq 0 ] && return 1
	echo_log "Testcase $TEST_TITLE is skipped because it's known to fail without"
	echo_log "the following patch applied."
	echo_log "  Subject:"
	local subject=
	while read subject ; do
		if ! grep "$subject" $GTMPD/patches > /dev/null ; then
			echo_log "    $subject"
		fi
	done <<<"$(echo $FIXEDBY_SUBJECT | tr '|' '\n')"
	echo_log "  Commit: $FIXEDBY_COMMITID"
	echo_log "If you really want to run the testcase, please set environment variable"
	echo_log "CURRENT_KERNEL to some appropriate kernel version."
	count_skipped
	return 0
}

# return 1 if test (cmd) didn't run, otherwise return 0 even if test itself
# failed.
__do_test() {
	local cmd="$1"
	local line=

	if [ ! "$REBOOT" ] ; then # dirty hack
		init_return_code
	fi
	prepare
	if [ $? -ne 0 ] ; then
		cleanup
		return 1
	fi
	# TODO: check impact of removing this line on existing testcases.
	set_return_code_start
	echo_log "$cmd"

	# exec 2> >( tee -a ${OFILE} )
	# Keep pipe open to hold the data on buffer after the writer program
	# is terminated.
	exec 11<>${PIPE}
	eval "( $cmd ) &"
	local pid=$!
	while true ; do
		if ! check_process_status $pid ; then
			set_return_code "KILLED"
			break
		elif read -t${PIPETIMEOUT} line <> ${PIPE} ; then
			run_controller $pid "$line"
			if [ $? -eq 0 ] ; then
				break
			fi
		else
			if ! check_process_status $pid ; then
				set_return_code "KILLED"
				break
			else
				echo_log "time out, abort test"
				set_return_code "TIMEOUT"
				break
			fi
		fi
	done
	kill_all_subprograms
	exec 11<&-
	exec 11>&-

	cleanup
	check
	return 0
}

__do_test_async() {
	init_return_code
	prepare
	if [ $? -ne 0 ] ; then
		cleanup
		return 1
	fi
	set_return_code_start
	run_controller
	cleanup
	check
	return 0
}

export PIPETIMEOUT=5
generate_testcase_pipe() {
	export PIPE=$TMPD/.pipe
	mkfifo ${PIPE} 2> /dev/null
	[ ! -p ${PIPE} ] && echo_log "Fail to create pipe." >&2 && return 1
	chmod a+x ${PIPE}
}

do_test_try() {
	local ret=0
	local failure_before="$(cat $TMPD/_failure)"

	check_test_flag && return 1
	# check_inclusion_of_fixedby_patch && break

	if [ "$TEST_PROGRAM" ] ; then
		generate_testcase_pipe
		__do_test "$TEST_PROGRAM -p $PIPE"
	else
		__do_test_async
	fi
	# test aborted due to the preparation failure
	if [ $? -ne 0 ] ; then
		ret=1
	elif [ "$(cat $TMPD/_failure)" -gt "$failure_before" ] ; then
		ret=2
	else
		ret=0
	fi
	return $ret
}

warmup() {
	lib/test_allocate_generic -B anonymous -N 1000 -L "mmap access" > /dev/null 2>&1
}

# Returns fail if at least one of trails fails. So at least HARD_RETRY times
# are tried.
do_hard_try() {
	local ret=0
	local soft_try=$1

	if [ ! "$HARD_RETRY" ] || [ "$HARD_RETRY" -eq 1 ] ; then
		do_test_try
		return $?
	fi

	for hard_try in $(seq $HARD_RETRY) ; do
		echo_log "====> Trial #${soft_try:+$soft_try-}$hard_try"
		do_test_try
		case $? in
			0)
				echo_log "<==== Trial #${soft_try:+$soft_try-}$hard_try passed"
				;;
			1)
				ret=1
				break
				;;
			2)
				echo_log "<==== Trial #${soft_try:+$soft_try-}$hard_try failed"
				ret=2
				break
				;;
		esac
		warmup
	done
	return $ret
}

# Returns fail if all of trails fails.
do_soft_try() {
	local ret=0
	if [ ! "$SOFT_RETRY" ] || [ "$SOFT_RETRY" -eq 1 ] ; then
		do_hard_try
		ret=$?
	else
		for soft_try in $(seq $SOFT_RETRY) ; do
			echo_log "=====> Trial #$soft_try"
			do_hard_try $soft_try
			ret=$?
			case $ret in
				0)
					echo_log "<===== Trial #$soft_try passed"
					break
					;;
				1)
					echo_log "<===== skipped"
					break
					;;
				2)
					echo_log "<===== Trial #$soft_try failed"
					;;
			esac
			warmup
		done
	fi

	if [ "$ret" -eq 0 ] ; then
		echo_log "TESTCASE_RESULT: $recipe_relpath: PASS"
	elif [ "$ret" -eq 1 ] ; then
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
	elif [ "$ret" -eq 2 ] ; then
		echo_log "TESTCASE_RESULT: $recipe_relpath: FAIL"
	fi
	return $ret
}

set_rc_local() {
	cat <<EOF > /etc/rc.d/rc.local
#!/bin/bash

# need buffer for rescue from infinite loop
sleep 15

echo "##### test project $RUNNAME continues to run after reboot #####"
cd $TRDIR
export RUNNAME=$RUNNAME
nohup bash run.sh &
disown

mv /etc/rc.d/rc.local.tmp /etc/rc.d/rc.local
exit 0
EOF
	chmod +x /etc/rc.d/rc.local
}

revert_rc_local() {
	cat <<EOF > /etc/rc.d/rc.local
#!/bin/bash

touch /var/lock/subsys/local
EOF
	chmod +x /etc/rc.d/rc.local
}

dir_cleanup() {
	if [ "$(type -t _dir_cleanup)" = "function" ] ; then
		_dir_cleanup
	fi
}

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
	export -f $func
done
