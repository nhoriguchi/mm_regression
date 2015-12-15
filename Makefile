SHELL=/bin/bash
CC=gcc
CFLAGS=-g # -Wall -Wextra
TESTCASE_FILTER=

src=test_mbind.c test_mbind_fuzz.c test_mbind_unmap_race.c test_malloc_madv_willneed.c test_mincore.c test_mbind_bug_reproducer.c test_vma_vm_pfnmap.c test_swap_shmem.c test_thp_double_mapping.c test_idle_page_tracking.c mark_idle_all.c test_memory_compaction.c test_alloc.c test_mbind_hm.c test_move_pages.c test_memory_hotremove.c hog_hugepages.c iterate_numa_move_pages.c iterate_hugepage_mmap_fault_munmap.c test_hugetlb_hotremove.c test_alloc_thp.c test_mlock_on_shared_thp.c test_mprotect_on_shared_thp.c madvise_hwpoison_hugepages.c hugepage_pingpong.c test_thp_migration_race_with_gup.c test_process_vm_access.c iterate_mmap_fault_munmap.c test_thp.c test_ksm.c test_hugetlb.c memeater.c memeater_multithread.c test_base_madv_simple_stress.c test_thp_on_pcplist.c test_thp_small.c test_soft_offline_unpoison_stress.c memeater_hugetlb.c test_zero_page.c memeater_thp.c memeater_random.c test_fill_zone.c test_thp_justalloc.c test_alloc_generic.c
exe=$(src:.c=)
srcdir=.
dstdir=/usr/local/bin
dstexe=$(addprefix $(dstdir)/,$(exe))

OPT=-DDEBUG
LIBOPT=-lnuma -lpthread # -lcgroup

all: get_test_core get_rpms $(exe)
%: %.c
	$(CC) $(CFLAGS) -o $@ $^ $(OPT) $(LIBOPT)

get_test_core:
	@test ! -d "test_core" && test -f install.sh && bash install.sh || true
	@test -d "test_core" || git clone https://github.com/Naoya-Horiguchi/test_core
	@true

get_rpms:
	yum install -y numactl*
	@true

install: $(exe)
	for file in $? ; do \
	  mv $$file $(dstdir) ; \
	done

clean:
	@for file in $(exe) ; do \
	  rm $(dstdir)/$$file 2> /dev/null ; \
	  rm $(srcdir)/$$file 2> /dev/null ; \
	  true ; \
	done

TARGETS=page_table_walker mmgeneric hugepage_migration thp_migration mce_base mce_hugetlb mce_thp mce_ksm mce_stress mce_multiple_injection

$(TARGETS): all
	@bash run-test.sh -v -r $@.rc -n $@ $(TESTCASE_FILTER)

test1g: all
	@bash run-test-1g.sh

mce_kvm: all
	bash run-test.sh -v -r $@.rc -n $@ -S $(TESTCASE_FILTER)

tmp_mce_kvm: all
	bash run-test.sh -v -r $@.rc -n $@ -S $(TESTCASE_FILTER)

# alias definition
test: mmgeneric page_table_walker hugepage_migration thp_migration mce_test
mce_test: mce_base mce_hugetlb mce_thp mce_ksm
mce_test_advanced: mce_multiple_injection mce_stress
mce_test_full: mce_test mce_test_advanced

test2: all
	@bash test_core/run-test-new.sh -v -t $@ $(addprefix '-f ',$(TESTCASE_FILTER)) $(addprefix '-r ',$(RECIPES)) -d cases/page_migration/hugetlb

test3: all
	@bash test_core/run-test-new.sh -v -t $@ $(addprefix '-f ',$(TESTCASE_FILTER)) cases/page_migration/hugetlb/mbind_private_reserved

test4: all
	@bash test_core/run-test-new.sh -v -t $@ $(addprefix '-f ',$(TESTCASE_FILTER)) $(addprefix '-r ',$(RECIPES))
