#!/bin/bash

TCDIR=$(dirname $(readlink -f $BASH_SOURCE))
export TESTNAME="test"
VERBOSE=""
TESTCASE_FILTER=""
RECIPEDIR=
RECIPEFILES=

# script mode: execute recipe file as a single bash script.
SCRIPT=false

# subprocess mode where each testcase is processed in a separate process
# so functions and/or environment variable are free from conflict.
SUBPROCESS=false

DEVEL_MODE=

while getopts vs:t:f:Spd:r:D OPT ; do
    case $OPT in
        v) VERBOSE="-v" ;;
        s) KERNEL_SRC="${OPTARG}" ;;
        t) export TESTNAME="${OPTARG}" ;;
        f) export TESTCASE_FILTER="$TESTCASE_FILTER ${OPTARG}" ;;
        S) SCRIPT=true ;;
		p) SUBPROCESS=true ;;
		d) RECIPEDIR="$OPTARG" ;;
		r) RECIPEFILES="$RECIPEFILES $OPTARG" ;;
		D) DEVEL_MODE=true ;;
    esac
done

shift $[OPTIND-1]
[ "$RECIPEFILES" ] && RECIPEFILES="$(readlink -f $RECIPEFILES)"

for rd in $RECIPEDIR ; do
	if [ -d "$rd" ] ; then
		for rf in $(find $(readlink -f $rd) -type f) ; do
			RECIPEFILES="$RECIPEFILES $rf"
		done
	fi
done

[ ! "$RECIPEFILES" ] && echo "RECIPEFILES not given or not exist." >&2 && exit 1

# Assuming that current directory is the root directory of the current test.
export TRDIR=$PWD

# keep backward compatibility with older version of test_core
export NEWSTYLE=true

. $TCDIR/setup_generic.sh
. $TCDIR/setup_test_core.sh
. $TCDIR/setup_recipe.sh
. $TCDIR/lib/patch.sh
. $TCDIR/lib/common.sh

# record current revision of test suite and test_core tool
echo "Current test: $(basename $TRDIR)"
( cd $TRDIR ; echo "Test version: $(git log -n1 --pretty="format:%H %s")" )
( cd $TCDIR ; echo "Test Core version: $(git log -n1 --pretty="format:%H %s")" )

echo $TESTCASE_FILTER

for recipe in $RECIPEFILES ; do
	[ -d $recipe ] && continue
	# TEMPORARY
	[[ "$recipe" =~ race ]] && continue

	recipe_relpath=${recipe##$PWD/cases/}
	recipe_id=${recipe_relpath//\//_}

	# suffix is dropped in recipe_id
	check_remove_suffix $recipe || continue

	if [ "$TESTCASE_FILTER" ] ; then
		filtered=$(echo "$recipe_id" | grep $(_a="" ; for f in $TESTCASE_FILTER ; do _a="$_a -e $f" ; done ; echo $_a))
	fi

	if [ "$TESTCASE_FILTER" ] && [ ! "$filtered" ] ; then
		echo_verbose "===> SKIPPED: Recipe: $recipe_id"
		continue
	fi

	parse_recipefile $recipe .tmp.$recipe_id

	(
		. .tmp.$recipe_id
		export TMPD=$GTMPD/$recipe_relpath/
		export TMPF=$TMPD
		export OFILE=$TMPD/result
		mkdir -p $TMPD

		export TEST_TITLE=$recipe_id # compatibility
		# TODO: suppress filtered testcases at this point
		# check_testcase_filter || exit 1

		kill_all_subprograms
		reset_per_testcase_counters

		if [ "$TEST_PROGRAM" ] ; then
			do_test "$TEST_PROGRAM -p $PIPE $VERBOSE"
		else
			do_test_async
		fi
	) &
	testcase_pid=$!

	echo_verbose "===> Recipe: $recipe_relpath (ID: $recipe_id)"
	# echo_verbose "===> $$ -> $testcase_pid"
	wait $testcase_pid
done

# find $GTMPD -name testcount | while read line ; do echo $line $(cat $line) ; done
# find $GTMPD -name success | while read line ; do echo $line $(cat $line) ; done
# find $GTMPD -name later | while read line ; do echo $line $(cat $line) ; done

show_summary
