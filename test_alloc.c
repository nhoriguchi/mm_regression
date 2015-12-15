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
#include "test_core/lib/hugepage.h"

#define ADDR_INPUT 0x700000000000

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

int main(int argc, char *argv[]) {
	int i;
	int ret;
	int nr = 2;
	char c;
	char *p;
	int mapflag = MAP_ANONYMOUS;
	int protflag = PROT_READ|PROT_WRITE;
        unsigned long nr_nodes = numa_max_node() + 1;
        struct bitmask *new_nodes;
        unsigned long nodemask;
	char *migrate_src = "migratetypes";
	int thp = 0;
	int partialmbind = 0;

	while ((c = getopt(argc, argv, "vp:m:n:h:Rs:P")) != -1) {
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
		case 'm':
			if (!strcmp(optarg, "private"))
				mapflag |= MAP_PRIVATE;
			else if (!strcmp(optarg, "shared"))
				mapflag |= MAP_SHARED;
			else
				errmsg("invalid optarg for -m\n");
			break;
		case 'n':
			nr = strtoul(optarg, NULL, 10);
			break;
		case 'h':
			HPS = strtoul(optarg, NULL, 10) * 1024;
			mapflag |= MAP_HUGETLB;
			/* todo: arch independent */
			if (HPS != 2097152 && HPS != 1073741824)
				errmsg("Invalid hugepage size\n");
			break;
		case 'R':
			mapflag |= MAP_NORESERVE;
			break;
		case 's':
			if (strcmp(optarg, "migratepages") &&
			    strcmp(optarg, "mbind") &&
			    strcmp(optarg, "move_pages") &&
			    strcmp(optarg, "hotremove"))
				errmsg("invalid optarg for -s\n");
			migrate_src = optarg;
			break;
		case 'P': /* partial mbind() */
			partialmbind = 1;
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

        if (nr_nodes < 2)
                errmsg("A minimum of 2 nodes is required for this test.\n");

	nodemask = 1; /* node 0 is preferred */
	if (set_mempolicy(MPOL_BIND, &nodemask, nr_nodes) == -1)
		err("set_mempolicy");

	signal(SIGUSR1, sig_handle);
	pprintf("just started\n");
	pause();

	if (!strcmp(migrate_src, "migratepages")) {
		p = mmap((void *)ADDR_INPUT, nr * HPS, protflag, mapflag, -1, 0);
		if (p == MAP_FAILED) {
			pprintf("mmap failed\n");
			err("mmap");
		}
		printf("mmap done %p\n", p);

		/* fault in */
		memset(p, 'a', nr * HPS);

		pprintf("page_fault_done\n");
		pause();

		signal(SIGUSR1, sig_handle_flag);
		pprintf("entering busy loop\n");
		while (flag) {
			memset(p, 'a', nr * HPS);
			usleep(100000);
		}
		pprintf("exited busy loop\n");
		pause();
	} else if (!strcmp(migrate_src, "mbind")) {
		new_nodes = numa_bitmask_alloc(nr_nodes);
		numa_bitmask_setbit(new_nodes, 1);

		p = mmap((void *)ADDR_INPUT, nr * HPS, protflag, mapflag, -1, 0);
		if (p == MAP_FAILED) {
			pprintf("mmap failed\n");
			err("mmap");
		}
		printf("mmap done %p\n", p);
		if (thp)
			madvise(p, nr * HPS, MADV_HUGEPAGE);
		/* fault in */
		memset(p, 'a', nr * HPS);

		pprintf("page_fault_done\n");
		pause();
		if (set_mempolicy(MPOL_DEFAULT, NULL, nr_nodes) == -1)
			err("set_mempolicy to MPOL_DEFAULT");
		printf("call mbind\n");
		if (partialmbind) {
			for (i = 0; i < nr; i++) {
				ret = mbind(p + i * HPS, 10 * PS, MPOL_BIND,
					    new_nodes->maskp, new_nodes->size + 1,
					    MPOL_MF_MOVE|MPOL_MF_STRICT);
				if (ret == -1) {
					pprintf("mbind failed\n");
					pause();
					err("mbind");
				}
			}
		} else {
			printf("%p, %lx, %lx, %lx, %lx %lx\n", p, nr * HPS, MPOL_BIND, new_nodes->maskp, new_nodes->size + 1, MPOL_MF_MOVE|MPOL_MF_STRICT);
			ret = mbind(p, nr * HPS, MPOL_BIND, new_nodes->maskp,
				    new_nodes->size + 1, MPOL_MF_MOVE|MPOL_MF_STRICT);
			if (ret == -1) {
				pprintf("mbind failed\n");
				pause();
				err("mbind");
			}
		}
		signal(SIGUSR1, sig_handle_flag);
		pprintf("entering busy loop\n");
		while (flag)
			memset(p, 'a', nr * HPS);
		pprintf("exited busy loop\n");
		pause();
	}

	return 0;
}
