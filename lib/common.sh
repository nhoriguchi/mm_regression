MEMTOTAL=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')

check_and_define_tp() {
    local symbol=$1
    eval $symbol=$TRDIR/$symbol
    [ ! -e $(eval echo $"$symbol") ] && echo "$symbol not found." >&2 && exit 1
}
