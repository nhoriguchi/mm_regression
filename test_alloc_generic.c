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
#include "include.h"

void do_normal_allocation(void) {
	char *p[BUFNR];

	mmap_all(p);

	/* In both branch, signal(SIGUSR1) can break the loop or pause(). */
	if (busyloop)
		while (flag)
			access_all(p);
	else
		pause();

	munmap_all(p);
}

void do_mmap_munmap_iteration(void) {
	char *p[BUFNR];

	while (flag) {
		mmap_all(p);
		if (busyloop)
			access_all(p);
		munmap_all(p);
	}
}

void do_injection(char **p) {
	char rbuf[256];
	unsigned long offset = 0;

	switch (injection_type) {
	case MCE_SRAO:
	case SYSFS_HARD:
	case SYSFS_SOFT:
		pprintf("waiting for injection from outside\n");
		pause();
		break;
	case MADV_HARD:
	case MADV_SOFT:
		pprintf("error injection with madvise\n");
		pause();
		pipe_read(rbuf);
		offset = strtol(rbuf, NULL, 0);
		Dprintf("madvise inject to addr %lx\n", p[0] + offset * PS);
		if (madvise(p[0] + offset * PS, PS, injection_type == MADV_HARD ?
			    MADV_HWPOISON : MADV_SOFT_OFFLINE) != 0)
			perror("madvise");
		pprintf("after madvise injection\n");
		pause();
		break;
	}

	if (access_after_injection) {
		pprintf("writing affected region\n");
		pause();
		access_all(p);
	}

	pprintf("memory_error_injection_done\n");
	pause();
}

void do_memory_error_injection(void) {
	char *p[BUFNR];

	mmap_all(p);
	do_injection(p);
	munmap_all(p);
}

void do_alloc_exit(void) {
	char *p[BUFNR];

	mmap_all(p);
	access_all(p);
	munmap_all(p);
}

static void __do_madv_stress(char **p, int backend) {
	int ret;
	int i;
	int madv = (injection_type == MADV_HARD ? MADV_HWPOISON : MADV_SOFT_OFFLINE);

	for (i = 0; i < nr_chunk; i++) {
		ret = madvise(p[i], PS, madv);
		if (ret < 0) {
			fprintf(stderr, "backend:%d, i:%d: ", backend, i);
			perror("madvise");
		}
	}
}

void do_multi_backend(void) {
	int i;
	char *p[NR_BACKEND_TYPES][BUFNR];

	for (i = 0; i < NR_BACKEND_TYPES; i++) {
		/* TODO: might not prepared yet */
		/* if (i == HUGETLB_SHMEM || i == HUGETLB_SHMEM) */
		/* 	continue; */
		backend_type = i;
		allocate_base = (void *)ADDR_INPUT + i * nr_p * PS;
		mmap_all(p[i]);
	}

	if (injection_type == MADV_HARD || injection_type == MADV_SOFT) {
		for (i = 0; i < NR_BACKEND_TYPES; i++) {
			__do_madv_stress(p[i], i);
		}
	} else if (busyloop) {
		pprintf("do_multi_backend_busyloop\n");
		while (flag) {
			for (i = 0; i < NR_BACKEND_TYPES; i++)
				access_all(p[i]);
		}
	}

	for (i = 0; i < NR_BACKEND_TYPES; i++) {
		backend_type = i;
		allocate_base = (void *)ADDR_INPUT + i * nr_p * PS;
		if (access_after_injection)
			access_all(p[i]);
		munmap_all(p[i]);
	}
}

