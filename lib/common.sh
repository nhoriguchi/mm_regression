MEMTOTAL=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')
MEMFREE=$(grep ^MemFree: /proc/meminfo | awk '{print $2}')
KERNEL_SRC=/src/linux-dev

# higher value means more verbose (0:minimum, 1:normal (default), 2:verbose)
[ ! "$LOGLEVEL" ] && export LOGLEVEL=1
[ ! "$SOFT_RETRY" ] && SOFT_RETRY=2

[ ! "$HIGHEST_PRIORITY" ] && export HIGHEST_PRIORITY=0
[ ! "$LOWEST_PRIORITY" ] && export LOWEST_PRIORITY=10

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

kill_all_subprograms() {
	for tp in $(grep ^src= $TRDIR/Makefile | cut -f2 -d=) ; do
		local tmp=${tp%.c}
		eval "pkill -9 -f \$$(echo $tmp)" > /dev/null 2>&1
	done
}

check_process_status() {
	local pid=$1

	kill -0 $pid 2> /dev/null
}

# Getting all C program into variables, which is convenient to calling
# pkill to kill all subprobrams before/after some testcase.
for tp in $(grep ^src= $TRDIR/Makefile 2> /dev/null | cut -f2 -d=) ; do
	check_and_define_tp ${tp%.c}
done

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
    export -f $func
done
