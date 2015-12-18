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

[ ! -e "$RECIPEFILE" ] && exit 1

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

# workaround for compatibility with older test_core
export TMPD=$GTMPD
export OFILE=$TMPD/result
mkdir -p $TMPD

# original recipe can 'embed' other small parts
parse_recipefile $RECIPEFILE .tmp.$RECIPEFILE

# less .tmp.$RECIPEFILE

if [ "$SCRIPT" == true ] ; then
    bash .tmp.${RECIPEFILE}
else
    while read line ; do
        [ ! "$line" ] && continue
        [[ $line =~ ^# ]] && continue

        if [ "$line" = do_test_sync ] ; then
            if [ ! "$TEST_PROGRAM" ] ; then
                echo "no TEST_PROGRAM given for '${TEST_TITLE}'. Check your recipe."
                exit 1
            fi
            do_test "$TEST_PROGRAM -p ${PIPE} ${VERBOSE}"
        elif [ "$line" = do_test_async ] ; then
            do_test_async
        else
            eval $line
        fi
    done < .tmp.${RECIPEFILE}
fi

show_summary
