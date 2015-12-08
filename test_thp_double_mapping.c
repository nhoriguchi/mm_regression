/*
 * Test program for memory error handling for hugepages
 * Author: Naoya Horiguchi <n-horiguchi@ah.jp.nec.com>
 */
#define _GNU_SOURCE 1
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <getopt.h>
#include <sys/mman.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/types.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <numa.h>
#include <numaif.h>

#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"

#define ADDR_INPUT 0x700000000000

int flag = 1;

void sig_handle(int signo) { flag = 0; }

int main(int argc, char *argv[])
{
	char *addr;
	int i;
	int ret;
	int fd = 0;
	int inject = 0;
	int privateflag = 0;
	char c;
	char filename[BUF_SIZE] = "/test";
	void *exp_addr = (void *)ADDR_INPUT;
	int nr_hps = 1;
	unsigned long nr_nodes = numa_max_node() + 1;
	struct bitmask *all_nodes;
	struct bitmask *old_nodes;
	struct bitmask *new_nodes;
	char *split_type;
	int do_pmd_splitting = 0;
	int do_fork = 1;

	signal(SIGUSR1, sig_handle);

	while ((c = getopt(argc, argv, "vp:n:s:SF")) != -1) {
		switch (c) {
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
			nr_hps = strtol(optarg, NULL, 10);
			break;
		case 's':
			split_type = optarg;
			break;
		case 'S':
			do_pmd_splitting = 1;
			break;
		case 'F':
			do_fork = 0;
			break;
		}
	}

	if (nr_nodes < 2)
		errmsg("A minimum of 2 nodes is required for this test.\n");
	all_nodes = numa_bitmask_alloc(nr_nodes);
	old_nodes = numa_bitmask_alloc(nr_nodes);
	new_nodes = numa_bitmask_alloc(nr_nodes);
	numa_bitmask_setbit(all_nodes, 0);
	numa_bitmask_setbit(all_nodes, 1);
	numa_bitmask_setbit(old_nodes, 0);
	numa_bitmask_setbit(new_nodes, 1);
	numa_sched_setaffinity(0, old_nodes);

	signal(SIGUSR1, sig_handle);

	addr = checked_mmap((void *)ADDR_INPUT, nr_hps * THPS, MMAP_PROT,
			    MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	memset(addr, 0, nr_hps * THPS);
	pprintf_wait(SIGUSR1, "thp allocated\n");

	if (do_fork && !fork()) {
		/* Generate read access from child process */
		for (i = 0; i < nr_hps * 512; i++)
			c = addr[i * PS];
		pause();
		for (i = 0; i < nr_hps; i++)
			checked_munmap(addr + PS + i * THPS, PS);
		pprintf_wait(SIGUSR1, "munmapped\n");
		pause();
		return 0;
	}
	pprintf_wait(SIGUSR1, "forked\n");

	/* trigger split_huge_pmd */
	if (do_pmd_splitting) {
		for (i = 0; i < nr_hps; i++)
			madvise(addr + i * THPS, PS, MADV_DONTNEED);
		pprintf_wait(SIGUSR1, "pmd_split\n");
	}

	/* trigger split_huge_page */
	if (!strcmp(split_type, "hwpoison")) {
		for (i = 0; i < nr_hps; i++)
			madvise(addr + PS + i * THPS, PS, MADV_HWPOISON);
	} else if (!strcmp(split_type, "soft_offline")) {
		for (i = 0; i < nr_hps; i++)
			madvise(addr + PS + i * THPS, PS, MADV_SOFT_OFFLINE);
	} else if (!strcmp(split_type, "mbind")) {
		numa_sched_setaffinity(0, all_nodes);
		for (i = 0; i < nr_hps; i++) {
			ret = mbind(addr + PS + i * THPS, PS, MPOL_BIND, new_nodes->maskp,
				    new_nodes->size + 1, MPOL_MF_MOVE|MPOL_MF_STRICT);
			if (ret == -1)
				err("mbind");
		}
	} else if (!strcmp(split_type, "migratepages")) {
		pprintf_wait(SIGUSR1, "waiting_migratepages\n");
	} else if (!strcmp(split_type, "move_pages")) {
		void **addrs = malloc(sizeof(char *) * nr_hps + 1);
		int *status = malloc(sizeof(char *) * nr_hps + 1);
		int *nodes = malloc(sizeof(char *) * nr_hps + 1);

		for (i = 0; i < nr_hps; i++) {
			addrs[i] = addr + PS + i * THPS;
			nodes[i] = 1;
			status[i] = 0;
		}
		ret = move_pages(0, nr_hps, addrs, nodes, status,
				      MPOL_MF_MOVE_ALL);
		if (ret == -1)
			err("move_pages");
	}
	pprintf_wait(SIGUSR1, "thp_split\n");

	pprintf_wait(SIGUSR1, "done\n");
	checked_munmap(addr, nr_hps * THPS);
	return 0;
}
