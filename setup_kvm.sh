. $TCDIR/lib/mm.sh
. $TCDIR/lib/kvm.sh

[ ! -x /usr/local/bin/sshvm ] && install $TCDIR/lib/sshvm /usr/local/bin/sshvm
[ ! "$VM" ] && echo_log "You must give VM name in recipe file" && return 1

SSH_OPT="-o ConnectTimeout=5"
GPA2HPA=$(dirname $(readlink -f $BASH_SOURCE))/gpa2hpa.rb
GUESTTESTALLOC=/usr/local/bin/test_alloc_generic
GUESTPAGETYPES=/usr/local/bin/page-types

send_helper_to_guest() {
	local vmip=$1

	scp $test_alloc_generic $vmip:$GUESTTESTALLOC > /dev/null
	scp $PAGETYPES $vmip:$GUESTPAGETYPES > /dev/null
}

stop_guest_memeater() {
	local vmip=$1

	ssh $vmip "pkill -9 -f $GUESTTESTALLOC > /dev/null 2>&1 </dev/null"
}

start_guest_memeater() {
	local vm=$1
	local vmip=$(sshvm -i $vm 2> /dev/null)
	local size=$2
	
	stop_guest_memeater $vmip

	echo_log "start running test_alloc_generic on VM ($vm:$vmip)"
	if [ "$BACKEND" == clean_pagecache ] ; then
		ssh $vmip "
			$GUESTTESTALLOC -B pagecache -n $size -f read -L \"mmap access:type=read:wait_after access:type=read:wait_after\" > /dev/null 2>&1 </dev/null &"
	elif [ "$BACKEND" == dirty_pagecache ] ; then
		ssh $vmip "
			$GUESTTESTALLOC -B pagecache -n $size -f write -L \"mmap access:type=write:wait_after access:type=write:wait_after\" > /dev/null 2>&1 </dev/null &"
	elif [ "$BACKEND" == anonymous ] ; then
		ssh $vmip "
			$GUESTTESTALLOC -B anonymous -n $size -L \"mmap access:wait_after access:wait_after\" > /dev/null 2>&1 </dev/null &"
	elif [ "$BACKEND" == thp ] ; then
		ssh $vmip "
			$GUESTTESTALLOC -B thp -n $size -L \"mmap access:wait_after access:wait_after\" > /dev/null 2>&1 </dev/null &"
	else
		ssh $vmip "
			$GUESTTESTALLOC -B pagecache -B anonymous -B thp -n $size -L \"mmap access:wait_after access:wait_after\" > /dev/null 2>&1 </dev/null &"
	fi
	ssh $vmip "pgrep -f $GUESTTESTALLOC" | tr '\n' ' ' > $TMPD/_guest_memeater_pids.1
	if [ ! -s $TMPD/_guest_memeater_pids.1 ] ; then
		echo "Failed to start guest memeater $GUESTTESTALLOC" >&2
		return 1
	fi
	return 0
}
