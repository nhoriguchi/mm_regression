#!/bin/bash

TCDIR=$(dirname $(readlink -f $BASH_SOURCE))
export TESTNAME="test"
VERBOSE=""
TESTCASE_FILTER=""
SCRIPT=false # script mode

while getopts vs:t:f:S OPT ; do
    case $OPT in
        "v" ) VERBOSE="-v" ;;
        "s" ) KERNEL_SRC="${OPTARG}" ;;
        "t" ) export TESTNAME="${OPTARG}" ;;
        "f" ) export TESTCASE_FILTER="${OPTARG}" ;;
        "S" ) SCRIPT=true
    esac
done

shift $[OPTIND-1]
RECIPEFILE=$1

[ ! -e "$RECIPEFILE" ] && exit 1

# Assuming that current directory is the test root directory.
export TRDIR=$PWD # $(dirname $(readlink -f $RECIPEFILE))

. $TCDIR/setup_generic.sh
. $TCDIR/setup_test_core.sh
. $TCDIR/setup_recipe.sh
. $TCDIR/lib/patch.sh

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
