MEMTOTAL=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')
MEMFREE=$(grep ^MemFree: /proc/meminfo | awk '{print $2}')
KERNEL_SRC=/src/linux-dev

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
		tmp="$tmp $(grep "^$t " $GTMPD/.ps-fj | cut -f2 -d' ' | tr '\n' ' ')"
	done
	echo -n "$tmp "
	collect_subprocesses $tmp
}

collect_orphan_processes() {
	local sid=$(ps -p $$ --no-headers -o sid | tr -d ' ')
	ps fj | awk '{print $1, $2, $4}' | grep " $sid$" | grep "^1 " | cut -f2 -d' ' | tr '\n' ' '
}

# kill all subprocess of the given process, and orphan processes belonging to
# the same process group. If the second argument is non-null, $pid itself will
# be killed too.
kill_all_subprograms() {
	local pid=$1
	local self=$2
	local sid=$(ps -p $pid --no-headers -o sid | tr -d ' ')
	ps fj | grep -v "ps fj$" | awk '{print $1, $2, $4}' | grep " $sid$" | cut -f1-2 -d' ' > $GTMPD/.ps-fj
	echo_verbose "collect_subprocesses $pid: $(collect_subprocesses $pid)"
	echo_verbose "orphan_processes: $(collect_orphan_processes)"
	kill -9 ${self:+$pid} $(collect_subprocesses $pid) 2> /dev/null
	kill -9 $(collect_orphan_processes) 2> /dev/null
	rm -f $GTMPD/.ps-jf
}

check_process_status() {
	local pid=$1

	kill -0 $pid 2> /dev/null
}
