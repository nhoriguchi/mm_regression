#!/bin/bash
#
# Usage
#   run-test.sh [options]
#
# Description
#
# Options
#
#   -v <loglevel>
#   -s <kernel_source_path>
#   -p <priority>            set priority range to be executed
#   -V                       show version info of this test tool
#   -h                       show this message
#
# Environment variables:
#
#   - RUNNAME
#   - AGAIN
#   - SKIP_PASS
#   - SKIP_FAIL
#   - SKIP_WARN
#   - RUN_MODE
#   - LOGLEVEL
#   - PRIORITY
#   - SOFT_RETRY
#   - HARD_RETRY
#   - BACKWARD_KEYWORD
#   - FORWARD_KEYWORD
#   - ROUND
#
show_help() {
        sed -n 2,$[$BASH_LINENO-4]p $BASH_SOURCE | grep "^#" | sed 's/^#/ /'
}

SHOW_TEST_VERSION=
while getopts v:s:p:DVh OPT ; do
	case $OPT in
		v) export LOGLEVEL="$OPTARG" ;;
		s) KERNEL_SRC="$OPTARG" ;;
		p) PRIORITY=$OPTARG ;;
		D) DEVEL_MODE=true ;;
		V) SHOW_TEST_VERSION=true ;;
		h)
			show_help
			exit 0
			;;
	esac
done

shift $[OPTIND-1]

export LANG=C
export LC_ALL=C

export TCDIR=$(dirname $(readlink -f $BASH_SOURCE))
# Assuming that current directory is the root directory of the current test.
export TRDIR=$PWD

. $TCDIR/setup_generic.sh
. $TCDIR/setup_test_core.sh

# record current revision of test suite and test_core tool
if [ "$SHOW_TEST_VERSION" ] ; then
	echo "Current test: $(basename $TRDIR)"
	echo "RUNNAME: $RUNNAME"
	( cd $TRDIR ; echo "Test version: $(git log -n1 --pretty="format:%H %s")" )
	( cd $TCDIR ; echo "Test Core version: $(git log -n1 --pretty="format:%H %s")" )
	exit 0
fi

. $TCDIR/lib/recipe.sh
. $TCDIR/lib/patch.sh
. $TCDIR/lib/common.sh

if [ "$USER" = root ] ; then
	sysctl -q kernel.panic_on_warn=1
	sysctl -q kernel.panic_on_oops=1
	sysctl -q kernel.softlockup_panic=1
	sysctl -q kernel.softlockup_all_cpu_backtrace=1
	sysctl -q kernel.core_pattern="|/bin/false"
	sysctl -q fs.suid_dumpable=0
	# systemctl stop systemd-journald.service
fi

stop_test_running() {
	echo "kill_all_subprograms $BASHPID by signal"
	kill_all_subprograms $BASHPID
	exit
}

trap stop_test_running SIGTERM SIGINT

prepare_run_recipe() {
	local recipes=$1
	for rid in $(cat $recipes) ; do
		local rfile=cases/$rid
		local rtmpd=$GTMPD/$rid
		mkdir -p $rtmpd > /dev/null 2>&1
		cp $rfile $rtmpd/_recipe
	done
}

