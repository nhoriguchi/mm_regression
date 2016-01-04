SHELL=/bin/bash
CC=gcc
CFLAGS=-g # -Wall -Wextra
TESTCASE_FILTER=

src=test_mincore.c test_thp_double_mapping.c test_idle_page_tracking.c mark_idle_all.c hog_hugepages.c iterate_numa_move_pages.c iterate_hugepage_mmap_fault_munmap.c hugepage_pingpong.c memeater.c test_alloc_generic.c
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
	@yum install -q -y numactl* > /dev/null 2>&1
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
	bash test_core/run-test-new.sh -v $(addprefix -f ,$(TESTCASE_FILTER)) $(addprefix -r ,$(shell readlink -f $(RECIPES) 2> /dev/null)) $(addprefix -t ,$(RUNNAME))

test42: all
	@echo $(shell readlink -f $(RECIPES) 2> /dev/null)
	@echo $(addprefix -r ,$(shell readlink -f $(RECIPES) 2> /dev/null))

page_migration: all
	@bash test_core/run-test-new.sh -v $(addprefix -f ,$(TESTCASE_FILTER)) $(addprefix -r ,$(RECIPES)) $(addprefix -t ,$(RUNNAME))

-include test_core/make.include
