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
BASE_SIZE=$[(GB_REGIONS/NR_NAMESPACES/8)*6]
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

available_region() {
	local size=$1

	ndctl list -R | jq -r '.[] | select(.available_size > '$size') | .dev' | head -n1
}

# Note: ndctl-create-namespace might create unexpectedly multiple namespaces
# with --force option, so we might need explicitly specify region with -r option.

for i in $(seq $NR_SECTOR) ; do
	mountpoint=/mnt/sector${i}
	mkdir -p $mountpoint
	region=$(available_region $[BASE_SIZE << 30])
	if [ ! "$region" ] ; then
		echo "no space available"
		exit 1
	fi
	echo "ndctl create-namespace -f -r $region -n sector${i} -m sector -s ${BASE_SIZE}G"
	ndctl create-namespace -f -r $region -n sector${i} -m sector -s ${BASE_SIZE}G > $TMPDIR/create.sector${i} || continue

	blockdev=$(ndctl list -N -i | jq -r '.[] | select(.name == "sector'${i}'") | .blockdev' | head -1)
	echo "mkfs.$FSTYPE -F /dev/$blockdev"
	mkfs.$FSTYPE -F /dev/$blockdev || continue
	mount /dev/$blockdev $mountpoint
done

for i in $(seq $NR_RAW) ; do
	mkdir -p /mnt/raw$i
	region=$(available_region $[BASE_SIZE << 30])
	if [ ! "$region" ] ; then
		echo "no space available"
		exit 1
	fi
	echo "ndctl create-namespace -f -r $region -n raw${i} -m raw -s ${BASE_SIZE}G"
	ndctl create-namespace -f -r $region -n raw${i} -m raw -s ${BASE_SIZE}G > $TMPDIR/create.raw${i}
done

for i in $(seq $NR_DEVDAX) ; do
	region=$(available_region $[BASE_SIZE << 30])
	if [ ! "$region" ] ; then
		echo "no space available"
		exit 1
	fi
	echo "ndctl create-namespace -f -r $region -n devdax${i} -m devdax -s ${BASE_SIZE}G"
	ndctl create-namespace -f -r $region -n devdax${i} -m devdax -s ${BASE_SIZE}G > $TMPDIR/create.devdax${i}
done

for i in $(seq $NR_FSDAX) ; do
	mountpoint=/mnt/pmem${i}
	mkdir -p $mountpoint
	region=$(available_region $[BASE_SIZE << 30])
	if [ ! "$region" ] ; then
		echo "no space available"
		exit 1
	fi
	echo "ndctl create-namespace -f -r $region -n fsdax${i} -m fsdax -s ${BASE_SIZE}G"
	ndctl create-namespace -f -r $region -n fsdax${i} -m fsdax -s ${BASE_SIZE}G > $TMPDIR/create.fsdax${i} || continue

	blockdev=$(ndctl list -N -i | jq -r '.[] | select(.name == "fsdax'${i}'") | .blockdev' | head -1)
	echo "mkfs.$FSTYPE -F /dev/$blockdev"
	mkfs.$FSTYPE -F /dev/$blockdev || continue
	mount -o dax /dev/$blockdev $mountpoint
done
