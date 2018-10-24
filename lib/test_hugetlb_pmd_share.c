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
#include <getopt.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/wait.h>
#include "./include.h"

int main(int argc, char *argv[]) {
	size_t size = 2 * HPS;
	char *phugetlb;
	int preferred_mem_node = 0;

	/* hugetlbfd returned */
	create_hugetlbfs_file();

	if (set_mempolicy_node(MPOL_BIND, preferred_mem_node) == -1)
		err("set_mempolicy");

	phugetlb = checked_mmap((void *)ADDR_INPUT, size, protflag,
				MAP_SHARED, hugetlbfd, 0);
	memset(phugetlb, 'a', size);

	if (set_mempolicy_node(MPOL_DEFAULT, 0) == -1)
		err("set_mempolicy");

	if (argc > 1) {
		nr_nodes = numa_max_node() + 1;
		signal(SIGUSR1, sig_handle);
		pause();

		if (!strcmp(argv[1], "mbind")) {
			struct bitmask *new_nodes = numa_bitmask_alloc(nr_nodes);
			numa_bitmask_setbit(new_nodes, 1);

			mbind(phugetlb, size, MPOL_BIND, new_nodes->maskp,
			      new_nodes->size + 1, MPOL_MF_MOVE_ALL|MPOL_MF_STRICT);
			new_nodes = numa_bitmask_alloc(nr_nodes);
			numa_bitmask_setbit(new_nodes, 0);
			mbind(phugetlb, size, MPOL_BIND, new_nodes->maskp,
			      new_nodes->size + 1, MPOL_MF_MOVE_ALL|MPOL_MF_STRICT);
		} else if (!strcmp(argv[1], "move_pages")) {
			void *addrs[2];
			int status[2];
			int nodes[2];

			addrs[0] = phugetlb;
			nodes[0] = 1;
			status[0] = 0;
			numa_move_pages(0, 1, addrs, nodes, status, MPOL_MF_MOVE_ALL);
			nodes[0] = 0;
			status[0] = 0;
			numa_move_pages(0, 1, addrs, nodes, status, MPOL_MF_MOVE_ALL);
		} else if (!strcmp(argv[1], "madv_soft")) {
			madvise(phugetlb, PS, MADV_SOFT_OFFLINE);
		}
	}
	pause();
}
