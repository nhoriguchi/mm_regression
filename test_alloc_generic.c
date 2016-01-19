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

static int need_numa() {
	if ((operation_type == OT_PAGE_MIGRATION) ||
	    (operation_type == OT_PAGE_MIGRATION)) {
		if (nr_nodes < 2)
			errmsg("A minimum of 2 nodes is required for this test.\n");
	}
}

/* TODO: validation options' combination more */
static void setup(void) {
	nr_nodes = numa_max_node() + 1;
	nodemask = (1UL << nr_nodes) - 1; /* all nodes in default */

	need_numa();

	signal(SIGUSR1, sig_handle_flag);

	if (backend_bitmap & BE_PAGECACHE) {
		if (!workdir)
			err("you must set workdir with -d option to allocate pagecache");
		printf("create regular file\n");
		create_regular_file();
	}

	if (backend_bitmap & BE_HUGETLB_FILE) {
		if (!workdir)
			err("you must set workdir with -d option to allocate hugetlbfs file");
		printf("create hugetlbfs file\n");
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

	if (!(backend_bitmap & BE_HUGEPAGE) && hp_partial) {
		err("hp_partial (-P) option is useful only for hugepages");
	}

	nr_chunk = (nr_p - 1) / CHUNKSIZE + 1;

	nr_mem_types = get_nr_mem_types();
	nr_all_chunks = nr_chunk * nr_mem_types;

	chunkset = (struct mem_chunk *)malloc(sizeof(struct mem_chunk) *
					      nr_all_chunks);
	memset(chunkset, 0, sizeof(struct mem_chunk) * nr_all_chunks);
}

static void do_operation(void) {
	switch (operation_type) {
	case OT_MEMORY_ERROR_INJECTION:
		__do_memory_error_injection();
		break;
	case OT_PAGE_MIGRATION:
		__do_page_migration();
		break;
	case OT_PROCESS_VM_ACCESS:
		__do_process_vm_access();
		break;
	case OT_MLOCK:
		__do_mlock();
		break;
	case OT_MLOCK2:
		__do_mlock2();
		break;
	case OT_MPROTECT:
		__do_mprotect();
		break;
	case OT_MADV_STRESS:
		_do_madv_stress();
		break;
	case OT_FORK_STRESS:
		__do_fork_stress();
		break;
	case OT_MREMAP_STRESS:
		__do_mremap_stress();
		break;
	case OT_MBIND_FUZZ:
		__do_mbind_fuzz();
		break;
	case OT_MEMORY_COMPACTION:
		do_memory_compaction();
		break;
	case OT_MADV_WILLNEED:
		__do_madv_willneed();
		break;
	case OT_ALLOCATE_MORE:
		__do_allocate_more();
		break;
	case OT_MOVE_PAGES_PINGPONG:
		__do_move_pages_pingpong();
		break;
	case OT_MBIND_PINGPONG:
		__do_mbind_pingpong();
		break;
	case OT_PAGE_MIGRATION_PINGPONG:
		/* __do_page_migration_pingpong(); */
		break;
	case OT_NOOP:
		break;
	case OT_BUSYLOOP:
		__busyloop();
		break;
	case OT_HUGETLB_RESERVE:
		do_hugetlb_reserve();
		break;
	}
}

int main(int argc, char *argv[]) {
	char c;

	while ((c = getopt(argc, argv, "vp:n:N:bm:o:e:PB:Ad:M:s:RFw:O:C:L:")) != -1) {
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
		case 'o':
			if (!strcmp(optarg, "memory_error_injection"))
				operation_type = OT_MEMORY_ERROR_INJECTION;
			else if (!strcmp(optarg, "alloc_exit"))
				operation_type = OT_ALLOC_EXIT;
			else if (!strcmp(optarg, "multi_backend"))
				err("-o multi_backend is obsolete, use -B 0xffff");
			else if (!strcmp(optarg, "page_migration"))
				operation_type = OT_PAGE_MIGRATION;
			else if (!strcmp(optarg, "process_vm_access"))
				operation_type = OT_PROCESS_VM_ACCESS;
			else if (!strcmp(optarg, "mlock"))
				operation_type = OT_MLOCK;
			else if (!strcmp(optarg, "mlock2"))
				operation_type = OT_MLOCK2;
			else if (!strcmp(optarg, "mprotect"))
				operation_type = OT_MPROTECT;
			else if (!strcmp(optarg, "madv_stress"))
				operation_type = OT_MADV_STRESS;
			else if (!strcmp(optarg, "fork_stress"))
				operation_type = OT_FORK_STRESS;
			else if (!strcmp(optarg, "mremap_stress"))
				operation_type = OT_MREMAP_STRESS;
			else if (!strcmp(optarg, "mbind_fuzz"))
				operation_type = OT_MBIND_FUZZ;
			else if (!strcmp(optarg, "madv_willneed")) {
				operation_type = OT_MADV_WILLNEED;
			} else if (!strcmp(optarg, "allocate_more")) {
				operation_type = OT_ALLOCATE_MORE;
			} else if (!strcmp(optarg, "memory_compaction")) {
				operation_type = OT_MEMORY_COMPACTION;
			} else if (!strcmp(optarg, "move_pages_pingpong")) {
				operation_type = OT_MOVE_PAGES_PINGPONG;
			} else if (!strcmp(optarg, "mbind_pingpong")) {
				operation_type = OT_MBIND_PINGPONG;
			} else if (!strcmp(optarg, "page_migration_pingpong")) {
				operation_type = OT_PAGE_MIGRATION_PINGPONG;
			} else if (!strcmp(optarg, "noop")) {
				operation_type = OT_NOOP;
			} else if (!strcmp(optarg, "busyloop")) {
				operation_type = OT_BUSYLOOP;
			} else if (!strcmp(optarg, "hugetlb_reserve")) {
				operation_type = OT_HUGETLB_RESERVE;
			} else
				operation_type = strtoul(optarg, NULL, 0);
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
		case 'P': /* do the operation for hugepage partially */
			hp_partial = 1;
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
		case 's':
			if (!strcmp(optarg, "migratepages"))
				migration_src = MS_MIGRATEPAGES;
			else if (!strcmp(optarg, "mbind"))
				migration_src = MS_MBIND;
			else if (!strcmp(optarg, "move_pages"))
				migration_src = MS_MOVE_PAGES;
			else if (!strcmp(optarg, "hotremove"))
				migration_src = MS_HOTREMOTE;
			else if (!strcmp(optarg, "madv_soft"))
				migration_src = MS_MADV_SOFT;
			else if (!strcmp(optarg, "auto_numa"))
				migration_src = MS_AUTO_NUMA;
			else if (!strcmp(optarg, "change_cpuset"))
				migration_src = MS_CHANGE_CPUSET;
			else
				errmsg("invalid -s option %s\n", optarg);
			break;
		case 'R':
			mapflag |= MAP_NORESERVE;
			break;
		case 'F':
			forkflag = 1;
			break;
		case 'w':
			if (!strcmp(optarg, "start")) {
				waitpoint_mask |= 1 << WP_START;
			} else if (!strcmp(optarg, "after_mmap")) {
				waitpoint_mask |= 1 << WP_AFTER_MMAP;
			} else if (!strcmp(optarg, "after_allocate")) {
				waitpoint_mask |= 1 << WP_AFTER_ALLOCATE;
			} else if (!strcmp(optarg, "before_munmap")) {
				waitpoint_mask |= 1 << WP_BEFORE_FREE;
			} else if (!strcmp(optarg, "exit")) {
				waitpoint_mask |= 1 << WP_EXIT;
			} else {
				int i;
				waitpoint_mask |= strtoul(optarg, NULL, 0);
				printf("waitpoint_mask %lx\n", waitpoint_mask);
			}
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
