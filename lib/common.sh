MEMTOTAL=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')

check_and_define_tp() {
    local symbol=$1
    eval $symbol=$TRDIR/$symbol
    [ ! -e $(eval echo $"$symbol") ] && echo "$symbol not found." >&2 && exit 1
}

check_install_package() {
    local pkg=$1
    local path=$(which $pkg)
    if [ ! "$path" ] ; then
        echo "Package $pkg not found, so install now."
        yum install -y ${pkg}
    fi
    if [ ! -s "$path" ] ; then
        echo "$(which $pkg) is empty for some reason, so let's re-install now."
        yum reinstall -y ${pkg}
    fi
}
