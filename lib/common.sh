MEMTOTAL=$(grep ^MemTotal: /proc/meminfo | awk '{print $2}')

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
