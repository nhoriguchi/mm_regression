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

/* TODO: validation options' combination more */
static void setup(void) {
	if (filebase && backend_bitmap & BE_PAGECACHE)
		create_regular_file();

	if (backend_bitmap & BE_HUGETLB_FILE)
		create_hugetlbfs_file();

	if (backend_bitmap & BE_DEVMEM) {
		if (backend_bitmap & ~BE_DEVMEM) {
			errmsg("-B devmem shouldn't be used with other backend type\n");
		}

		nr_p = 1; /* -n option shouldn't work */
	}

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

	while ((c = getopt(argc, argv, "vp:n:N:B:L:f:Fw:s")) != -1) {
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
		case 'L':
			parse_operations(optarg);
			break;
		case 'f':
			filebase = optarg;
			break;
		case 'F':
			filebase = NULL;
			break;
		case 'w':
			workdir = optarg;
			break;
		case 's':
			/* use rich signal handler */
			sigaction(SIGBUS, &sa, NULL);
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
