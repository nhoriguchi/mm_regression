#!/bin/bash

DEVEL_MODE=
# LOGLEVEL might be set as an environment variable
# RECIPELIST might be set as an environment variable
# TESTCASE_FILTER might be set as an environment variable
SHOW_TEST_VERSION=
# PRIORITY might be set as an environment variable
RUN_ALL_WAITING=

while getopts v:s:t:f:Sp:DVw OPT ; do
    case $OPT in
        v) export LOGLEVEL="$OPTARG" ;;
        s) KERNEL_SRC="$OPTARG" ;;
        t) TESTNAME="$OPTARG" ;;
        f) TESTCASE_FILTER="$TESTCASE_FILTER $OPTARG" ;;
        S) SCRIPT=true ;;
		p) PRIORITY=$OPTARG ;;
		D) DEVEL_MODE=true ;;
		V) SHOW_TEST_VERSION=true ;;
		w) RUN_ALL_WAITING=true ;;
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
	echo "TESTNAME/RUNNAME: $TESTNAME"
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
fi

stop_test_running() {
	echo "kill_all_subprograms $BASHPID by signal"
	kill_all_subprograms $BASHPID
	exit
}

trap stop_test_running SIGTERM SIGINT

skip_testcase_out_priority() {
	echo_log "This testcase is skipped because the testcase priority ($TEST_PRIORITY) is not within given priority range [$PRIORITY]."
	echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
}

run_recipe() {
	export RECIPE_FILE="$1"
	local recipe_relpath=$(echo $RECIPE_FILE | sed 's/.*cases\///')
	export TEST_TITLE=$recipe_relpath
	export RTMPD=$GTMPD/$recipe_relpath
	export TMPF=$TMPD

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
	. $RECIPE_FILE
	ret=$?
	echo_log "===> testcase '$TEST_TITLE' start" | tee /dev/kmsg

	if [ "$SKIP_THIS_TEST" ] ; then
		echo_log "This testcase is marked to be skipped by developer."
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
		echo SKIPPED > $RTMPD/run_status
	elif [ "$ret" -ne 0 ] ; then
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
		echo SKIPPED > $RTMPD/run_status
	elif ! check_skip_priority $TEST_PRIORITY ; then
		skip_testcase_out_priority
		echo SKIPPED > $RTMPD/run_status
	elif check_test_flag ; then
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
		echo SKIPPED > $RTMPD/run_status
		# TODO: check_inclusion_of_fixedby_patch && break
	else
		save_environment_variables

		# reminder for restart after reboot. If we find this file when starting,
		# that means the reboot was triggerred during running the testcase.
		if [ "$TEST_RUN_MODE" ] && [ -f $GTMPD/current_testcase ] && [ "$RECIPE_FILE" = $(cat $GTMPD/current_testcase) ] ; then
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
			echo $RECIPE_FILE > $GTMPD/current_testcase
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
		rm -f $GTMPD/current_testcase
		echo -n cases/$recipe_relpath > $GTMPD/finished_testcase
		sync
	fi
	echo_log "<=== testcase '$TEST_TITLE' end" | tee /dev/kmsg
}

run_recipes() {
	local pid=
	local basedir=$(echo $@ | cut -f1 -d:)
	local elms="$(echo $@ | cut -f2- -d:)"
	# echo "- parsing [$basedir] $elms"

	if [ -f "$basedir/config" ] ; then
		# TODO: this is a hack for dir_cleanup, to be simplified.
		local tmp="$(echo $basedir | sed 's|cases|work/'${RUNNAME:=debug}'|')"
		echo $BASHPID > $tmp/BASHPID
		. "$basedir/config"
		if [ "$?" -ne 0 ] ; then
			echo "skip this directory due to the failure in $basedir/config" >&2
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

generate_recipelist() {
	if [ -f "$RECIPELIST" ] ; then # RECIPELIST is given by caller
		cp $RECIPELIST $GTMPD/recipelist
	elif [ ! -f "$GTMPD/recipelist" ] ; then
		if [ -f "$GTMPD/full_recipe_list" ] ; then
			cp $GTMPD/full_recipe_list $GTMPD/recipelist
		else
			make --no-print-directory allrecipes | grep ^cases | sort > $GTMPD/recipelist
		fi
	fi

	# recipe control, need to have separate function for this
	if [ "$AGAIN" == true ] ; then
		rm -f $GTMPD/finished_testcase 2> /dev/null
	fi
	if [ "$FILTER" ] ; then
		grep "$FILTER" $RLIST > /tmp/current_recipelist2
		RLIST=/tmp/current_recipelist2
	elif [ -f "$GTMPD/finished_testcase" ] ; then
		local nr_point="$(grep -x -n $(cat $GTMPD/finished_testcase) $RLIST | cut -f1 -d:)"
		sed -n $[nr_point + 1]',$p' $RLIST > /tmp/current_recipelist
		RLIST=/tmp/current_recipelist
	fi
}

RLIST=$GTMPD/recipelist
# RLIST could be updated in generate_recipelist()
generate_recipelist

. $TCDIR/lib/environment.sh

if [ "$USER" != root ] ; then
	run_recipes ": $(cat $RLIST | tr '\n' ' ')"
	exit
fi

if [ "$BACKGROUND" ] ; then # kick background service and kick now
	setup_systemd_service
	systemctl start test.service
else
	run_recipes ": $(cat $RLIST | tr '\n' ' ')"
	cancel_systemd_service
	echo "All testcases in project $RUNNAME finished." | tee /dev/kmsg
	ruby test_core/lib/test_summary.rb work/$RUNNAME
fi
