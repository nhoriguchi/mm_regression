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

void sig_handle(int signo) { ; }

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
	char *pmem1, *pmem2, *pmem3;
	char *phugetlb;
	char *pthp;
	char *file = NULL;
	unsigned long nr_nodes = numa_max_node() + 1; /* numa_num_possible_nodes(); */
	struct bitmask *new_nodes;
	unsigned long nodemask;
	int dev_mem_fd;

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

	mapflag = MAP_PRIVATE|MAP_ANONYMOUS;
	dev_mem_fd = checked_open("/dev/mem", O_RDWR);
	pmem1 = checked_mmap((void *)address, memsize, MMAP_PROT, mapflag, fd, 0);
	pmem2 = checked_mmap((void *)address + memsize, memsize, PROT_READ, MAP_SHARED, dev_mem_fd, 0xf0000);
	pmem3 = checked_mmap((void *)address + 2*memsize, memsize, MMAP_PROT, mapflag, fd, 0);
	memset(pmem1, 'a', memsize);
	memset(pmem3, 'a', memsize);
	signal(SIGUSR1, sig_handle);
	pprintf_wait(SIGUSR1, "waiting\n");
	pprintf_wait(SIGUSR1, "vma_vm_pfnmap exit\n");
	checked_munmap(pmem1, memsize);
	checked_munmap(pmem2, memsize);
	checked_munmap(pmem3, memsize);
	return 0;
}
