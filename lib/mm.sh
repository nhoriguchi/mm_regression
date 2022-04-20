. $TRDIR/lib/numa.sh
. $TRDIR/lib/mce.sh
. $TRDIR/lib/hugetlb.sh
. $TRDIR/lib/thp.sh
. $TRDIR/lib/ksm.sh

if [ ! -s "$GTMPD/environment/kpf_flags" ] ; then
	cat <<EOF > $GTMPD/environment/kpf_flags
locked			0
error			1
referenced		2
uptodate		3
dirty			4
lru				5
active			6
slab			7
writeback		8
reclaim			9
buddy			10
mmap			11
anonymous		12
swapcache		13
swapbacked		14
compound_head	15
compound_tail	16
huge			17
unevictable		18
hwpoison		19
nopage			20
ksm				21
thp				22
offline			23
pgtable			24
zero_page		25
idle_page		26
reserved		32
mlocked			33
mappedtodisk	34
private			35
private_2		36
owner_private	37
arch			38
uncached		39
softdirty		40
arch_2			41
readahead		48
slob_free		49
slub_frozen		50
slub_debug		51
file			61
swap			62
mmap_exclusive	63
EOF
fi

get_backend_pageflags_mask_value() {
	local flags="$(get_backend_pageflags $1)"
	[ ! "$flags" ] && return 1

	local mask=$(echo $flags | cut -f1 -d=)
	local value=$(echo $flags | cut -f2 -d=)

	[ ! "$value" ] && value=$mask

	local mask2=0
	local value2=0

	for flg in $(echo $mask | tr ',' ' ') ; do
		local flbit="$(grep -P "^$flg\t" $GTMPD/environment/kpf_flags | awk '{print $2}')"
		mask2=$[mask2 + (1<<$flbit)]
	done

	for flg in $(echo $value | tr ',' ' ') ; do
		local flbit="$(grep -P "^$flg\t" $GTMPD/environment/kpf_flags | awk '{print $2}')"
		value2=$[value2 + (1<<$flbit)]
	done

	printf "0x%lx,0x%lx\n" $mask2 $value2
}

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
		thp_shmem)		# ___________M____T_____t___________f______1
			echo "thp,mmap,anonymous,compound_head=thp,mmap,compound_head"
			;;
		thp_shmem_split)
			# ___UDl_____M__b___________________f____F_1
			# TODO: maybe better flag combination
			echo "thp,mmap,swapbacked=mmap,swapbacked"
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
		rm -rf $TMPHUGETLBDIR/* > /dev/null 2>&1
		umount -f $TMPHUGETLBDIR > /dev/null 2>&1
		rm -rf $TMPHUGETLBDIR > /dev/null 2>&1
		mkdir -p $TMPHUGETLBDIR > /dev/null 2>&1
		mount -t hugetlbfs none $TMPHUGETLBDIR || return 1
	fi

	if [ "$HUGETLB_OVERCOMMIT" ] ; then
		set_hugetlb_overcommit $HUGETLB_OVERCOMMIT
		set_return_code SET_OVERCOMMIT
	fi

	if [ "$THP" ] ; then
		# TODO: how can we make sure that there's no thp on the test system?
		set_thp_params_for_testing
		if [ "$THP" == always ] ; then
			echo "enable THP (always)"
			set_thp_always
		else
			echo "enable THP (madvise)"
			set_thp_madvise
		fi
		# show_stat_thp
	else
		# TODO: split existing thp forcibly via debugfs?
		set_thp_never
	fi

	if [ "$SHMEM" ] ; then
		rm -rf $TDIR/shmem/* > /dev/null 2>&1
		umount -f $TDIR/shmem > /dev/null 2>&1
		rm -rf $TDIR/shmem > /dev/null 2>&1
		mkdir -p $TDIR/shmem > /dev/null 2>&1
		mount -t tmpfs -o huge=always tmpfs $TDIR/shmem || return 1
	fi

	# These service changes /sys/kernel/mm/ksm/run, which is not fine for us.
	stop_ksm_service
	if [ "$BACKEND" == ksm ] || [ "$KSM" ] ; then
		ksm_on
		show_ksm_params | tee $TMPD/ksm_params1
	else
		ksm_off
	fi

	reonline_memblocks

	if [ "$AUTO_NUMA" ] ; then
		enable_auto_numa
	else
		disable_auto_numa
	fi

	# TODO: better location?
	all_unpoison
	ipcrm --all > /dev/null 2>&1
	echo 3 > /proc/sys/vm/drop_caches
}

cleanup_mm_generic() {
	# TODO: better location?
	all_unpoison
	ipcrm --all > /dev/null 2>&1
	echo 3 > /proc/sys/vm/drop_caches
	sync

	if [ "$HUGETLB" ] ; then
		set_and_check_hugetlb_pool 0
		rm -rf $TMPHUGETLBDIR/* > /dev/null 2>&1
		umount -f $TMPHUGETLBDIR > /dev/null 2>&1
		rm -rf $TMPHUGETLBDIR > /dev/null 2>&1
	fi

	if [ "$HUGETLB_OVERCOMMIT" ] ; then
		set_hugetlb_overcommit 0
	fi

	if [ "$THP" ] ; then
		default_tuning_parameters
		# show_stat_thp
	fi

	if [ "$BACKEND" == ksm ] || [ "$KSM" ] ; then
		show_ksm_params | tee $TMPD/ksm_params2
		ksm_off
	fi

	reonline_memblocks

	if [ "$AUTO_NUMA" ] ; then
		disable_auto_numa
	fi

	if [ "$SHMEM" ] ; then
		rm -rf $TDIR/shmem/* > /dev/null 2>&1
		umount -f $TDIR/shmem > /dev/null 2>&1
		rm -rf $TDIR/shmem > /dev/null 2>&1
	fi

	find $TDIR -type f -name testfile* | xargs rm -f 2> /dev/null

	echo 0 > /proc/sys/kernel/numa_balancing

	all_unpoison
	ipcrm --all > /dev/null 2>&1
}

get_smaps_block() {
	local pid=$1
	local file=$2
	local start=$3 # address (hexagonal but no '0x' prefix)

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
		' /proc/$pid/smaps > $TMPD/$file
	else
		cp /proc/$pid/smaps > $TMPD/$file
	fi
}

get_pagetypes() {
	local pid=$1
	local file=$2
	shift 2
	page-types -p $pid $@ | grep -v offset > $TMPD/.$file
	cp $TMPD/.$file $TMPD/2.$file

	# separate mapping list part and statistics part.
	gawk '
		BEGIN {gate = 1;}
		/^$/ {gate = 0;}
		{if (gate == 1) {print $0;}}
	' $TMPD/.$file > $TMPD/$file
	gawk '
		BEGIN {gate = 0;}
		/^$/ {gate = 1;}
		{if (gate == 1) {print $0;}}
	' $TMPD/.$file | sed '/^$/d' > $TMPD/$file.stat

	local nr_lines=$(cat $TMPD/$file | wc -l)
	if [ "$nr_lines" -gt 12 ] ; then
		sed -ne 1,10p $TMPD/$file
		echo "... (more $[nr_lines - 10] lines in $TMPD/$file)"
		cat $TMPD/$file.stat
	else
		cat $TMPD/$file
	fi
}

get_pagemap() {
	local pid=$1
	local file=$2
	shift 2
	page-types -p $pid $@ | grep -v offset | cut -f1,2 > $TMPD/$file
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
	cp /proc/meminfo $TMPD/meminfo.$tag
	cp /proc/vmstat $TMPD/vmstat.$tag
	cp /proc/buddyinfo $TMPD/buddyinfo.$tag
	# if [ "$CGROUP" ] ; then
	# 	cgget -g $CGROUP > $TMPD/cgroup.$tag
	# fi
}

get_mm_stats_pid() {
	local tag=$1
	local pid=$2

	check_process_status $pid || return
	get_numa_maps $pid > $TMPD/numa_maps.$tag
	get_smaps_block $pid smaps.$tag 70 > /dev/null
	get_pagetypes $pid pagetypes.$tag -rla 0x700000000+0x10000000
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

clear_soft_dirty() {
	local pid=$1

	echo "==> echo 4 > /proc/$pid/clear_refs"
	echo 4 > /proc/$pid/clear_refs
}
