wait_timeout() {
	local timeout=$1
	shift 1
	local pids="$@"
	local ret=0

	# wait $pids

	echo "$pids"
	while true ; do
		# all processes are finished
		if ! kill -0 $pids 2> /dev/null ; then
			break
		fi

		if [ "$timeout" -le 0 ] ; then
			ret=1
			break
		fi

		sleep 1
		timeout=$[timeout - 1]
	done

	return $ret
}

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
	pids=

	sleep 2 &
	pids="$pids $!"

	sleep 8 &
	pids="$pids $!"

	wait_timeout 5 $pids
	echo $?
fi

