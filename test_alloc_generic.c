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

void do_normal_allocation(void) {
	mmap_all_chunks();

	/* In both branch, signal(SIGUSR1) can break the loop or pause(). */
	if (busyloop)
		while (flag)
			access_all_chunks();
	else
		pause();

	munmap_all_chunks();
}

void do_mmap_munmap_iteration(void) {
	while (flag) {
		mmap_all_chunks();
		munmap_all_chunks();
	}
}

/* inject only onto the first page, so allocating big region makes no sense. */
void __do_memory_error_injection(void) {
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
		Dprintf("madvise inject to addr %lx\n", chunkset[0].p + offset * PS);
		if (madvise(chunkset[0].p + offset * PS, PS, injection_type == MADV_HARD ?
			    MADV_HWPOISON : MADV_SOFT_OFFLINE) != 0)
			perror("madvise");
		pprintf("after madvise injection\n");
		pause();
		break;
	}

	if (access_after_injection) {
		pprintf("writing affected region\n");
		pause();
		access_all_chunks();
	}
}

void do_memory_error_injection(void) {
	mmap_all_chunks();
	__do_memory_error_injection();
	pprintf("before_free\n");
	pause();
	munmap_all_chunks();
}

void do_alloc_exit(void) {
	mmap_all_chunks();
	munmap_all_chunks();
}

static void __do_madv_stress() {
	int i, j;
	int madv = (injection_type == MADV_HARD ? MADV_HWPOISON : MADV_SOFT_OFFLINE);

	for (j = 0; j < nr_mem_types; j++) {
		for (i = 0; i < nr_chunk; i++) {
			struct mem_chunk *tmp = &chunkset[i + j * nr_chunk];

			if (madvise(tmp->p, PS, madv) == -1) {
				fprintf(stderr, "chunk:%p, backend:%d\n",
					tmp->p, tmp->mem_type);
				perror("madvise");
			}
		}
	}
}

static void _do_madv_stress(void) {
	__do_madv_stress();
	if (access_after_injection)
		access_all_chunks();
}

static void do_madv_stress(void) {
	mmap_all_chunks();
	_do_madv_stress();
	munmap_all_chunks();
}

static void __do_fork_stress(void) {
	while (flag) {
		pid_t pid = fork();
		if (!pid) {
			access_all_chunks();
			return;
		}
		/* get status? */
		waitpid(pid, NULL, 0);
	}
}

static void do_fork_stress(void) {
	mmap_all_chunks();
	__do_fork_stress();
	munmap_all_chunks();
}

static int __mremap_chunk(char *p, int csize, void *args) {
	int offset = nr_chunk * CHUNKSIZE * PS;
	int back = *(int *)args; /* 0: +offset, 1: -offset*/

	if (back) {
		printf("mremap p:%p+%lx -> %p\n", p + offset, csize, p);
		return mremap(p + offset, csize, csize, MREMAP_MAYMOVE|MREMAP_FIXED, p);
	} else {
		printf("mremap p:%p+%lx -> %p\n", p, csize, p + offset);
		return mremap(p, csize, csize, MREMAP_MAYMOVE|MREMAP_FIXED, p + offset);
	}
}

static void __do_mremap_stress(void) {
	int ret;
	int back = 0;

	while (flag) {
		back = 0;
		ret = do_work_memory2(__mremap_chunk, (void *)&back);
		if (ret == -1) {
			perror("mremap");
			/* pprintf("mremap failed\n"); */
			/* return; */
		} else
			pprintf("mremap OK %lx\n", ret);
		back = 1;
		ret = do_work_memory2(__mremap_chunk, (void *)&back);
		if (ret == -1) {
			perror("mremap");
			/* pprintf("mremap failed\n"); */
			/* return; */
		} else
			pprintf("mremap OK %lx\n", ret);
	}
}

static void do_mremap_stress(void) {
	mmap_all_chunks();
	__do_mremap_stress();
	munmap_all_chunks();
}

static int __madv_willneed_chunk(char *p, int size, void *args) {
	return madvise(p, size, MADV_WILLNEED);
}

static void __do_madv_willneed(void) {
	int ret = do_work_memory2(__madv_willneed_chunk, NULL);
	if (ret == -1) {
		perror("madv_willneed");
		pprintf("madv_willneed failed\n");
		pause();
		/* return; */
	}
}

static void do_madv_willneed(void) {
	mmap_all_chunks();
	__do_madv_willneed();
	munmap_all_chunks();
}

