#define _GNU_SOURCE
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
#include <sched.h>
#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"

#define ADDR_INPUT 0x700000000000

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

int main(int argc, char *argv[]) {
	int i;
	int nr = 2;
	char c;
	char *p;
	int mapflag = MAP_ANONYMOUS | MAP_PRIVATE;
	int protflag = PROT_READ|PROT_WRITE;
        unsigned long nr_nodes = numa_max_node() + 1;
        unsigned long nodemask;
        struct bitmask *new_nodes;
	int busyloop = 0;

	while ((c = getopt(argc, argv, "vp:n:b")) != -1) {
		switch(c) {
                case 'v':
                        verbose = 1;
                        break;
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
			break;
		case 'b':
			busyloop = 1;
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

	signal(SIGUSR1, sig_handle);

        nodemask = 1; /* only node 0 allowed */
        if (set_mempolicy(MPOL_BIND, &nodemask, nr_nodes) == -1)
                err("set_mempolicy");

	p = checked_mmap((void *)ADDR_INPUT, nr * HPS, protflag, mapflag, -1, 0);
	printf("mmap done %p\n", p);

	if (madvise(p, nr * HPS, MADV_HUGEPAGE) == -1)
		err("madvise");
	
	/* fault in */
	memset(p, 'a', nr * HPS);
	signal(SIGUSR1, sig_handle_flag);
	pprintf("entering_busy_loop\n");
	if (busyloop)
		while (flag)
			memset(p, 'a', nr * HPS);
	else
		pause();
	pprintf("exited_busy_loop\n");
	pause();
	return 0;
}