run_recipe() {
	local recipe_id=$1
	export RECIPE_FILE="cases/$recipe_id"
	export TEST_TITLE=$recipe_id
	export RTMPD=$GTMPD/$recipe_id

	if [ ! -s "$RECIPE_FILE" ] ; then
		echo "Recipe file not found: '$RECIPE_FILE'"
		return
	fi

	[ "$VERBOSE" ] && set -x

	# recipe run status check
	check_testcase_already_run && return

	if [ -d $RTMPD ] && [ "$AGAIN" == true ] ; then
		rm -rf $RTMPD/* > /dev/null 2>&1
	fi
	mkdir -p $RTMPD > /dev/null 2>&1

	check_remove_suffix $RECIPE_FILE || return

	system_health_check || return

	# just for saving, not functional requirement.
	cp $RECIPE_FILE $RTMPD/_recipe

	( set -o posix; set ) > $RTMPD/.var1

	TEST_PRIORITY=10 # TODO: better place?
	# TODO: helpful if we can save stdout in loading process, but this might
	# break test control.
	set -o pipefail
	. $RECIPE_FILE # | tee -a $RTMPD/result
	ret=$?
	echo_log "===> testcase '$TEST_TITLE' start" | tee /dev/kmsg

	if recipe_load_check $recipe_id $ret | tee -a $RTMPD/result ; then
		save_environment_variables
		# reminder for restart after reboot. If we find this file when starting,
		# that means the reboot was triggerred during running the testcase.
		if [ "$TEST_RUN_MODE" ] && [ -f $GTMPD/__current_testcase ] && [ "$RECIPE_FILE" = $(cat $GTMPD/__current_testcase) ] ; then
			# restarting from reboot
			local doit=true
			if [ -s "$RTMPD/reboot_count" ] ; then
				local rcount=$(cat $RTMPD/reboot_count)
				rcount=$[rcount+1]
				echo $rcount > $RTMPD/reboot_count

				if [ "$rcount" -gt "${MAX_REBOOT:-0}" ] ; then
					echo "System rebooted more than expected (${MAX_REBOOT:-0}), so let's finish this testcase." | tee -a $RTMPD/result
					doit=false
				fi
			fi

			if [ "$doit" = true ] ; then
				echo "reboot during running testcase $TEST_TITLE, and the testcase expect the reboot, so let's start round $[rcount+1]." | tee -a $RTMPD/result
				echo_verbose "PID calling do_soft_try $BASHPID"
				do_soft_try > >(tee -a $RTMPD/result) 2>&1
			fi
		else
			echo 0 > $RTMPD/reboot_count
			echo $RECIPE_FILE > $GTMPD/__current_testcase
			echo RUNNING > $RTMPD/run_status
			date +%s%3N > $RTMPD/start_time
			sync
			# TODO: put general system information under $RTMPD
			# prepare empty testcount file at first because it's used to check
			# testcase result from summary script.
			reset_per_testcase_counters
			echo_verbose "PID calling do_soft_try $BASHPID"
			do_soft_try > >(tee -a $RTMPD/result) 2>&1
		fi
		date +%s%3N > $RTMPD/end_time
		echo FINISHED > $RTMPD/run_status
		rm -f $GTMPD/__current_testcase
		echo -n $recipe_id > $GTMPD/__finished_testcase
		sync
	fi
	set +o pipefail
	echo_log "<=== testcase '$TEST_TITLE' end" | tee /dev/kmsg
}

run_recipes() {
	local pid=
	local basedir=$(echo $@ | cut -f1 -d:)
	local elms="$(echo $@ | cut -f2- -d:)"
	# echo "- parsing [$basedir] $elms"

	if [ -f "cases/$basedir/config" ] ; then
		# TODO: this is a hack for dir_cleanup, to be simplified.
		# local tmp="$(echo $basedir | sed 's|cases|work/'${RUNNAME:=debug}'|')"
		local tmp="work/${RUNNAME:=debug}/$basedir"
		mkdir -p $tmp
		echo $BASHPID > $tmp/BASHPID
		. "cases/$basedir/config"
		if [ "$?" -ne 0 ] ; then
			echo "skip this directory due to the failure in cases/$basedir/config"
			return 1
		fi
	fi

	local elm=
	local keepdir=
	local linerecipe=
	for elm in $elms ; do
		local dir=$(echo $elm | cut -f1 -d/)
		local abc=$(echo $elm | cut -f2- -d/)

		# echo "-- $elm: $dir, $abc"
		if [ "$elm" = "$dir" ] ; then # file
			if [ "$keepdir" ] ; then # end of previous dir
				(
					run_recipes "$linerecipe"
				) &
				pid=$!
				echo_verbose "$FUNCNAME: $$/$BASHPID -> $pid"
				wait $pid
				keepdir=
				linerecipe=
			fi
			# execute file recipe
			# echo "--- Execute recipe: $basedir/$elm"
			(
				run_recipe "$basedir/$elm"
			) &
			pid=$!
			echo_verbose "$FUNCNAME (new recipe $dir: $basedir/$elm): $$/$BASHPID -> $pid"
			wait $pid
		else # dir
			# echo "--- $keepdir"
			if [ "$keepdir" != "$dir" ] ; then # new dir
				if [ "$keepdir" ] ; then # end of previous dir
					# echo "--- 1: run_recipes \"$linerecipe\""
					(
						run_recipes "$linerecipe"
					) &
					pid=$!
					echo_verbose "$FUNCNAME: $$/$BASHPID -> $pid"
					wait $pid
					linerecipe=
				fi
				linerecipe="${basedir:+$basedir/}$dir: $abc"
				keepdir=$dir
				# echo "--- 3"
			else # keep dir
				linerecipe="$linerecipe $abc"
				# echo "--- 5"
			fi
		fi
	done
	if [ "$linerecipe" ] ; then
		(
			run_recipes "$linerecipe"
		) &
		pid=$!
		echo_verbose "$FUNCNAME: $$/$BASHPID -> $pid"
		wait $pid
	fi

	if [ -s "$tmp/BASHPID" ] && [ "$(cat $tmp/BASHPID)" = "$BASHPID" ] ; then
		dir_cleanup
	fi
}

filter_recipe_list() {
	local recipefile=$1
	local run_mode=
	local priority=
	if [ "$RUN_MODE" ] && [ "$RUN_MODE" != "all" ] ; then
		run_mode="-t $RUN_MODE"
	fi
	if [ "$PRIORITY" ] ; then
		priority="-p $PRIORITY"
	fi
	echo "ruby test_core/lib/recipe.rb list -r $recipefile $run_mode $priority"
	ruby test_core/lib/recipe.rb list -r $recipefile $run_mode $priority | cut -f3 > $GTMPD/__run_recipes
}

generate_recipelist() {
	if [ ! -f "$GTMPD/full_recipe_list" ] ; then
		make --no-print-directory allrecipes > $GTMPD/full_recipe_list
	fi

	if [ -s "$GTMPD/full_recipe_list" ] && [ ! -f "$GTMPD/recipelist" ] ; then
		echo "$GTMPD/recipelist not found, so all testcases in $GTMPD/full_recipe_list is included."
		cp $GTMPD/full_recipe_list $GTMPD/recipelist
	fi

	# recipe control, need to have separate function for this
	if [ "$AGAIN" == true ] ; then
		rm -f $GTMPD/__finished_testcase 2> /dev/null
	fi

	if [ -f "$GTMPD/__finished_testcase" ] ; then
		local nr_point="$(grep -x -n $(cat $GTMPD/__finished_testcase) $GTMPD/recipelist | cut -f1 -d:)"
		sed -n $[nr_point + 1]',$p' $GTMPD/recipelist > $GTMPD/__remaining_recipelist
	else
		cp $GTMPD/recipelist $GTMPD/__remaining_recipelist
	fi

	# filter recipelist based on priority and test type
	# $GTMPD/__run_recipes is the final recipe list to run.
	filter_recipe_list $GTMPD/__remaining_recipelist

	if [ "$FILTER" ] ; then
		grep "$FILTER" $GTMPD/__run_recipes > $GTMPD/__run_recipes2
		mv $GTMPD/__run_recipes2 $GTMPD/__run_recipes
	fi
}

generate_recipelist
. $TCDIR/lib/environment.sh

if [ "$USER" != root ] ; then
	run_recipes ": $(cat $GTMPD/__run_recipes | tr '\n' ' ')"
	exit
fi

if [ "$BACKGROUND" ] ; then # kick background service and kick now
	if [ "$FAILRETRY" ] && [ "$ROUND" ] && [ "$FAILRETRY" -gt "$ROUND" ] ; then
		setup_systemd_service $(dirname $RUNNAME) $FAILRETRY $ROUND
		systemctl start test.service
	else
		setup_systemd_service $RUNNAME
		systemctl start test.service
	fi
else
	prepare_run_recipe $GTMPD/recipelist
	run_recipes ": $(cat $GTMPD/__run_recipes | tr '\n' ' ')"
	echo "All testcases in project $RUNNAME finished." | tee /dev/kmsg
	touch work/$RUNNAME/__finished
	ruby test_core/lib/test_summary.rb work/$RUNNAME

	if [ -f /etc/systemd/system/test.service ] ; then
		if [ "$FAILRETRY" ] && [ "$ROUND" ] && [ "$FAILRETRY" -gt "$ROUND" ] ; then
			echo "Retry failure cases until reaching retry limit $FAILRETRY (current round: $ROUND)"
			setup_systemd_service $(dirname $RUNNAME) $FAILRETRY $[ROUND+1]
			systemctl restart test.service
		else
			cancel_systemd_service
		fi
	fi
fi
