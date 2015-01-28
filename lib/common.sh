MEMTOTAL=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')

check_and_define_tp() {
    local symbol=$1
    local name=$2
    [ ! "$name" ] && name=$symbol
    echo "$symbol=$TRDIR/$name"
    eval $symbol=$TRDIR/$name
    [ ! -x $(eval echo $"$symbol") ] && echo "$path not found." >&2 && exit 1
}