/* TODO: validation options' combination more */
static void setup(void) {
	nr_nodes = numa_max_node() + 1;
	nodemask = (1UL << nr_nodes) - 1; /* all nodes in default */
	if (operation_type == OT_PAGE_MIGRATION) {
		nr_nodes = numa_max_node() + 1;
		if (nr_nodes < 2)
			errmsg("A minimum of 2 nodes is required for this test.\n");
	}

	signal(SIGUSR1, sig_handle);
	signal(SIGUSR2, sig_handle_flag);

	if (backend_type == PAGECACHE || operation_type == OT_MULTI_BACKEND) {
		if (!workdir)
			err("you must set workdir with -d option to allocate pagecache");
		create_regular_file();
	}

	if (backend_type == HUGETLB_FILE || operation_type == OT_MULTI_BACKEND) {
		if (!workdir)
			err("you must set workdir with -d option to allocate hugetlbfs file");
		create_hugetlbfs_file();
	}

	if (access_after_injection && injection_type == -1)
		err("-A is set, but -e is not set, which is meaningless.");

	nr_chunk = (nr_p - 1) / CHUNKSIZE + 1;
}

int main(int argc, char *argv[]) {
	char c;

	while ((c = getopt(argc, argv, "vp:n:N:bm:io:e:PB:Af:d:M:s:R")) != -1) {
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
		case 'i':
			operation_type = OT_MAPPING_ITERATION;
			break;
		case 'o':
			if (!strcmp(optarg, "iterate_mapping"))
				operation_type = OT_MAPPING_ITERATION;
			else if (!strcmp(optarg, "allocate_once"))
				operation_type = OT_ALLOCATE_ONCE;
			else if (!strcmp(optarg, "memory_error_injection"))
				operation_type = OT_MEMORY_ERROR_INJECTION;
			else if (!strcmp(optarg, "alloc_exit"))
				operation_type = OT_ALLOC_EXIT;
			else if (!strcmp(optarg, "multi_backend"))
				operation_type = OT_MULTI_BACKEND;
			else if (!strcmp(optarg, "page_migration"))
				operation_type = OT_PAGE_MIGRATION;
			else
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
				injection_type = strtoul(optarg, NULL, 0);
			break;
		case 'P': /* partial mbind() */
			partialmbind = 1;
			break;
		case 'B':
			if (!strcmp(optarg, "pagecache"))
				backend_type = PAGECACHE;
			else if (!strcmp(optarg, "anonymous"))
				backend_type = ANONYMOUS;
			else if (!strcmp(optarg, "thp"))
				backend_type = THP;
			else if (!strcmp(optarg, "hugetlb_anon"))
				backend_type = HUGETLB_ANON;
			else if (!strcmp(optarg, "hugetlb_shmem"))
				backend_type = HUGETLB_SHMEM;
			else if (!strcmp(optarg, "hugetlb_file"))
				backend_type = HUGETLB_FILE;
			else if (!strcmp(optarg, "ksm"))
				backend_type = KSM;
			else if (!strcmp(optarg, "zero"))
				backend_type = ZERO;
			else if (!strcmp(optarg, "huge_zero"))
				backend_type = HUGE_ZERO;
			else
				backend_type = strtoul(optarg, NULL, 0);
			break;
		case 'A':
			access_after_injection = 1;
			break;
		case 'f':
			file = optarg;
			printf("file %s\n", file);
			fd = checked_open(file, O_RDWR);
			break;
		case 'd': /* tmpdir/workdir */
			workdir = optarg;
			break;
		case 'M':
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
			else
				errmsg("invalid optarg for -s\n");
			break;
		case 'R':
			mapflag |= MAP_NORESERVE;
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	setup();

	/* TODO: shmem hugetlb full support */
	if (backend_type == HUGETLB_SHMEM) {
		shmids = malloc(sizeof(int) * nr_chunk);
	}

	switch (operation_type) {
	case OT_MAPPING_ITERATION:
		do_mmap_munmap_iteration();
		break;
	case OT_ALLOCATE_ONCE:
		do_normal_allocation();
		break;
	case OT_MEMORY_ERROR_INJECTION:
		do_memory_error_injection();
		break;
	case OT_ALLOC_EXIT:
		do_alloc_exit();
		break;
	case OT_MULTI_BACKEND:
		do_multi_backend();
		break;
	case OT_PAGE_MIGRATION:
		pprintf("just started\n");
		pause();
		do_page_migration();
		break;
	}
}
