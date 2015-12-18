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
			echo "huge,thp,mmap,anonymous=mmap"
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
		ksm)			#
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
