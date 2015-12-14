#!/bin/bash

TCDIR=$(dirname $(readlink -f $BASH_SOURCE))
export TESTNAME="test"
VERBOSE=""
TESTCASE_FILTER=""

# script mode: execute recipe file as a single bash script.
SCRIPT=false

# subprocess mode where each testcase is processed in a separate process
# so functions and/or environment variable are free from conflict.
SUBPROCESS=false

while getopts vs:t:f:Sp OPT ; do
    case $OPT in
        "v" ) VERBOSE="-v" ;;
        "s" ) KERNEL_SRC="${OPTARG}" ;;
        "t" ) export TESTNAME="${OPTARG}" ;;
        "f" ) export TESTCASE_FILTER="${OPTARG}" ;;
        "S" ) SCRIPT=true ;;
		"p" ) SUBPROCESS=true ;;
    esac
done

shift $[OPTIND-1]
RECIPEFILE=$1

[ ! -e "$RECIPEFILE" ] && echo "RECIPEFILE not given or not exist." >&2 && exit 1

# Assuming that current directory is the root directory of the current test.
export TRDIR=$PWD # $(dirname $(readlink -f $RECIPEFILE))

. $TCDIR/setup_generic.sh
. $TCDIR/setup_test_core.sh
. $TCDIR/setup_recipe.sh
. $TCDIR/lib/patch.sh

# record current revision of test suite and test_core tool
echo "Current test: $(basename $TRDIR)"
( cd $TRDIR ; echo "Test version: $(git log -n1 --pretty="format:%H %s")" )
( cd $TCDIR ; echo "Test Core version: $(git log -n1 --pretty="format:%H %s")" )

# original recipe can 'embed' other small parts
echo .tmp.${RECIPEFILE/\//_}

parse_recipefile $RECIPEFILE .tmp.${RECIPEFILE/\//_}

(
	echo "---"
	. .tmp.${RECIPEFILE/\//_}

	if [ "$TEST_PROGRAM" ] ; then
		do_test "$TEST_PROGRAM -p $PIPE $VERBOSE"
	else
		do_test_async
	fi
)

show_summary
