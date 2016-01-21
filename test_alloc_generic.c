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
#include "include.h"

/* TODO: validation options' combination more */
static void setup(void) {
	if (backend_bitmap & BE_PAGECACHE) {
		if (!workdir)
			err("you must set workdir with -d option to allocate pagecache");
		create_regular_file();
	}

	if (backend_bitmap & BE_HUGETLB_FILE) {
		if (!workdir)
			err("you must set workdir with -d option to allocate hugetlbfs file");
		create_hugetlbfs_file();
	}

	if (backend_bitmap & BE_DEVMEM) {
		if (backend_bitmap & ~BE_DEVMEM) {
			errmsg("-B devmem shouldn't be used with other backend type\n");
		}

		nr_p = 1; /* -n option shouldn't work */
	}

	if (access_after_injection && injection_type == -1)
		err("-A is set, but -e is not set, which is meaningless.");

	nr_chunk = (nr_p - 1) / CHUNKSIZE + 1;
	nr_mem_types = get_nr_mem_types();
	nr_all_chunks = nr_chunk * nr_mem_types;

	chunkset = (struct mem_chunk *)malloc(sizeof(struct mem_chunk) *
					      nr_all_chunks);
	memset(chunkset, 0, sizeof(struct mem_chunk) * nr_all_chunks);
}

int main(int argc, char *argv[]) {
	char c;

	nr_nodes = numa_max_node() + 1;
	nodemask = (1UL << nr_nodes) - 1; /* all nodes in default */

	signal(SIGUSR1, sig_handle);

	while ((c = getopt(argc, argv, "vp:n:N:bm:e:B:Ad:M:RFO:C:L:")) != -1) {
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
			nr_p = strtoul(optarg, NULL, 0);
			break;
		case 'N':
			nr_p = strtoul(optarg, NULL, 0) * 512;
			break;
		case 'b':
			busyloop = 1;
			break;
		case 'm':
			/* TODO: fix dirty hack */
			if (!strcmp(optarg, "private")) {
				mapflag |= MAP_PRIVATE;
				mapflag &= ~MAP_SHARED;
			} else if (!strcmp(optarg, "shared")) {
				mapflag &= ~MAP_PRIVATE;
				mapflag |= MAP_SHARED;
			} else {
				nodemask = strtoul(optarg, NULL, 0);
				printf("%lx\n", nodemask);
				if (set_mempolicy(MPOL_BIND, &nodemask, nr_nodes) == -1)
					err("set_mempolicy");
			}
			break;
		case 'e':
			if (!strcmp(optarg, "mce-srao"))
				injection_type = MCE_SRAO;
			else if (!strcmp(optarg, "hard-offline"))
				injection_type = SYSFS_HARD;
			else if (!strcmp(optarg, "soft-offline"))
				injection_type = SYSFS_SOFT;
			else if (!strcmp(optarg, "madv_hard"))
				injection_type = MADV_HARD;
			else if (!strcmp(optarg, "madv_soft"))
				injection_type = MADV_SOFT;
			else
				errmsg("invalid -e option %s\n", optarg);
			break;
		case 'B':
			if (!strcmp(optarg, "pagecache")) {
				backend_bitmap |= BE_PAGECACHE;
			} else if (!strcmp(optarg, "anonymous")) {
				backend_bitmap |= BE_ANONYMOUS;
			} else if (!strcmp(optarg, "thp")) {
				backend_bitmap |= BE_THP;
			} else if (!strcmp(optarg, "hugetlb_anon")) {
				backend_bitmap |= BE_HUGETLB_ANON;
			} else if (!strcmp(optarg, "hugetlb_shmem")) {
				backend_bitmap |= BE_HUGETLB_SHMEM;
			} else if (!strcmp(optarg, "hugetlb_file")) {
				backend_bitmap |= BE_HUGETLB_FILE;
			} else if (!strcmp(optarg, "ksm")) {
				backend_bitmap |= BE_KSM;
			} else if (!strcmp(optarg, "zero")) {
				backend_bitmap |= BE_ZERO;
			} else if (!strcmp(optarg, "huge_zero")) {
				backend_bitmap |= BE_HUGE_ZERO;
			} else if (!strcmp(optarg, "normal_shmem")) {
				backend_bitmap |= BE_NORMAL_SHMEM;
			} else if (!strcmp(optarg, "devmem")) {
				backend_bitmap |= BE_DEVMEM;
			} else {
				int i;
				backend_bitmap |= strtoul(optarg, NULL, 0);
				printf("backend_bitmap %lx, %d\n",
				       backend_bitmap, get_nr_mem_types());
			}
			break;
		case 'A':
			access_after_injection = 1;
			break;
		case 'd': /* tmpdir/workdir */
			workdir = optarg;
			break;
		case 'M':
			/* this filter is used for choosing memblk to be hotremoved */
			parse_bits_mask(optarg);
			break;
		case 'R':
			mapflag |= MAP_NORESERVE;
			break;
		case 'F':
			forkflag = 1;
			break;
		case 'O':
			preferred_mem_node = strtoul(optarg, NULL, 0);
			break;
		case 'C':
			preferred_cpu_node = strtoul(optarg, NULL, 0);
			break;
		case 'L':
			parse_operations(optarg);
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	setup();

	if (op_strings) {
		do_operation_loop();
	} else {
		errmsg("-L option given\n");
	}
}
