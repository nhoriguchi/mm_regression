# deploy with standard namespace layout

if [ "$1" = autoyes ] ; then
	AUTOYES=true
fi

# Environment
FSTYPE=ext4

TMPDIR=$(mktemp -d)

# check system status
ndctl list -iR > $TMPDIR/ndctl_list_iR

NR_REGIONS=$(jq length $TMPDIR/ndctl_list_iR)

if [ ! "$NR_REGIONS" ] ; then
	echo no regions found >&2
	exit 1
fi

SIZE_REGIONS=$(jq "[.[].size] | add" $TMPDIR/ndctl_list_iR)
GB_REGIONS=$[SIZE_REGIONS >> 30]

if [ ! "$GB_REGIONS" ] ; then
	echo failed to retrieve NVDIMM capacity >&2
	exit 1
fi

NR_SECTOR=1
NR_RAW=1
NR_DEVDAX=1
NR_FSDAX=8
NR_NAMESPACES=$[NR_SECTION + NR_RAW + NR_DEVDAX + NR_FSDAX]
# align to 6 (interleave set)
BASE_SIZE=$[(GB_REGIONS/NR_NAMESPACES/6)*6]
if [ "$BASE_SIZE" -gt 126 ] ; then
	BASE_SIZE=126
fi

if [ ! "$AUTOYES" ] ; then
	echo -n "destory all current namespaces [y/N]? "
	read input
	if [ "$input" != y ] && [ "$input" != Y ] ; then
		exit 0
	fi
fi

ndctl list -iN > $TMPDIR/ndctl_list_iN
ndctl list -iN | jq -r ".[].blockdev" | grep -v null > $TMPDIR/destroy.blocks
for dev in $(cat $TMPDIR/destroy.blocks) ; do
	umount -f /dev/$dev
done
ndctl destroy-namespace -f all || exit 1

for i in $(seq $NR_SECTOR) ; do
	mountpoint=/mnt/sector${i}
	mkdir -p $mountpoint
	ndctl create-namespace -m sector -s ${BASE_SIZE}G > $TMPDIR/create.sector${i} || continue
	blockdev=$(jq -r ".blockdev" $TMPDIR/create.sector${i})
	mkfs.$FSTYPE /dev/$blockdev || continue
	mount /dev/$blockdev $mountpoint
done

for i in $(seq $NR_RAW) ; do # maybe unused
	mkdir -p /mnt/raw$i
	ndctl create-namespace -m raw -s ${BASE_SIZE}G > $TMPDIR/create.raw${i}
done

for i in $(seq $NR_DEVDAX) ; do # maybe unused
	ndctl create-namespace -m devdax -s ${BASE_SIZE}G > $TMPDIR/create.devdax${i}
done

for i in $(seq $NR_FSDAX) ; do
	mountpoint=/mnt/pmem${i}
	mkdir -p $mountpoint
	ndctl create-namespace -m fsdax -s ${BASE_SIZE}G > $TMPDIR/create.fsdax${i} || continue
	blockdev=$(jq -r ".blockdev" $TMPDIR/create.fsdax${i})
	mkfs.$FSTYPE /dev/$blockdev || continue
	mount -o dax /dev/$blockdev $mountpoint
done
