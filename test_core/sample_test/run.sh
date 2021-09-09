cd $(dirname $BASH_SOURCE)

[ ! "$TEST_DESCRIPTION" ] && TEST_DESCRIPTION="sample_test"
export TEST_DESCRIPTION

[ ! "$RUNNAME" ] && RUNNAME=debug
export RUNNAME

# export AGAIN=true

[ ! "$SOFT_RETRY" ] && SOFT_RETRY=1
export SOFT_RETRY
[ ! "$HARD_RETRY" ] && HARD_RETRY=1
export HARD_RETRY

make build

if [ "$FAILRETRY" -gt 1 ] ; then
	[ ! "$ROUND" ] && export ROUND=1
	BASERUNNAME=$RUNNAME
	export RUNNAME=$RUNNAME/$ROUND
	make --no-print-directory prepare
	if [ "$ROUND" -gt 1 ] ; then
		ruby test_core/lib/test_summary.rb -C work/$BASERUNNAME/$[ROUND-1] | grep -e ^FAIL -e ^WARN | cut -f4 -d' ' > work/$RUNNAME/recipelist
	else
		make --no-print-directory prepare
	fi
else
	make --no-print-directory prepare
fi

if [ "$1" ] ; then
	export FILTER="$1"
fi

make --no-print-directory test
