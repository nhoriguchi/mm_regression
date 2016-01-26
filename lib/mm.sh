PAGETYPES=$KERNEL_SRC/tools/vm/page-types
if [ ! -x "${PAGETYPES}" ] || [ ! -s "${PAGETYPES}" ] ; then
    make clean -C $KERNEL_SRC/tools > /dev/null 2>&1
    echo -n "build KERNEL_SRC/tools ... "
    make vm -C $KERNEL_SRC/tools > /dev/null 2>&1 && echo "done" || echo "failed"
fi
[ ! -x "${PAGETYPES}" ] && echo "Failed to build/install ${PAGETYPES}." >&2 && exit 1

. $TCDIR/lib/numa.sh
. $TCDIR/lib/mce.sh
. $TCDIR/lib/hugetlb.sh
. $TCDIR/lib/thp.sh
. $TCDIR/lib/memcg.sh
. $TCDIR/lib/ksm.sh

# The behavior of page flag set in typical workload could change, so
# we must keep up with newest kernel.
get_backend_pageflags() {
	case $1 in
		buddy)			# __________BM_____________________________
			echo "buddy"
			;;
		anonymous)		# ___U_lA____Ma_b__________________________
			echo "huge,thp,mmap,anonymous=anonymous,mmap"
			;;
		pagecache)		# __RU_lA____M_____________________________
			echo "huge,thp,mmap,anonymous,file=mmap,file"
			;;
		clean_pagecache)
			echo "dirty,huge,thp,mmap,anonymous,file=mmap,file"
			;;
		dirty_pagecache)
			echo "dirty,huge,thp,mmap,anonymous,file=dirty,mmap,file"
			;;
		hugetlb_all)    # _______________H_G_______________________
			echo "huge,compound_head=huge,compound_head"
			;;
		hugetlb_mapped) # ___________M___H_G_______________________
			echo "huge,compound_head,mmap=huge,compound_head,mmap"
			;;
		hugetlb_free)	# _______________H_G_______________________
			echo "huge,compound_head,mmap=huge,compound_head"
			;;
		hugetlb_anon)	# ___U_______Ma__H_G_______________________
			echo "huge,mmap,anonymous,compound_head=huge,mmap,anonymous,compound_head"
			;;
		hugetlb_shmem)	# ___U_______M___H_G_______________________
			echo "huge,mmap,anonymous,compound_head=huge,mmap,compound_head"
			;;
		# How to distinguish?
		hugetlb_file)	# ___U_______M___H_G_______________________
			echo "huge,mmap,anonymous,compound_head=huge,mmap,compound_head"
			;;
		ksm)			# __RUDlA____Ma_b______x___________________
			echo "ksm=ksm"
			;;
		thp)			# ___U_lA____Ma_bH______t__________________
			echo "thp,mmap,anonymous,compound_head=thp,mmap,anonymous,compound_head"
			;;
		thp_doublemap)
			;;
		zero)			# ________________________z________________
			echo "thp,zero_page=zero_page"
			;;
		huge_zero)		# ______________________t_z________________
			echo "thp,zero_page=thp,zero_page"
			;;
	esac
}

