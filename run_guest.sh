#!/bin/bash
#
# usage:
#   run standard testcases on VM (called from host user)
#     run_guest.sh <VM> <RUNNAME> <WORKDIR>
#
show_help() {
	sed -n 2,$[$BASH_LINENO-4]p $BASH_SOURCE | grep "^#" | sed 's/^#/ /'
	exit
}

cd $(dirname $BASH_SOURCE)

FAILRETRY=${FAILRETRY:=3}
PRIORITY=${PRIORITY:=0-15}
TIMEOUT=${TIMEOUT:=150}

VM=$1
RUNNAME=$2
WDIR=$3

[ ! "$VM" ] && echo "no VM given" && show_help
[ ! "$RUNNAME" ] && echo "no RUNNAME given" && show_help
[ ! "$WDIR" ] && echo "no WDIR given" && show_help

mkdir -p /tmp/run_guest.sh
TMPD=$(mktemp -d /tmp/run_guest.sh/XXXXXX)

ruby test_core/lib/vm_serial_setting.rb $VM > $TMPD/serial

if grep -q file-based $TMPD/serial ; then
	echo file
	SERIALFILE=$(sed -n 2p $TMPD/serial)
else
	echo "WARNING: serial console of guest $VM is not file log based, so you will not have serial console output during testing."
	echo "Try to use test_core/lib/vm_serial_setting.rb for serial setting."
fi

check_finished() {
	true
}

rsync -ae ssh ./ $VM:$WDIR || exit 1

ssh $VM \
	RUNNAME=$RUNNAME \
	FAILRETRY=$FAILRETRY \
	RUN_MODE=normal,devel \
	LOGLEVEL=1 \
	PRIOIRTY=$PRIORITY \
	BACKGROUND=true \
	bash $WDIR/run.sh

# wait for test to finish.
for i in $(seq $TIMEOUT) ; do
	sleep 60

	if ssh $VM stat $WDIR/work/$RUNNAME/$FAILRETRY/finished 2>&1 > /dev/null ; then
		break
	else
		echo "$(date +'%y%m%d %H:%M:%S') ($i/$TIMEOUT) testing on vm $VM still running..."
	fi
done

# save serial output
mkdir -p $TMPD/work/$RUNNAME/
rsync -ae ssh $VM:$WDIR/work/$RUNNAME/ $TMPD/work/$RUNNAME/
if [ -f "$SERIALFILE" ] ; then
	mv $SERIALFILE $TMPD/work/$RUNNAME/console.log
fi

echo "Done, output data is put under $TMPD/work."
