TMPD=$(mktemp -d)

ndctl list -B > $TMPD/ndctl_list_all

NDBUS=$(jq -r .[].dev $TMPD/ndctl_list_all)
[ ! "$NDBUS" ] && echo "failed to extract ndbus device" && exit 1
SYSDIR=$(readlink -f /sys/bus/nd/devices/$NDBUS)
[ ! -d "$SYSDIR" ] && exit 1

get_nvdimm_namespace_layout() {
	for resfile in $(find $SYSDIR/ | grep resource) ; do
		resdir=$(dirname $resfile)
		devname=$(basename $resdir)
		resstart=$(cat $resfile 2> /dev/null)
		ressize=$(cat $resdir/size 2> /dev/null)
		if [ "$resstart" ] ; then
			printf "%s\t0x%012lx\t0x%012lx\n" $devname $resstart $ressize >> $TMPD/table
		fi
	done
	sort -k2,2 -k3,3r $TMPD/table > $TMPD/table.sorted

	printf "%s\t%s\t%s\n" device start size > $TMPD/table2
	for abc in $(cat $TMPD/table.sorted | grep -e ^region -e ^namespace | cut -f1) ; do
		grep ^$abc $TMPD/table.sorted >> $TMPD/table2
		if [[ "$abc" =~ ^region ]] ; then
			region=$abc
		else
			holder=$(cat $SYSDIR/$region/$abc/holder)
			mode=$(cat $SYSDIR/$region/$abc/mode)
			uuid=$(cat $SYSDIR/$region/$abc/uuid)
			if [ ! "$uuid" ] ; then # seed
				continue
			elif [ "$mode" == raw ] ; then
				devfile=$(ls -1 $SYSDIR/$region/$abc/block)
				size=$(cat $SYSDIR/$region/$abc/block/$devfile/size | xargs printf "0x%lx")
				echo "  (raw)" >> $TMPD/table2
				echo "    $devfile" >> $TMPD/table2
			elif [ "$mode" == safe ] ; then # sector
				devfile=$(ls -1 $SYSDIR/$region/$abc/../$holder/block)
				echo "  $holder" >> $TMPD/table2
				echo "    $devfile" >> $TMPD/table2
			elif [ "$mode" == memory ] ; then # fsdax
				devfile=$(ls -1 $SYSDIR/$region/$abc/../$holder/block)
				devsize=$(cat $SYSDIR/$region/$abc/../$holder/size)
				devres=$(cat $SYSDIR/$region/$abc/../$holder/resource)
				printf "  $holder\t0x%012lx\t0x%012lx\n" $devres $devsize >> $TMPD/table2
				printf "    $devfile\n" >> $TMPD/table2
			elif [ "$mode" == dax ] ; then # devdax
				devfile=$(basename $(dirname $(find $SYSDIR/$region/$abc/../$holder/ -type f | grep /dev$)))
				devsize=$(cat $SYSDIR/$region/$abc/../$holder/$devfile/size)
				devres=$(cat $SYSDIR/$region/$abc/../$holder/$devfile/resource)
				echo "  $holder" >> $TMPD/table2
				printf "    $devfile\t0x%012lx\t0x%012lx\n" $devres $devsize >> $TMPD/table2
			fi
		fi
	done
	cat $TMPD/table2 | expand -t 20
}

get_nvdimm_namespace_layout