prepare_mm_generic() {
	if [ "$NUMA_NODE" ] ; then
		numa_check || return 1
	fi

	if [ "$HUGETLB" ] ; then
		hugetlb_support_check || return 1
		if [ "$HUGEPAGESIZE" ] ; then
			hugepage_size_support_check || return 1
		fi
		set_and_check_hugetlb_pool $HUGETLB
		HUGETLB_MOUNT=$WDIR/hugetlbfs
		rm -rf $HUGETLB_MOUNT/* > /dev/null 2>&1
		umount -f $HUGETLB_MOUNT > /dev/null 2>&1
		rm -rf $HUGETLB_MOUNT > /dev/null 2>&1
		mkdir -p $HUGETLB_MOUNT > /dev/null 2>&1
		mount -t hugetlbfs none $HUGETLB_MOUNT || return 1
	fi

	if [ "$HUGETLB_OVERCOMMIT" ] ; then
		set_hugetlb_overcommit $HUGETLB_OVERCOMMIT
		set_return_code SET_OVERCOMMIT
	fi

	if [ "$CGROUP" ] ; then
		cgdelete $CGROUP 2> /dev/null
		cgcreate -g $CGROUP || return 1
	fi

	if [ "$THP" ] ; then
		# TODO: how can we make sure that there's no thp on the test system?
		set_thp_params_for_testing
		set_thp_madvise
		# show_stat_thp
	fi

	if [ "$BACKEND" == ksm ] || [ "$KSM" ] ; then
		ksm_on
		show_ksm_params | tee $TMPD/ksm_params1
	fi

	if [ "$MEMORY_HOTREMOVE" ] ; then
		reonline_memblocks
	fi

	if [ "$AUTO_NUMA" ] ; then
		enable_auto_numa
	else
		disable_auto_numa
	fi

	# TODO: better location?
	all_unpoison
	ipcrm --all > /dev/null 2>&1
}

cleanup_mm_generic() {
	# TODO: better location?
	all_unpoison
	ipcrm --all > /dev/null 2>&1
	echo 3 > /proc/sys/vm/drop_caches
	sync

	if [ "$HUGETLB" ] ; then
		set_and_check_hugetlb_pool 0
		rm -rf $HUGETLB_MOUNT/* > /dev/null 2>&1
		umount -f $HUGETLB_MOUNT > /dev/null 2>&1
		rm -rf $HUGETLB_MOUNT > /dev/null 2>&1
	fi

	if [ "$HUGETLB_OVERCOMMIT" ] ; then
		set_hugetlb_overcommit 0
	fi

	if [ "$CGROUP" ] ; then
		cgdelete $CGROUP 2> /dev/null
	fi

	if [ "$THP" ] ; then
		default_tuning_parameters
		# show_stat_thp
	fi

	if [ "$BACKEND" == ksm ] || [ "$KSM" ] ; then
		show_ksm_params | tee $TMPD/ksm_params2
		ksm_off
	fi

	if [ "$MEMORY_HOTREMOVE" ] ; then
		reonline_memblocks
	fi

	if [ "$AUTO_NUMA" ] ; then
		disable_auto_numa
	fi

	if [ -f $WDIR/testfile ] ; then
		rm -f $WDIR/testfile*
	fi

	echo 0 > /proc/sys/kernel/numa_balancing

	all_unpoison
	ipcrm --all > /dev/null 2>&1
}

get_smaps_block() {
	local pid=$1
	local file=$2
	local start=$3 # address (hexagonal but no '0x' prefix)

	cp /proc/$pid/smaps $TMPD/$file
	if [ "$start" ] ; then
		gawk '
			BEGIN {gate = 0;}
			/000-/ {
				if ($0 ~ /^'$start'/) {
					gate = 1;
				} else {
					gate = 0;
				}
			}
			{if (gate == 1) {print $0;}}
		' $TMPD/$file
	fi
}

get_pagetypes() {
	local pid=$1
	local file=$2
	shift 2
	$PAGETYPES -p $pid $@ | grep -v offset > $TMPD/$file
	local nr_lines=$(cat $TMPD/$file | wc -l)
	if [ "$nr_lines" -gt 12 ] ; then
		sed -ne 1,10p $TMPD/$file
		echo "... (more $[nr_lines - 10] lines in $TMPD/$file)"
	else
		cat $TMPD/$file
	fi
}

get_pagemap() {
	local pid=$1
	local file=$2
	shift 2
	$PAGETYPES -p $pid $@ | grep -v offset | cut -f1,2 > $TMPD/$file
	local nr_lines=$(cat $TMPD/$file | wc -l)
	if [ "$nr_lines" -gt 12 ] ; then
		sed -ne 1,10p $TMPD/$file
		echo "... (more $[nr_lines - 10] lines in $TMPD/$file)"
	else
		cat $TMPD/$file
	fi
}

get_mm_global_stats() {
	local tag=$1

	show_hugetlb_pool > $TMPD/hugetlb_pool.$tag
	cp /proc/vmstat $TMPD/vmstat.$tag
	if [ "$CGROUP" ] ; then
		cgget -g $CGROUP > $TMPD/cgroup.$tag
	fi
}

get_mm_stats_pid() {
	local tag=$1
	local pid=$2

	check_process_status $pid || continue
	get_numa_maps $pid > $TMPD/numa_maps.$tag
	get_smaps_block $pid smaps.$tag 700000 > /dev/null
	get_pagetypes $pid pagetypes.$tag -Nrla 0x700000000+0x10000000
	get_pagemap $pid .mig.$tag -NrLa 0x700000000+0x10000000 > /dev/null
	cp /proc/$pid/status $TMPD/proc_status.$tag
	cp /proc/$pid/sched $TMPD/proc_sched.$tag
	taskset -p $pid > $TMPD/taskset.$tag
}

get_mm_stats() {
	if [ "$#" -eq 1 ] ; then # only global stats
		local tag=$1
		get_mm_global_stats $tag
	elif [ "$#" -gt 1 ] ; then # process stats
		local tag=$1
		local pid=
		shift 1

		get_mm_global_stats $tag

		if [ "$#" -eq 1 ] ; then
			get_mm_stats_pid $tag $1
		else
			for pid in $@ ; do
				echo "PID: $pid"
				get_mm_stats_pid $tag.$pid $pid
			done
		fi
	fi
}

check_process_status() {
	local pid=$1

	kill -0 $pid 2> /dev/null
}