static void __do_allocate_more(void) {
	char *panon;
	int size = nr_p * PS;

	panon = checked_mmap((void *)(ADDR_INPUT + size), size, MMAP_PROT,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	/* should cause swap out with external cgroup setting */
	pprintf("anonymous address starts at %p\n", panon);
	memset(panon, 'a', size);
}

static void allocate_transhuge(void *ptr)
{
	uint64_t ent[2];
	int i;

	/* drop pmd */
	if (mmap(ptr, THPS, PROT_READ | PROT_WRITE,
		 MAP_FIXED | MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE, -1, 0) != ptr)
		err("mmap transhuge");

	if (madvise(ptr, THPS, MADV_HUGEPAGE))
		err("MADV_HUGEPAGE");

	/* allocate transparent huge page */
	for (i = 0; i < (1 << (THP_SHIFT - PAGE_SHIFT)); i++) {
		*(volatile void **)(ptr + i * PAGE_SIZE) = ptr;
	}
}

static void do_memory_compaction(void) {
	size_t ram, len;
	void *ptr, *p;

	ram = sysconf(_SC_PHYS_PAGES);
	if (ram > SIZE_MAX / sysconf(_SC_PAGESIZE) / 4)
		ram = SIZE_MAX / 4;
	else
		ram *= sysconf(_SC_PAGESIZE);
	Dprintf("===> %lx\n", ram);
	len = ram;
	Dprintf("===> %lx\n", len);
	len -= len % THPS;
	ptr = mmap((void *)ADDR_INPUT, len + THPS, PROT_READ | PROT_WRITE,
			MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE, -1, 0);

	if (madvise(ptr, len, MADV_HUGEPAGE))
		err("MADV_HUGEPAGE");

	pprintf("entering busy loop\n");
	while (flag) {
		for (p = ptr; p < ptr + len; p += THPS) {
			allocate_transhuge(p);
			/* split transhuge page, keep last page */
			if (madvise(p, THPS - PAGE_SIZE, MADV_DONTNEED))
				err("MADV_DONTNEED");
		}
	}
}

static void __do_mbind_pingpong(void) {
	int ret;
	int node;
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
	};

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);

	while (flag) {
		numa_bitmask_clearall(mbind_arg.new_nodes);
		numa_bitmask_setbit(mbind_arg.new_nodes, 1);

		ret = do_work_memory2(__mbind_chunk, &mbind_arg);
		if (ret == -1) {
			perror("mbind");
		/* 	pprintf("mbind failed\n"); */
		/* 	pause(); */
		}

		numa_bitmask_clearall(mbind_arg.new_nodes);
		numa_bitmask_setbit(mbind_arg.new_nodes, 0);

		ret = do_work_memory2(__mbind_chunk, &mbind_arg);
		if (ret == -1) {
			perror("mbind");
		/* 	pprintf("mbind failed\n"); */
		/* 	pause(); */
		}
	}
}

static void __do_move_pages_pingpong(void) {
	int ret;
	int node;

	while (flag) {
		node = 1;
		ret = do_work_memory2(__move_pages_chunk, &node);
		if (ret == -1) {
			perror("move_pages");
			pprintf("move_pages failed\n");
			pause();
		}

		node = 0;
		ret = do_work_memory2(__move_pages_chunk, &node);
		if (ret == -1) {
			perror("move_pages");
			pprintf("move_pages failed\n");
			pause();
		}
	}
}

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

	signal(SIGUSR1, sig_handle);
	signal(SIGUSR2, sig_handle_flag);

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
	pprintf("%s: operation_type %d\n", __func__, operation_type);
	switch (operation_type) {
	case OT_MEMORY_ERROR_INJECTION:
		__do_memory_error_injection();
		break;
	case OT_PAGE_MIGRATION:
		pprintf("__do_page_migration\n");
		__do_page_migration();
		break;
	case OT_PROCESS_VM_ACCESS:
		__do_process_vm_access();
		break;
	case OT_MLOCK:
		__do_mlock();
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
	}
}

/* static void operate_with_allocate_wait(int (alloc_func)(void), int (op_func)(void)) { */
static void operate_with_allocate_wait(void) {
	mmap_all_chunks();
	pprintf_wait(SIGUSR1, "page_fault_done\n");
	munmap_all_chunks();
}

static void operate_with_allocate_exit(void) {
	mmap_all_chunks();
	if (wait_after_allocate)
		pprintf_wait(SIGUSR1, "page_fault_done\n");
	do_operation();
	if (wait_before_free)
		pprintf_wait(SIGUSR1, "before_free\n");
	munmap_all_chunks();
}

