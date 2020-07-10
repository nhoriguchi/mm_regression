cd $(dirname $BASH_SOURCE)

[ ! "$TEST_DESCRIPTION" ] && TEST_DESCRIPTION="MM regression test"
export TEST_DESCRIPTION

[ ! "$RUNNAME" ] && RUNNAME=debug
export RUNNAME

# export AGAIN=true
export UNPOISON=false

export PATH=$PWD/build:$PATH

[ ! "$SOFT_RETRY" ] && SOFT_RETRY=3
export SOFT_RETRY
[ ! "$HARD_RETRY" ] && HARD_RETRY=1
export HARD_RETRY

if [ "$FAILRETRY" ] ; then
	make -s build
	export RUNNAME=${FAILRETRY}.a
	make prepare || exit 1
	ruby test_core/lib/test_summary.rb -C work/$FAILRETRY | grep ^FAIL | cut -f4 -d' ' > work/$RUNNAME/recipelist
	export BACKGROUND=true
	# TODO: how to pass environment variables
	make --no-print-directory test
	exit 0
elif [[ "$1" =~ cases/ ]] ; then
	if [ "$RUNNAME" == debug ] ; then
		make prepare
		grep $1 work/$RUNNAME/full_recipe_list > work/$RUNNAME/recipelist
	else
		make prepare
		export FILTER="$1"
	fi
	if [ ! -s work/$RUNNAME/recipelist ] ; then
		echo "no recipe matched to $1" >&2
		exit 1
	fi
	make -s build
	make --no-print-directory test
	exit 0
fi

recipelist=$1

if [ "$recipelist" ] ; then
	export RECIPELIST=$recipelist
fi

# make --no-print-directory prepare
make -s build
make prepare
make --no-print-directory test
