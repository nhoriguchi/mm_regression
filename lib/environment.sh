export ENVDIR=$GTMPD/environment

collect_environment_info() {
	mkdir -p $ENVDIR
	uname -a > $ENVDIR/uname-a
	hostname > $ENVDIR/hostname
	lscpu > $ENVDIR/lscpu
	lsblk > $ENVDIR/lsblk
	lsmod > $ENVDIR/lsmod
	lsmem > $ENVDIR/lsmem
	virsh list --all > $ENVDIR/virsh-list
	true
}

# test sequence could cause system reboot, so we have to check we really
# testing the same kernel after reboot.
check_environment() {
	[ "$AGAIN" ] && return

	if [ -s "$ENVDIR/uname-r" ] && [ "$(cat $ENVDIR/uname-r)" != "$(uname -a)" ] ; then
		echo "Testing kernel ($(uname -r)) might not be the one you originally intended ($(awk '{print $3}' $ENVDIR/uname-a))."
		exit 1
	fi

	if [ -s "$ENVDIR/hostname" ] && [ "$(cat $ENVDIR/hostname)" != "$(hostname)" ] ; then
		echo "Testing host ($(hostnamer)) might not be the one you originally intended ($(awk '{print $3}' $ENVDIR/hostname))."
		exit 1
	fi
}

save_environment_variables() {
	if [ -d "$TMPD" ] ; then
		env | grep = | grep -v "^ " > $TMPD/environment
	fi
}

check_environment
collect_environment_info
