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
#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"

#define ADDR_INPUT 0x700000000000

/* for multi_backend operation */
void *allocate_base = (void *)ADDR_INPUT;

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

#define BUFNR 0x10000 /* 65536 */
#define CHUNKSIZE 0x1000 /* 4096 pages */

int mapflag = MAP_ANONYMOUS|MAP_PRIVATE;
int protflag = PROT_READ|PROT_WRITE;

int nr_p = 512;
int nr_chunk = 1;
int busyloop = 0;

char *workdir;
char *file;
int fd;
int hugetlbfd;

int *shmids;

enum {
	OT_MAPPING_ITERATION,
	OT_ALLOCATE_ONCE,
	OT_MEMORY_ERROR_INJECTION,
	OT_ALLOC_EXIT,
	OT_MULTI_BACKEND,
	NR_OPERATION_TYPES,
};
int operation_type;

enum {
	MCE_SRAO,
	SYSFS_HARD,
	SYSFS_SOFT,
	MADV_HARD,
	MADV_SOFT,
	NR_INJECTION_TYPES,
};
int injection_type = -1;
int access_after_injection;

enum {
	PAGECACHE,
	ANONYMOUS,
	THP,
	HUGETLB_ANON,
	HUGETLB_SHMEM,
	HUGETLB_FILE,
	KSM,
	ZERO,
	HUGE_ZERO,
	NR_BACKEND_TYPES,
};
int backend_type;

/*
 * @i is current chunk index. In the last chunk mmaped size will be truncated.
 */
static int get_size_of_chunked_mmap_area(int i) {
	if (i == nr_chunk - 1)
		return ((nr_p - 1) % CHUNKSIZE + 1) * PS;
	else
		return CHUNKSIZE * PS;
}

static void *prepare_memory(void *baseaddr, int size) {
	char *p;
	unsigned long offset;
	int index;

	switch (backend_type) {
	case PAGECACHE:
		offset = (unsigned long)(baseaddr - allocate_base);
		/* printf("open, fd %d, offset %lx\n", fd, offset); */
		p = checked_mmap(baseaddr, size, protflag, MAP_SHARED, fd, offset);
		break;
	case ANONYMOUS:
		/* printf("base:0x%lx, size:%lx\n", baseaddr, size); */
		p = checked_mmap(baseaddr, size, protflag, mapflag, -1, 0);
		madvise(p, size, MADV_NOHUGEPAGE);
		break;
	case THP:
		p = checked_mmap(baseaddr, size, protflag, mapflag, -1, 0);
		madvise(p, size, MADV_HUGEPAGE);
		break;
	case HUGETLB_ANON:
		p = checked_mmap(baseaddr, size, protflag, mapflag|MAP_HUGETLB, -1, 0);
		madvise(p, size, MADV_DONTNEED);
		break;
	case HUGETLB_SHMEM:
		/* printf("size %lx\n", size); */
		/*
		 * TODO: currently alloc_shm_hugepage is not designed to be called
		 * multiple times, so controlling script must cleanup shmems after
		 * running the testcase.
		 */
		p = alloc_shm_hugepage(size);
		break;
	case HUGETLB_FILE:
		offset = (unsigned long)(baseaddr - allocate_base);
		/* printf("open, hugetlbfd %d, offset %lx\n", hugetlbfd, offset); */
		p = checked_mmap(baseaddr, size, protflag, MAP_SHARED, hugetlbfd, offset);
		break;
	case KSM:
		p = checked_mmap(baseaddr, size, protflag, mapflag, -1, 0);
		set_mergeable(p, size);
		break;
	case ZERO:
		p = checked_mmap(baseaddr, size, protflag, mapflag, -1, 0);
		madvise(p, size, MADV_NOHUGEPAGE);
		break;
	case HUGE_ZERO:
		p = checked_mmap(baseaddr, size, protflag, mapflag, -1, 0);
		madvise(p, size, MADV_HUGEPAGE);
		break;
	}

	return p;
}

static void cleanup_memory(void *baseaddr, int size) {
	;
}

static void read_memory(char *p, int size) {
	int i;
	char c;

	for (i = 0; i < size; i += PS) {
		c = p[i];
	}
}

