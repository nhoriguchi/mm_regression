. $TRDIR/lib/setup_mmgeneric.sh

SWAPFILE=$TDIR/swapfile

__prepare_memcg() {
	cgdelete cpu,memory:test1 2> /dev/null
	cgdelete cpu,memory:test2 2> /dev/null
	cgcreate -g cpu,memory:test1 || return 1
	cgcreate -g cpu,memory:test2 || return 1
	echo 1 > $MEMCGDIR/test1/memory.move_charge_at_immigrate || return 1
	echo 1 > $MEMCGDIR/test2/memory.move_charge_at_immigrate || return 1
}

__prepare_swap_device() {
	local count=$1
	[ $? -ne 0 ] && echo "failed to __prepare_memcg" && return 1
	rm -f $SWAPFILE
	dd if=/dev/zero of=$SWAPFILE bs=4096 count=$count > /dev/null 2>&1
	[ $? -ne 0 ] && echo "failed to create $SWAPFILE" && return 1
	chmod 0600 $SWAPFILE
	mkswap $SWAPFILE
	echo "swapon $SWAPFILE"
	swapon $SWAPFILE || return 1
	swapon -s
}

__cleanup_memcg() {
	cgdelete cpu,memory:test1 || return 1
	cgdelete cpu,memory:test2 || return 1
}

__cleanup_swap_device() {
	swapon -s
	swapoff $SWAPFILE
	ipcrm --all
	rm -rf $SWAPFILE
}
