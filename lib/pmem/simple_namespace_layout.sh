MODE=$1

umount -f /dev/pmem*
ndctl destroy-namespace -f all || exit 1

if [ "$MODE" == fsdax ] ; then
	FSTYPE=ext4
	MNT=/mnt/pmem1
	set -x
	ndctl create-namespace -f --name "fsdax" -m $MODE || exit 1
	DEV=$(ndctl list -N -i | jq -r '.[].blockdev' | head -1)
	echo "mkfs.$FSTYPE -F /dev/$DEV"
	mkfs.$FSTYPE -F /dev/$DEV || exit 1
	mkdir -p $MNT
	mount -o dax /dev/$DEV $MNT || exit 1
else
	echo "not implemented"
	exit 1
fi


