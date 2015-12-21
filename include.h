#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"
#include "test_core/lib/pfn.h"

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

#define ADDR_INPUT 0x700000000000

/* for multi_backend operation */
void *allocate_base = (void *)ADDR_INPUT;

unsigned long nr_nodes;
unsigned long nodemask;

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
	OT_PAGE_MIGRATION,
	NR_OPERATION_TYPES,
};
int operation_type = -1;

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
int backend_type = -1;

enum {
	MS_MIGRATEPAGES,
	MS_MBIND,
	MS_MOVE_PAGES,
	MS_HOTREMOTE,
	MS_MADV_SOFT,
	NR_MIGRATION_SRCS,
};
int migration_src = -1;

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
		p = checked_mmap(baseaddr, size, protflag, mapflag, hugetlbfd, offset);
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

int do_work_memory(char **p, int (*func)(char *p, int size, void *arg), void *args) {
	int i;
	int ret = 0;
	int size;
	void *baseaddr = allocate_base;

	for (i = 0; i < nr_chunk; i++) {
		size = get_size_of_chunked_mmap_area(i);
		ret = (*func)(p[i], size, args);
		if (ret != 0)
			break;
		baseaddr += size;
	}
	return ret;
}

extern void do_alloc_exit(void);
extern void do_memory_error_injection(void);
extern void do_injection(char **p);
extern void do_mmap_munmap_iteration(void);
extern void do_normal_allocation(void);
extern void do_multi_backend(void);
extern void do_page_migration(void);



int partialmbind;

/*
 * Memory block size is 128MB (1 << 27) = 32k pages (1 << 15)
 */
#define MEMBLK_ORDER	15
#define MEMBLK_SIZE	(1 << MEMBLK_ORDER)
#define MAX_MEMBLK	1024

static int set_mempolicy_node(int mode, unsigned long nid) {
	/* Assuming that max node number is < 64 */
	unsigned long nodemask = 1UL << nid;
	if (mode == MPOL_DEFAULT)
		set_mempolicy(mode, NULL, nr_nodes);
	else
		set_mempolicy(mode, &nodemask, nr_nodes);
}

static void do_migratepages(char **p) {
	pprintf("entering busy loop\n");
	if (busyloop)
		while (flag)
			access_all(p);
	else
		pause();
}

struct mbind_arg {
	int mode;
	unsigned flags;
	struct bitmask *new_nodes;
};

static int __mbind_chunk(char *p, int size, void *args) {
	int i;
	struct mbind_arg *mbind_arg = (struct mbind_arg *)args;

	if (partialmbind) {
		for (i = 0; i < (size - 1) / 512 + 1; i++)
			mbind(p + i * HPS, PS,
			      mbind_arg->mode, mbind_arg->new_nodes->maskp,
			      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
	} else
		mbind(p, size,
		      mbind_arg->mode, mbind_arg->new_nodes->maskp,
		      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
}

static void do_mbind(char **p) {
	int i;
	int ret;
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
	};

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);
	numa_bitmask_setbit(mbind_arg.new_nodes, 1);

	/* TODO: more race consideration, chunk, busyloop case? */
	pprintf("call mbind\n");
	ret = do_work_memory(p, __mbind_chunk, (void *)&mbind_arg);
	if (ret == -1) {
		perror("mbind");
		pprintf("mbind failed\n");
		pause();
		/* return; */
	}

	pprintf("entering busy loop\n");
	if (busyloop)
		while (flag)
			access_all(p);
	else
		pause();
}

static int __move_pages_chunk(char *p, int size, void *args) {
	int i;
	void *__move_pages_addrs[CHUNKSIZE + 1];
	int __move_pages_status[CHUNKSIZE + 1];
	int __move_pages_nodes[CHUNKSIZE + 1];

	for (i = 0; i < size / PS; i++) {
		__move_pages_addrs[i] = p + i * PS;
		__move_pages_nodes[i] = 1;
		__move_pages_status[i] = 0;
	}
	numa_move_pages(0, size / PS, __move_pages_addrs, __move_pages_nodes,
			__move_pages_status, MPOL_MF_MOVE_ALL);
}

static void do_move_pages(char **p) {
	int ret;

	pprintf("call move_pages()\n");
	ret = do_work_memory(p, __move_pages_chunk, NULL);
	if (ret == -1) {
		perror("move_pages");
		pprintf("move_pages failed\n");
		pause();
		/* return; */
	}

	signal(SIGUSR1, sig_handle_flag);
	pprintf("entering busy loop\n");
	if (busyloop)
		while (flag)
			access_all(p);
	else
		pause();
}

