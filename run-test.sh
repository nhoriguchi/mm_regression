#!/bin/bash

DEVEL_MODE=
# LOGLEVEL might be set as an environment variable
# RECIPELIST might be set as an environment variable
# TESTCASE_FILTER might be set as an environment variable
SHOW_TEST_VERSION=
# HIGHEST_PRIORITY might be set as an environment variable
# LOWEST_PRIORITY might be set as an environment variable
RUN_ALL_WAITING=

while getopts v:s:t:f:SpDVh:l:w OPT ; do
    case $OPT in
        v) export LOGLEVEL="$OPTARG" ;;
        s) KERNEL_SRC="$OPTARG" ;;
        t) TESTNAME="$OPTARG" ;;
        f) TESTCASE_FILTER="$TESTCASE_FILTER $OPTARG" ;;
        S) SCRIPT=true ;;
		p) SUBPROCESS=true ;;
		D) DEVEL_MODE=true ;;
		V) SHOW_TEST_VERSION=true ;;
		h) HIGHEST_PRIORITY=$OPTARG ;;
		l) LOWEST_PRIORITY=$OPTARG ;;
		w) RUN_ALL_WAITING=true ;;
    esac
done

shift $[OPTIND-1]

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

stop_test_running() {
	ps x -o  "%p %r %y %x %c" | grep $$
	kill -9 -$(ps --no-header -o "%r" $$)
	kill_all_subprograms
	exit
}

trap stop_test_running SIGTERM SIGINT

echo 1 > /proc/sys/kernel/panic_on_oops
echo 1 > /proc/sys/kernel/softlockup_panic
echo 1 > /proc/sys/kernel/softlockup_all_cpu_backtrace

skip_testcase_out_priority() {
	echo_log "This testcase is skipped because the testcase priority ($PRIORITY) is not within given priority range [$HIGHEST_PRIORITY, $LOWEST_PRIORITY]. To run this, set HIGEST_PRIORITY and LOWEST_PRIORITY to contain PRIORITY ($PRIORITY)"
	echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
}

run_recipe() {
	local recipe="$1"
	local recipe_relpath=$(echo $recipe | sed 's/.*cases\///')
	export TEST_TITLE=$recipe_relpath
	export TMPD=$GTMPD/$recipe_relpath
	export TMPF=$TMPD
	export OFILE=$TMPD/result

	parse_recipefile $recipe .tmp.recipe

	if [ -d $TMPD ] && [ "$AGAIN" == true ] ; then
		rm -rf $TMPD/* > /dev/null 2>&1
	fi
	mkdir -p $TMPD > /dev/null 2>&1

	mv .tmp.recipe $TMPD/_recipe
	PRIORITY=10 # TODO: better place?
	. $TMPD/_recipe
	ret=$?
	echo_log "===> testcase '$TEST_TITLE' start" | tee /dev/kmsg

	if check_testcase_already_run ; then
		echo_log "### You already have workfiles for recipe $recipe_relpath with TESTNAME: $TESTNAME, so skipped. If you really want to run with removing old work directory, please give environment variable AGAIN=true."
	elif ! check_remove_suffix $recipe ; then
		return
	elif [ "$SKIP_THIS_TEST" ] ; then
		echo_log "This testcase is marked to be skipped by developer."
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
	elif [ "$ret" -ne 0 ] ; then
		echo_log "TESTCASE_RESULT: $recipe_relpath: SKIP"
	elif [ "$PRIORITY" ] && [ "$HIGHEST_PRIORITY" -gt "$PRIORITY" ] ; then
		skip_testcase_out_priority
	elif [ "$PRIORITY" ] && [ "$LOWEST_PRIORITY" -lt "$PRIORITY" ] ; then
		skip_testcase_out_priority
	else
		date +%s%3N > $TMPD/start_time
		# TODO: put general system information under $TMPD
		# prepare empty testcount file at first because it's used to check
		# testcase result from summary script.
		reset_per_testcase_counters
		init_return_code

		( do_soft_try ) 2>&1 | tee -a $OFILE
		date +%s%3N > $TMPD/end_time
	fi
	echo_log "<=== testcase '$TEST_TITLE' end" | tee /dev/kmsg
}

run_recipe_tree() {
	local dir="$1"

	if [ -f "$dir/config" ] ; then
		. "$dir/config"
	fi

	for f in $(ls -1 $dir) ; do
		(
			if [ "$f" == config ] ; then
				true
			elif [ -f "$dir/$f" ] ; then
				run_recipe "$dir/$f"
			elif [ -d "$dir/$f" ] ; then
				run_recipe_tree "$dir/$f"
			fi
		) &
		wait $!
	done
}

get_next_level() {
	local dir="$1"
	local list="$2"

	cat $list | sed "s|^|$PWD/|" | grep ^$dir/ | sed -e "s|^$dir/||" | cut -f1 -d / | uniq
}

run_recipe_list() {
	local dir="$1"
	local list="$2"

	if [ -f "$dir/config" ] ; then
		. "$dir/config"
	fi

	for f in $(get_next_level $dir $list) ; do
		(
			if [ "$f" == config ] ; then
				true
			elif [ -f "$dir/$f" ] ; then
				run_recipe "$dir/$f"
			elif [ -d "$dir/$f" ] ; then
				run_recipe_list "$dir/$f" "$list"
			fi
		) &
		wait $!
	done
}

run_recipes() {
	local dir=$1
	local list=$2

	if [ -f "$list" ] ; then
		run_recipe_list $dir $list
	else
		run_recipe_tree $dir
	fi
}

if [ -f "$RECIPELIST" ] ; then
	cp $RECIPELIST $GTMPD/recipelist
elif [ ! -f "$GTMPD/recipelist" ] ; then
	make --no-print-directory allrecipes | grep ^cases > $GTMPD/recipelist
fi
# make --no-print-directory RUNNAME=$RUNNAME waiting_recipes | grep ^cases > $GTMPD/waiting_recipe_list

run_recipes $TRDIR $GTMPD/recipelist
