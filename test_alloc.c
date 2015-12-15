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
#include "test_core/lib/pfn.h"

#define ADDR_INPUT 0x700000000000

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

/*
 * Memory block size is 128MB (1 << 27) = 32k pages (1 << 15)
 */
#define MEMBLK_ORDER	15
#define MAX_MEMBLK	1024

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
			    strcmp(optarg, "hotremove") &&
			    strcmp(optarg, "madv_soft"))
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
	} else if (!strcmp(migrate_src, "move_pages")) {
		void **addrs;
		int *status;
		int *nodes;
		int nr_p = nr * HPS / PS;

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
		
		addrs  = malloc(sizeof(char *) * nr_p + 1);
		status = malloc(sizeof(char *) * nr_p + 1);
		nodes  = malloc(sizeof(char *) * nr_p + 1);
		for (i = 0; i < nr_p; i++) {
			addrs[i] = p + i * PS;
			nodes[i] = 1;
			status[i] = 0;
		}
		printf("call move_pages()\n");
		ret = numa_move_pages(0, nr_p, addrs, nodes, status, MPOL_MF_MOVE_ALL);
		if (ret == -1) {
			perror("move_pages");
			pprintf("move_pages failed\n");
			pause();
			return 0;
		}
		signal(SIGUSR1, sig_handle_flag);
		pprintf("entering busy loop\n");
		while (flag)
			memset(p, 'a', nr * HPS);
		pprintf("exited busy loop\n");
		pause();
	} else if (!strcmp(migrate_src, "hotremove")) {
		unsigned long *pfns;
		int nr_hps_per_memblk[MAX_MEMBLK] = {};
		int max_nr_hps = 0;
		int preferred_memblk = 0;

		new_nodes = numa_bitmask_alloc(nr_nodes);
		numa_bitmask_setbit(new_nodes, 1);
		nodemask = 1; /* only node 0 allowed */
		if (set_mempolicy(MPOL_PREFERRED, &nodemask, nr_nodes) == -1)
			err("set_mempolicy");

		signal(SIGUSR1, sig_handle);
		p = checked_mmap((void *)ADDR_INPUT, nr * HPS, PROT_READ | PROT_WRITE,
				 mapflag, -1, 0);
		if (thp)
			if (madvise(p, nr * HPS, MADV_HUGEPAGE) == -1)
				err("madvise");
		memset(p, 0, nr * HPS);
		pfns = malloc(nr * sizeof(unsigned long));
		if (!pfns)
			err("malloc");
		memset(pfns, 0, nr * sizeof(unsigned long));
		for (i = 0; i < MAX_MEMBLK; i++)
			nr_hps_per_memblk[i] = 0;
		for (i = 0; i < nr; i++) {
			pfns[i] = get_my_pfn(&p[i * HPS]);
			nr_hps_per_memblk[pfns[i] >> MEMBLK_ORDER] += 1;
		}
		for (i = 0; i < MAX_MEMBLK; i++) {
			if (verbose > 1 && nr_hps_per_memblk[i] > 0)
				printf("memblock %d: hps %d\n", i, nr_hps_per_memblk[i]);
			if (nr_hps_per_memblk[i] > max_nr_hps) {
				max_nr_hps = nr_hps_per_memblk[i];
				preferred_memblk = i;
			}
		}

		/* unmap all hugepages except ones in preferred_memblk */
		for (i = 0; i < nr; i++)
			if (pfns[i] >> MEMBLK_ORDER != preferred_memblk)
				checked_munmap(&p[i * HPS], HPS);

		pprintf("before memory_hotremove: %d\n", preferred_memblk);
		pause();
		signal(SIGUSR1, sig_handle_flag);
		pprintf("entering busy loop\n");
		while (flag)
			for (i = 0; i < nr; i++)
				if (pfns[i] >> MEMBLK_ORDER == preferred_memblk)
					memset(&p[i * HPS], 'a', HPS);
		pprintf("exited busy loop\n");
		pause();
		for (i = 0; i < nr; i++)
			if (pfns[i] >> MEMBLK_ORDER == preferred_memblk)
				checked_munmap(&p[i * HPS], HPS);
		return 0;
	} else if (!strcmp(migrate_src, "madv_soft")) {
		int loop = 10;
		int do_unpoison = 1;

		new_nodes = numa_bitmask_alloc(nr_nodes);
		numa_bitmask_setbit(new_nodes, 1);

		nodemask = 1; /* only node 0 allowed */
		if (set_mempolicy(MPOL_BIND, &nodemask, nr_nodes) == -1)
			err("set_mempolicy");

		signal(SIGUSR2, sig_handle);
		pprintf("start background migration\n");
		pause();

		signal(SIGUSR1, sig_handle_flag);
		pprintf("hugepages prepared\n");

		while (flag) {
			p = checked_mmap((void *)ADDR_INPUT, nr * HPS, protflag, mapflag, -1, 0);
			/* fault in */
			memset(p, 'a', nr * HPS);
			for (i = 0; i < nr; i++) {
				ret = madvise(p + i * HPS, 4096, MADV_HWPOISON);
				if (ret) {
					perror("madvise");
					pprintf("madvise returned %d\n", ret);
				}
			}
			if (do_unpoison) {
				pprintf("need unpoison\n");
				pause();
			}
			checked_munmap(p, nr * HPS);
			if (loop-- <= 0)
				break;
		}
		pprintf("exit\n");
		pause();
	}

	return 0;
}
