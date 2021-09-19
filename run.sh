cd $(dirname $BASH_SOURCE)

if [ "$1" = "-h" ] || [ "$1" = "--help" ] ; then
	bash test_core/run-test.sh -h
	exit 0
fi

[ ! "$TEST_DESCRIPTION" ] && TEST_DESCRIPTION="MM regression test"
export TEST_DESCRIPTION

[ ! "$RUNNAME" ] && RUNNAME=debug
export RUNNAME

# export AGAIN=true
export UNPOISON=false

export PATH=$PWD/build:$PATH

[ ! "$SOFT_RETRY" ] && SOFT_RETRY=1
export SOFT_RETRY
[ ! "$HARD_RETRY" ] && HARD_RETRY=1
export HARD_RETRY

make -s build

if [ "$FAILRETRY" ] && [ "$FAILRETRY" -gt 1 ] ; then
	# TODO: rename ROUND?
	[ ! "$ROUND" ] && export ROUND=1
	BASERUNNAME=$RUNNAME
	export RUNNAME=$RUNNAME/$ROUND
	make --no-print-directory prepare
	if [ "$ROUND" -gt 1 ] ; then
		ruby test_core/lib/test_summary.rb -C work/$BASERUNNAME/$[ROUND-1] | grep -e ^FAIL -e ^WARN | cut -f4 -d' ' > work/$RUNNAME/recipelist
	else
		if [ -f work/$BASERUNNAME/recipelist ] ; then
			cp work/$BASERUNNAME/recipelist work/$RUNNAME/recipelist
		fi
	fi
elif [ "$FAILRETRY" ] ; then
	export RUNNAME=${FAILRETRY}.a
	make --no-print-directory prepare
	ruby test_core/lib/test_summary.rb -C work/$FAILRETRY | grep -e ^FAIL -e ^WARN | cut -f4 -d' ' > work/$RUNNAME/recipelist
	export BACKGROUND=true
	# TODO: how to pass environment variables
else
	make --no-print-directory prepare
fi

if [ "$1" ] ; then
	export FILTER="$1"
fi

make --no-print-directory test
