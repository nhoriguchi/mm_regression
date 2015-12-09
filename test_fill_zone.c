#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <getopt.h>
#include <numa.h>
#include <numaif.h>
#include "test_core/lib/include.h"

#define ADDR_INPUT 0x700000000000

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

#define BUFNR 0x10000 /* 65536 */

int main(int argc, char *argv[]) {
	int i;
	char c;
	int nr[BUFNR];
	char *p[BUFNR];
	int mapflag = MAP_ANONYMOUS|MAP_PRIVATE;
	int protflag = PROT_READ|PROT_WRITE;
        unsigned long nr_nodes = numa_max_node() + 1;
        struct bitmask *new_nodes;
        unsigned long nodemask;

	int max = strtoul(argv[1], NULL, 10);

        new_nodes = numa_bitmask_alloc(nr_nodes);
        numa_bitmask_setbit(new_nodes, 1);

	signal(SIGUSR1, sig_handle);
        nodemask = 1; /* only node 1 allowed */
        if (set_mempolicy(MPOL_BIND, &nodemask, nr_nodes) == -1)
                err("set_mempolicy");

	for (i = 0; i < max; i++) {
		p[i] = checked_mmap(NULL, 512 * PS, protflag, mapflag, -1, 0);
		printf("i:%d, p[i]:%p\n", i, p[i]);
		memset(p[i], 'a', 512 * PS);
	}
	return 0;

	for (i = 0; i < 9; i++)
		nr[i] = strtoul(argv[i + 1], NULL, 10);

	for (i = 0; i < 9; i++) {
		p[i] = checked_mmap(NULL, nr[i] * PS, protflag, mapflag, -1, 0);
		madvise(p[i], nr[i] * PS, MADV_UNMERGEABLE);
		madvise(p[i], nr[i] * PS, MADV_NOHUGEPAGE);
		madvise(p[i], nr[i] * PS, MADV_SEQUENTIAL);
		memset(p[i], 'a' + i, nr[i] * PS);
	}

	pause();
	/* /\* fault in *\/ */
	/* signal(SIGUSR1, sig_handle_flag); */
	/* pprintf("entering busy loop\n"); */
	/* while (flag) { */
	/* 	memset(p, 'a', nr * HPS); */
	/* 	usleep(100000); */
	/* } */
	/* pprintf("exited busy loop\n"); */
	/* pause(); */
	/* return 0; */
}
