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
	env > $ENVDIR/env
	git log -n1 > $ENVDIR/testtool_version
	git diff > $ENVDIR/testtool_version.diff
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
		echo "Testing host ($(hostname)) might not be the one you originally intended ($(awk '{print $3}' $ENVDIR/hostname))."
		exit 1
	fi
}

# TODO: more elegant way?
save_environment_variables() {
	if [ -d "$RTMPD" ] ; then
		( set -o posix; set ) > $RTMPD/.var2
		diff -u $RTMPD/.var1 $RTMPD/.var2 | grep ^+ | grep -v '^++ ' | cut -c2- > $RTMPD/variables
	fi
}

check_environment
collect_environment_info 2> /dev/null
