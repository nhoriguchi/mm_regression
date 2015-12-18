MEMTOTAL=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')
KERNEL_SRC=/src/linux-dev

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
    # if [ ! -s "$path" ] ; then
    #     echo "path for $pkg is empty for some reason, so let's re-install now."
    #     yum reinstall -y ${pkg} > /dev/null
    # fi
}

kill_all_subprograms() {
	for tp in $(grep ^src= $TRDIR/Makefile | cut -f2 -d=) ; do
		local tmp=${tp%.c}
		# echo "pkill -9 -f $(eval echo \$$(echo $tmp))"
		eval "pkill -9 -f \$$(echo $tmp)"
	done
}

# Getting all C program into variables, which is convenient to calling
# pkill to kill all subprobrams before/after some testcase.
for tp in $(grep ^src= $TRDIR/Makefile | cut -f2 -d=) ; do
	check_and_define_tp ${tp%.c}
done

for func in $(grep '^\w*()' $BASH_SOURCE | sed 's/^\(.*\)().*/\1/g') ; do
    export -f $func
done