static void mmap_all(char **p) {
	int i;
	int size;
	void *baseaddr = allocate_base;

	for (i = 0; i < nr_chunk; i++) {
		size = get_size_of_chunked_mmap_area(i);

		/* printf("base:0x%lx, size:%lx\n", baseaddr, size); */
		/* p[i] = checked_mmap(baseaddr, size, protflag, mapflag, -1, 0); */
		p[i] = prepare_memory(baseaddr, size);
		/* printf("p[%d]:%p + 0x%lx\n", i, p[i], size); */
		/* TODO: generalization, making this configurable */
		if (backend_type == ZERO || backend_type == HUGE_ZERO)
			read_memory(p[i], size);
		else
			memset(p[i], 'a', size);
		baseaddr += size;
	}
}

static void munmap_all(char **p) {
	int i;
	int size;
	void *baseaddr = allocate_base;

	for (i = 0; i < nr_chunk; i++) {
		size = get_size_of_chunked_mmap_area(i);
		/* cleanup_memory(p[i], size); */
		checked_munmap(p[i], size);
		baseaddr += size;
	}
}

static void access_all(char **p) {
	int i;
	int size;
	void *baseaddr = allocate_base;

	for (i = 0; i < nr_chunk; i++) {
		size = get_size_of_chunked_mmap_area(i);
		if (backend_type == ZERO || backend_type == HUGE_ZERO)
			read_memory(p[i], size);
		else
			memset(p[i], 'b', size);
		baseaddr += size;
	}
}

static void do_normal_allocation(void) {
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

static void do_mmap_munmap_iteration(void) {
	char *p[BUFNR];

	while (flag) {
		mmap_all(p);
		if (busyloop)
			access_all(p);
		munmap_all(p);
	}
}

static void do_injection(char **p) {
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

static void do_memory_error_injection(void) {
	char *p[BUFNR];

	mmap_all(p);
	do_injection(p);
	munmap_all(p);
}

static void do_alloc_exit(void) {
	char *p[BUFNR];

	mmap_all(p);
	access_all(p);
	munmap_all(p);
}

static __do_madv_stress(char **p, int backend) {
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

static void do_multi_backend(void) {
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

static void create_regular_file(void) {
	int i;
	char fpath[256];
	char buf[PS];

	sprintf(fpath, "%s/testfile", workdir);
	fd = open(fpath, O_CREAT|O_RDWR, 0755);
	if (fd == -1)
		err("open");
	memset(buf, 'a', PS);
	for (i = 0; i < nr_p; i++)
		write(fd, buf, PS);
	fsync(fd);
}

/*
 * Assuming that hugetlbfs is mounted on @workdir/hugetlbfs. And cleanup is
 * supposed to be done by control scripts.
 */
static void create_hugetlbfs_file(void) {
	int i;
	char fpath[256];
	char buf[PS];

	sprintf(fpath, "%s/hugetlbfs/testfile", workdir);
	hugetlbfd = open(fpath, O_CREAT|O_RDWR, 0755);
	if (hugetlbfd == -1)
		err("open");
	memset(buf, 'a', PS);
	for (i = 0; i < nr_p; i++)
		write(hugetlbfd, buf, PS);
	fsync(hugetlbfd);
}

/* TODO: validation options' combination more */
static void setup(void) {
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

	/* depends on busyloop flag */
	signal(SIGUSR1, sig_handle_flag);
	/* signal(SIGUSR1, sig_handle); */

	nr_chunk = (nr_p - 1) / CHUNKSIZE + 1;
}

int main(int argc, char *argv[]) {
	char c;
        unsigned long nr_nodes = numa_max_node() + 1;
        unsigned long nodemask = (1UL << nr_nodes) - 1; /* all nodes in default */

	while ((c = getopt(argc, argv, "vp:n:bm:io:e:B:Af:d:")) != -1) {
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
		case 'b':
			busyloop = 1;
			break;
		case 'm':
			nodemask = strtoul(optarg, NULL, 0);
			printf("%lx\n", nodemask);
			if (set_mempolicy(MPOL_BIND, &nodemask, nr_nodes) == -1)
				err("set_mempolicy");
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
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	setup();

	Dprintf("nr_p %lx, nr_chunk %lx\n", nr_p, nr_chunk);
	Dprintf("operation:%lx, backend:%lx, injection:%lx\n",
		operation_type, backend_type, injection_type);

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
	}
}
