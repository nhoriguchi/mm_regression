CC=gcc
OPT=-DDEBUG
LIBOPT=-lnuma -lpthread # -lcgroup
CFLAGS=-g # -Wall -Wextra

src=test_mincore.c mark_idle_all.c iterate_numa_move_pages.c test_alloc_generic.c test_hugetlb_pmd_share.c numa_move_pages.c
exe=$(src:.c=)

build: $(exe)

%: %.c
	C_INCLUDE_PATH=.. $(CC) $(CFLAGS) -o $@ $^ $(OPT) $(LIBOPT)
