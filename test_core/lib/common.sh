MEMTOTAL=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')
MEMFREE=$(grep ^MemFree: /proc/meminfo | awk '{print $2}')
[ ! "$KERNEL_SRC" ] && KERNEL_SRC=/src/linux-dev

# higher value means more verbose (0:minimum, 1:normal (default), 2:verbose)
[ ! "$LOGLEVEL" ] && export LOGLEVEL=1
[ ! "$SOFT_RETRY" ] && SOFT_RETRY=2

[ ! "$PRIORITY" ] && export PRIORITY=0-10

normalize_priority() {
	local out=
	local elm=
	for elm in $(echo $@ | tr ',' ' ') ; do
		if [[ "$elm" =~ [0-9]-[0-9] ]] ; then
			local a1=$(echo $elm | cut -f1 -d'-')
			local a2=$(echo $elm | cut -f2 -d'-')
			out="$out,$(seq $a1 $a2 | tr '\n' ',')"
		else
			out="$out,$elm"
		fi
	done
	echo $out, | sed 's/,,/,/g'
}

check_skip_priority() {
	local test_priority=$1

	echo $_PRIORITY | grep -q ",$test_priority,"
}

_PRIORITY=$(normalize_priority $PRIORITY)

check_and_define_tp() {
    local symbol=$1
    eval $symbol=$TRDIR/$symbol
    [ ! -e $(eval echo $"$symbol") ] && echo "$symbol not found." >&2 && exit 1
}

check_install_package() {
    local pkg=$1
    if ! yum list installed "$pkg" > /dev/null 2>&1 ; then
        yum install -y ${pkg}
    fi
}

collect_subprocesses() {
	[ "$#" -eq 0 ] && return
	local tmp=""

	for t in $@ ; do
		tmp="$tmp $(grep "^$t " $RTMPD/.ps-jx | cut -f2 -d' ' | tr '\n' ' ')"
	done
	echo -n "$tmp "
	collect_subprocesses $tmp
}

collect_orphan_processes() {
	local sid=$1
	ps jx | awk '{print $1, $2, $3, $4}' | grep " $sid$" | grep -v " $sid $sid $sid$" | grep "^1 " | cut -f2 -d' ' | tr '\n' ' '
}

# keep SESSIONID to find process sub-tree and/or orphan processes later.
SESSIONID=$(ps -p $$ --no-headers -o sid | tr -d ' ')

# kill all subprocess of the given process, and orphan processes belonging to
# the same process group. If the second argument is non-null, $pid itself will
# be killed too.
kill_all_subprograms() {
	local pid=$1
	local self=$2

	ps jx | grep -v "ps jx$" | awk '{print $1, $2, $4}' | grep " $SESSIONID$" | cut -f1-2 -d' ' > $RTMPD/.ps-jx
	local subprocs="$(collect_subprocesses $pid)"
	local orphanprocs="$(collect_orphan_processes $SESSIONID)"
	echo_verbose "collect_subprocesses $pid/$SESSIONID: $subprocs"
	echo_verbose "orphan_processes $pid/$SESSIONID: $orphanprocs"
	kill -9 ${self:+$pid} $subprocs 2> /dev/null
	kill -9 $orphanprocs 2> /dev/null
	rm -f $RTMPD/.ps-jx
}

check_process_status() {
	local pid=$1

	kill -0 $pid 2> /dev/null
}

system_health_check() {
	if dmesg | tail -n 100 | grep -q "Failed to send WATCHDOG=1 notification message" ; then
		echo "WARNING: Failed to send WATCHDOG=1 notification message"
		if [ "$TEST_RUN_MODE" ] || [ "$REBOOTABLE" ] ; then
			echo "systemd seems have unstability, so reboot before continuing testing."
			sync
			echo 1 > /proc/sys/kernel/sysrq
			echo b > /proc/sysrq-trigger
			exit 1
		fi
	fi

	systemctl status -q test 2> /dev/null
	if [ "$?" -eq 1 ] ; then
		echo "WARNING: systemd (PID 1) caught some signal and got frozen."
		if [ "$TEST_RUN_MODE" ] || [ "$REBOOTABLE" ] ; then
			echo "Let's restart the system to keep test reliable."
			echo 1 > /proc/sys/kernel/sysrq
			echo b > /proc/sysrq-trigger
			exit 1
		fi
	fi
}

check_binary() {
	local func="$1"

	if ! which $func ; then
		echo "binary '$func' not available, test skipped." >&2
		return 1
	fi
	return 0
}