static void operate_with_allocate_busyloop(void) {
	mmap_all_chunks();
	if (wait_after_allocate)
		pprintf_wait(SIGUSR1, "page_fault_done\n");
	while (flag)
		access_all_chunks();
	if (wait_before_free)
		pprintf_wait(SIGUSR1, "before_free\n");
	munmap_all_chunks();
}

static void operate_with_mapping_iteration(void) {
	while (flag) {
		mmap_all_chunks();
		munmap_all_chunks();
	}
}

static void operate_with_numa_prepared(void) {
	mmap_all_chunks_numa();
	if (wait_after_allocate)
		pprintf_wait(SIGUSR1, "page_fault_done\n");
	do_operation();
	if (wait_before_free)
		pprintf_wait(SIGUSR1, "before_free\n");
	munmap_all_chunks();
}

int main(int argc, char *argv[]) {
	char c;

	while ((c = getopt(argc, argv, "vp:n:N:bm:io:e:PB:Af:d:M:s:RFa:w:O:")) != -1) {
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
		case 'a':
			if (!strcmp(optarg, "iterate_mapping"))
				allocation_type = AT_MAPPING_ITERATION;
			else if (!strcmp(optarg, "allocate_exit"))
				allocation_type = AT_ALLOCATE_EXIT;
			else if (!strcmp(optarg, "allocate_wait"))
				allocation_type = AT_ALLOCATE_WAIT;
			else if (!strcmp(optarg, "allocate_busyloop"))
				allocation_type = AT_ALLOCATE_BUSYLOOP;
			else if (!strcmp(optarg, "numa_prepared"))
				allocation_type = AT_NUMA_PREPARED;
			else if (!strcmp(optarg, "none"))
				allocation_type = AT_NONE;
			else if (!strcmp(optarg, "access_loop"))
				allocation_type = AT_ACCESS_LOOP;
			else if (!strcmp(optarg, "alloc_exit"))
				allocation_type = AT_ALLOC_EXIT;
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
				err("-o multi_backend is obsolete, use -B 0xffff");
			else if (!strcmp(optarg, "page_migration"))
				operation_type = OT_PAGE_MIGRATION;
			else if (!strcmp(optarg, "process_vm_access"))
				operation_type = OT_PROCESS_VM_ACCESS;
			else if (!strcmp(optarg, "mlock"))
				operation_type = OT_MLOCK;
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
			} else if (!strcmp(optarg, "after_allocate")) {
				waitpoint_mask |= 1 << WP_AFTER_ALLOCATE;
			} else if (!strcmp(optarg, "before_free")) {
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
			preferred_node = strtoul(optarg, NULL, 0);
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	setup();

	if (allocation_type != -1) {
		if (wait_start)
			pprintf_wait(SIGUSR1, "just started\n");

		switch (allocation_type) {
		case AT_ALLOCATE_WAIT:
			operate_with_allocate_wait();
			break;
		case AT_ALLOCATE_EXIT:
			operate_with_allocate_exit();
			break;
		case AT_ALLOCATE_BUSYLOOP:
			operate_with_allocate_busyloop();
			break;
		case AT_MAPPING_ITERATION:
			operate_with_mapping_iteration();
			break;
		case AT_NUMA_PREPARED:
			operate_with_numa_prepared();
			break;
		case AT_NONE:
			operate_with_numa_prepared();
			break;
		}

		if (wait_exit)
			pprintf_wait(SIGUSR1, "just before exit\n");
	} else  {
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
		case OT_PAGE_MIGRATION:
			pprintf("just started\n");
			pause();
			do_page_migration();
			break;
		case OT_PROCESS_VM_ACCESS:
			do_process_vm_access();
			break;
		case OT_MLOCK:
			do_mlock();
			break;
		case OT_MPROTECT:
			do_mprotect();
			break;
		case OT_MADV_STRESS:
			do_madv_stress();
			break;
		case OT_FORK_STRESS:
			do_fork_stress();
			break;
		case OT_MREMAP_STRESS:
			do_mremap_stress();
			break;
		case OT_MBIND_FUZZ:
			do_mbind_fuzz();
			break;
		case OT_MEMORY_COMPACTION:
			if (wait_start)
				pprintf_wait(SIGUSR1, "just started\n");
			do_memory_compaction();
			if (wait_exit)
				pprintf_wait(SIGUSR1, "just before exit\n");
			break;
		}
	}
}
