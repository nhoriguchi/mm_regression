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
make prepare
make --no-print-directory test
