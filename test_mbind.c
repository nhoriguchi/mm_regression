#include <stdio.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <asm/unistd.h>
#include <numa.h>
#include <numaif.h>
#include <string.h>
#include <stdlib.h>
#include <getopt.h>
#include "test_core/lib/include.h"

#define ADDR_INPUT 0x700000000000

int flag = 1;

void sig_handle_flag(int signo) { flag = 0; }

int main(int argc, char *argv[]) {
	int i;
	int nr = 2;
	int ret;
	int fd = -1;
	char c;
	char *p;
	unsigned long memsize = 2*1024*1024;
	int mapflag = MAP_ANONYMOUS;
	unsigned long offset;
	unsigned long address = ADDR_INPUT;
	char *pmem;
	char *phugetlb;
	char *pthp;
	char *file = NULL;
	unsigned long nr_nodes = numa_max_node() + 1; /* numa_num_possible_nodes(); */
	struct bitmask *new_nodes;
	unsigned long nodemask;

	while ((c = getopt(argc, argv, "p:n:v")) != -1) {
		switch(c) {
		case 'p':
			testpipe = optarg;
			{
				struct stat stat;
				lstat(testpipe, &stat);
				if (!S_ISFIFO(stat.st_mode))
					errmsg("Given file is not fifo.\n");
			}
			break;
		case 'n':
			nr = strtoul(optarg, NULL, 10);
			memsize = nr * PS;
			break;
		case 'v':
			verbose = 1;
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	if (nr_nodes < 2)
		errmsg("A minimum of 2 nodes is required for this test.\n");

	new_nodes = numa_bitmask_alloc(nr_nodes);
	numa_bitmask_setbit(new_nodes, 1);

	nodemask = 1; /* only node 0 allowed */
	ret = set_mempolicy(MPOL_BIND, &nodemask, nr_nodes);
	if (ret == -1)
		err("set_mempolicy");

	mapflag = MAP_PRIVATE|MAP_ANONYMOUS;
	pmem = checked_mmap((void *)address, memsize, MMAP_PROT, mapflag, fd, 0);
	madvise(pmem, memsize, MADV_NOHUGEPAGE);
	memset(pmem, 'a', memsize);

	address += memsize;
	mapflag = MAP_PRIVATE|MAP_ANONYMOUS|MAP_HUGETLB;
	phugetlb = checked_mmap((void *)address, memsize, MMAP_PROT, mapflag, fd, 0);
	memset(phugetlb, 'a', memsize);

	address += memsize;
	mapflag = MAP_PRIVATE|MAP_ANONYMOUS;
	pthp = checked_mmap((void *)address, memsize, MMAP_PROT, mapflag, fd, 0);
	memset(pthp, 'a', memsize);

	pprintf_wait(SIGUSR1, "before mbind\n");
	ret = mbind(pmem, memsize, MPOL_BIND, new_nodes->maskp,
		    new_nodes->size + 1, MPOL_MF_MOVE|MPOL_MF_STRICT);
	if (ret == -1)
		err("mbind");
	ret = mbind(phugetlb, memsize, MPOL_BIND, new_nodes->maskp,
		    new_nodes->size + 1, MPOL_MF_MOVE|MPOL_MF_STRICT);
	if (ret == -1)
		err("mbind");
	ret = mbind(pthp, memsize, MPOL_BIND, new_nodes->maskp,
		    new_nodes->size + 1, MPOL_MF_MOVE|MPOL_MF_STRICT);
	if (ret == -1)
		err("mbind");

	signal(SIGUSR1, sig_handle_flag);

	pprintf("entering busy loop\n");
	while (flag) {
		usleep(1000);
		memset(pmem, 'a', memsize);
		memset(phugetlb, 'a', memsize);
		memset(pthp, 'a', memsize);
	}

	pprintf_wait(SIGUSR1, "mbind exit\n");
	munmap(pmem, memsize);
	munmap(phugetlb, memsize);
	munmap(pthp, memsize);
	return 0;
}
