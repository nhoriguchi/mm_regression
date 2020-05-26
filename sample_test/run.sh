export RUNNAME=debug
export AGAIN=true

export SOFT_RETRY=1
export HARD_RETRY=1

recipelist=$1

if [ "$recipelist" ] ; then
	export RECIPELIST=$recipelist
fi

make --no-print-directory prepare
make --no-print-directory test
ruby test_core/lib/test_summary.rb -v -C work/$RUNNAME
