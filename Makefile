SHELL=/bin/bash
CC=gcc
CFLAGS=-g # -Wall -Wextra
TESTCASE_FILTER=

src=test_mincore.c mark_idle_all.c iterate_numa_move_pages.c memeater.c test_alloc_generic.c
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

# recipes are given via environment variable RECIPEFILES= or RECIPEDIR=
test: all update_recipes
	@bash test_core/run-test-new.sh -v $(addprefix -f ,$(TESTCASE_FILTER)) $(addprefix -r ,$(shell readlink -f $(RECIPES) 2> /dev/null)) $(addprefix -t ,$(RUNNAME)) $(addprefix -d ,$(RECIPEDIR))

# all recipes
test_all: all update_recipes
	@bash test_core/run-test-new.sh -v $(addprefix -f ,$(TESTCASE_FILTER)) $(addprefix -r ,$(shell find cases/ -type f | xargs readlink -f 2> /dev/null)) $(addprefix -t ,$(RUNNAME))

test1g: all
	@bash run-test-1g.sh

# alias definition
test_old: mmgeneric page_table_walker hugepage_migration thp_migration mce_test
mce_test: mce_base mce_hugetlb mce_thp mce_ksm
mce_test_advanced: mce_multiple_injection mce_stress
mce_test_full: mce_test mce_test_advanced

makefile_test: all
	@echo $(shell readlink -f $(RECIPES) 2> /dev/null)
	@echo $(addprefix -r ,$(shell readlink -f $(RECIPES) 2> /dev/null))

-include test_core/make.include
