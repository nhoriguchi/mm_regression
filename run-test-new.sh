#!/bin/bash

VERBOSE=""
DEVEL_MODE=
# RECIPEFILES might be set as an environment variable
# RECIPEDIR might be set as an environment variable
# TESTCASE_FILTER might be set as an environment variable
SHOW_TEST_VERSION=

while getopts vs:t:f:Spd:r:DV OPT ; do
    case $OPT in
        v) VERBOSE="-v" ;;
        s) KERNEL_SRC="${OPTARG}" ;;
        t) TESTNAME="$OPTARG" ;;
        f) TESTCASE_FILTER="$TESTCASE_FILTER ${OPTARG}" ;;
        S) SCRIPT=true ;;
		p) SUBPROCESS=true ;;
		d) RECIPEDIR="$OPTARG" ;;
		r) RECIPEFILES="$RECIPEFILES $OPTARG" ;;
		D) DEVEL_MODE=true ;;
		V) SHOW_TEST_VERSION=true ;;
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

# keep backward compatibility with older version of test_core
export NEWSTYLE=true

[ "$RECIPEFILES" ] && RECIPEFILES="$(readlink -f $RECIPEFILES)"

for rd in $RECIPEDIR ; do
	if [ -d "$rd" ] ; then
		for rf in $(find $(readlink -f $rd) -type f) ; do
			RECIPEFILES="$RECIPEFILES $rf"
		done
	fi
done

[ ! "$RECIPEFILES" ] && echo "RECIPEFILES not given or not exist." >&2 && exit 1
export RECIPEFILES

. $TCDIR/lib/recipe.sh
. $TCDIR/lib/patch.sh
. $TCDIR/lib/common.sh

stop_test_running() {
	ps x -o  "%p %r %y %x %c" | grep $$
	kill -9 -$(ps --no-header -o "%r" $$)
}

trap stop_test_running SIGTERM

echo "=====> start testing $(basename $TRDIR):$TESTNAME"
echo "RECIPEFILES:"
echo "${RECIPEFILES//$TRDIR\/cases\//}"

for recipe in $RECIPEFILES ; do
	if [ ! -f "$recipe" ] ; then
		"Recipe $recipe must be a regular file." >&2
		continue
	fi

	recipe_relpath=${recipe##$PWD/cases/}
	# recipe_id=${recipe_relpath//\//_}

	check_remove_suffix $recipe || continue

	if [ "$TESTCASE_FILTER" ] ; then
		filtered=$(echo "$recipe_relpath" | grep $(_a="" ; for f in $TESTCASE_FILTER ; do _a="$_a -e $f" ; done ; echo $_a))
	fi

	if [ "$TESTCASE_FILTER" ] && [ ! "$filtered" ] ; then
		echo_verbose "===> SKIPPED: Recipe: $recipe_relpath"
		continue
	fi

	parse_recipefile $recipe .tmp.recipe

	(
		export TEST_TITLE=$recipe_relpath
		export TMPD=$GTMPD/$recipe_relpath
		export TMPF=$TMPD
		export OFILE=$TMPD/result

		if check_testcase_already_run ; then
			echo "### You already have workfiles for recipe $recipe_relpath with TESTNAME: $TESTNAME, so skipped."
			echo "### If you really want to run with removing old work directory, please give environment variable AGAIN=true."
			continue
		fi

		if [ -d $TMPD ] ; then
			rm -rf $TMPD/* > /dev/null 2>&1
		else
			mkdir -p $TMPD > /dev/null 2>&1
		fi

		# TODO: suppress filtered testcases at this point
		# check_testcase_filter || exit 1

		echo_log "===> Recipe: $recipe_relpath (ID: $recipe_relpath)"
		date +%s > $TMPD/start_time
		reset_per_testcase_counters
		init_return_code

		mv .tmp.recipe $TMPD/_recipe
		. $TMPD/_recipe

		if [ "$TEST_PROGRAM" ] ; then
			do_test "$TEST_PROGRAM -p $PIPE $VERBOSE"
		else
			do_test_async
		fi

		date +%s > $TMPD/end_time
	) &
	testcase_pid=$!

	# echo_verbose "===> Recipe: $recipe_relpath (ID: $recipe_relpath)"
	# echo_verbose "===> $$ -> $testcase_pid"
	wait $testcase_pid
done

# find $GTMPD -name testcount | while read line ; do echo $line $(cat $line) ; done
# find $GTMPD -name success | while read line ; do echo $line $(cat $line) ; done
# find $GTMPD -name later | while read line ; do echo $line $(cat $line) ; done

ruby $TCDIR/lib/test_summary.rb --only-total $GTMPD
show_summary