static int get_max_memblock(void) {
	FILE *f;
	char str[256];
	int spanned;
	int start_pfn;
	int mb;

	f = fopen("/proc/zoneinfo", "r");
	while (fgets(str, 256, f)) {
		sscanf(str, " spanned %d", &spanned);
		sscanf(str, " start_pfn: %d", &start_pfn);
	}
	fclose(f);
	return (spanned + start_pfn) >> MEMBLK_ORDER;
}

/* Assuming that */
static int check_compound(void) {
	return !!(opt_bits[0] & BIT(COMPOUND_HEAD));
}

/* find memblock preferred to be hotremoved */
static int memblock_check(char **p) {
	int i, j;
	int ret;
	int max_memblock = get_max_memblock();
	uint64_t pageflags[MEMBLK_SIZE];
	int pmemblk = 0;
	int max_matched_pages = 0;
	int compound = check_compound();

	kpageflags_fd = open("/proc/kpageflags", O_RDONLY);
	for (i = 0; i < max_memblock; i++) {
		int pfn = i * MEMBLK_SIZE;
		int matched = 0;

		ret = kpageflags_read(pageflags, pfn, MEMBLK_SIZE);
		for (j = 0; j < MEMBLK_SIZE; j++) {
			if (bit_mask_ok(pageflags[j])) {
				if (compound)
					matched += 512;
				else
					matched++;
			}
		}
		Dprintf("memblock:%d, readret:%d matched:%d (%d%), 1:%lx, 2:%lx\n",
		       i, ret, matched, matched*100/MEMBLK_SIZE,
		       pageflags[0], pageflags[1]);
		if (max_matched_pages < matched) {
			max_matched_pages = matched;
			pmemblk = i;
		}
	}
	close(kpageflags_fd);

	return pmemblk;
}

static void do_hotremove(char **p) {
	int pmemblk; /* preferred memory block for hotremove */

	if (set_mempolicy_node(MPOL_PREFERRED, 1) == -1)
		err("set_mempolicy(MPOL_PREFERRED) to 1");

	pmemblk = memblock_check(p);

	/* pass pmemblk into control script */
	pprintf("before memory_hotremove: %d\n", pmemblk);
	pause();

	pprintf("entering busy loop\n");
	if (busyloop)
		while (flag)
			access_all(p);
	else
		pause();
}

static int __madv_soft_chunk(char *p, int size, void *args) {
	int i;
	int ret;

	for (i = 0; i < size / HPS; i++) {
		ret = madvise(p + i * HPS, 4096, MADV_SOFT_OFFLINE);
		if (ret)
			break;
	}
	return ret;
}

static void do_madv_soft(char **p) {
	int ret;
	int loop = 10;
	int do_unpoison = 1;

	pprintf("call madvise(MADV_SOFT_OFFLINE)\n");
	ret = do_work_memory(p, __madv_soft_chunk, NULL);
	if (ret == -1) {
		perror("madvise(MADV_SOFT_OFFLINE)");
		pprintf("madvise(MADV_SOFT_OFFLINE) failed\n");
		pause();
		/* return; */
	}

	signal(SIGUSR1, sig_handle_flag);
	pprintf("entering busy loop\n");
	if (busyloop)
		while (flag)
			access_all(p);
	else
		pause();
}

void do_page_migration(void) {
	char *p[BUFNR];

	/* node 0 is preferred */
	if (set_mempolicy_node(MPOL_PREFERRED, 0) == -1)
		err("set_mempolicy(MPOL_PREFERRED) to 0");

	mmap_all(p);

	if (set_mempolicy_node(MPOL_DEFAULT, 0) == -1)
		err("set_mempolicy to MPOL_DEFAULT");

	pprintf("page_fault_done\n");
	pause();

	switch (migration_src) {
	case MS_MIGRATEPAGES:
		do_migratepages(p);
		break;
	case MS_MBIND:
		do_mbind(p);
		break;
	case MS_MOVE_PAGES:
		do_move_pages(p);
		break;
	case MS_HOTREMOTE:
		do_hotremove(p);
		break;
	case MS_MADV_SOFT:
		do_madv_soft(p);
		break;
	}

	pprintf("exited busy loop\n");
	pause();
}
