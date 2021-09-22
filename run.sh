cd $(dirname $BASH_SOURCE)

if [ "$1" = "-h" ] || [ "$1" = "--help" ] ; then
	bash test_core/run-test.sh -h
	exit 0
fi

# export AGAIN=true
# export BACKGROUND=true
export TEST_DESCRIPTION=${TEST_DESCRIPTION:="MM regression test"}
export RUNNAME=${RUNNAME:=debug}
export SOFT_RETRY=${SOFT_RETRY:=1}
export HARD_RETRY=${HARD_RETRY:=1}
export RUN_MODE=${RUN_MODE:=normal}

export PATH=$PWD/build:$PATH
export UNPOISON=false

make -s build

if [ "$FAILRETRY" ] && [ "$FAILRETRY" -gt 1 ] ; then
	# TODO: rename ROUND?
	[ ! "$ROUND" ] && export ROUND=1
	BASERUNNAME=$RUNNAME
	export RUNNAME=$BASERUNNAME/$ROUND
	make --no-print-directory prepare
	if [ ! -f  work/$RUNNAME/recipelist ] ; then
		if [ "$ROUND" -gt 1 ] ; then
			ruby test_core/lib/test_summary.rb -C work/$BASERUNNAME/$[ROUND-1] | grep -e ^FAIL -e ^WARN | cut -f4 -d' ' > work/$RUNNAME/recipelist
		else
			if [ -f work/$BASERUNNAME/recipelist ] ; then
				cp work/$BASERUNNAME/recipelist work/$RUNNAME/recipelist
			fi
		fi
		make --no-print-directory prepare
	fi
fi

if [ "$1" ] ; then
	export FILTER="$1"
fi

make --no-print-directory test
