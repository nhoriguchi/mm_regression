#include <sys/uio.h>
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

int forkflag;

struct mem_chunk {
	int mem_type;
	int chunk_size;
	char *p;
	int shmkey;
};

struct mem_chunk *chunkset;
int nr_all_chunks;
int nr_mem_types = 1;

enum {
	AT_MAPPING_ITERATION,
	AT_ALLOCATE_EXIT,
	AT_ALLOCATE_WAIT,
	AT_ALLOCATE_BUSYLOOP,
	AT_NUMA_PREPARED,
	AT_SIMPLE,
	AT_ACCESS_LOOP,
	AT_ALLOC_EXIT,
	NR_ALLOCATION_TYPES,
};
int allocation_type = -1;

enum {
	OT_MAPPING_ITERATION,
	OT_ALLOCATE_ONCE,
	OT_MEMORY_ERROR_INJECTION,
	OT_ALLOC_EXIT,
	OT_PAGE_MIGRATION,
	OT_PROCESS_VM_ACCESS,
	OT_MLOCK,
	OT_MPROTECT,
	OT_POISON_UNPOISON,
	OT_MADV_STRESS,
	OT_FORK_STRESS,
	OT_MREMAP_STRESS,
	OT_MBIND_FUZZ,
	OT_MADV_WILLNEED,
	OT_ALLOCATE_MORE,
	OT_MEMORY_COMPACTION,
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
	NORMAL_SHMEM,
	DEVMEM,
	NR_BACKEND_TYPES,
};

#define BE_PAGECACHE		(1UL << PAGECACHE)
#define BE_ANONYMOUS		(1UL << ANONYMOUS)
#define BE_THP			(1UL << THP)
#define BE_HUGETLB_ANON		(1UL << HUGETLB_ANON)
#define BE_HUGETLB_SHMEM	(1UL << HUGETLB_SHMEM)
#define BE_HUGETLB_FILE		(1UL << HUGETLB_FILE)
#define BE_KSM			(1UL << KSM)
#define BE_ZERO			(1UL << ZERO)
#define BE_HUGE_ZERO		(1UL << HUGE_ZERO)
#define BE_NORMAL_SHMEM		(1UL << NORMAL_SHMEM)
#define BE_DEVMEM		(1UL << DEVMEM)
unsigned long backend_bitmap = 0;

#define BE_HUGEPAGE	\
	(BE_THP|BE_HUGETLB_ANON|BE_HUGETLB_SHMEM|BE_HUGETLB_FILE|BE_NORMAL_SHMEM)

/* Waitpoint */
enum {
	WP_START,
	WP_AFTER_ALLOCATE,
	WP_BEFORE_FREE,
	WP_EXIT,
	NR_WAITPOINTS,
};
#define wait_start		(waitpoint_mask & (1 << WP_START))
#define wait_after_allocate	(waitpoint_mask & (1 << WP_AFTER_ALLOCATE))
#define wait_before_free	(waitpoint_mask & (1 << WP_BEFORE_FREE))
#define wait_exit		(waitpoint_mask & (1 << WP_EXIT))
int waitpoint_mask = 0;

enum {
	MS_MIGRATEPAGES,
	MS_MBIND,
	MS_MOVE_PAGES,
	MS_HOTREMOTE,
	MS_MADV_SOFT,
	MS_AUTO_NUMA,
	MS_CHANGE_CPUSET,
	MS_MBIND_FUZZ,
	NR_MIGRATION_SRCS,
};
int migration_src = -1;
int mpol_mode_for_page_migration = MPOL_PREFERRED;

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

static int find_next_backend(int i) {
	while (i < NR_BACKEND_TYPES) {
		if (backend_bitmap & (1UL << i))
			break;
		i++;
	}
	return i;
}

#define for_each_backend(i)			\
	for (i = find_next_backend(0);		\
	     i < NR_BACKEND_TYPES;		\
	     i = find_next_backend(i+1))

static int get_nr_mem_types(void) {
	int i, j = 0;

	for_each_backend(i)
		j++;
	return j;
}

/*
 * @i is current chunk index. In the last chunk mmaped size will be truncated.
 */
static int get_size_of_chunked_mmap_area(int i) {
	if ((i % nr_chunk) == nr_chunk - 1)
		return ((nr_p - 1) % CHUNKSIZE + 1) * PS;
	else
		return CHUNKSIZE * PS;
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
	char *phugetlb;

	sprintf(fpath, "%s/hugetlbfs/testfile", workdir);
	hugetlbfd = open(fpath, O_CREAT|O_RDWR, 0755);
	if (hugetlbfd == -1)
		err("open");
	phugetlb = checked_mmap(NULL, nr_p * PS, protflag, MAP_SHARED,
				hugetlbfd, 0);
	/* printf("phugetlb %p\n", phugetlb); */
	memset(phugetlb, 'a', nr_p * PS);
	munmap(phugetlb, nr_p * PS);
}

static void *alloc_shmem2(struct mem_chunk *mc, void *exp_addr, int hugetlb) {
	void *addr;
	int shmid;
	int flags = IPC_CREAT | SHM_R | SHM_W;

	if (hugetlb)
		flags |= SHM_HUGETLB;
	if ((shmid = shmget(shmkey, mc->chunk_size, flags)) < 0) {
		perror("shmget");
		return NULL;
	}
	addr = shmat(shmid, exp_addr, 0);
	if (addr == (char *)-1) {
		perror("Shared memory attach failure");
		shmctl(shmid, IPC_RMID, NULL);
		err("shmat failed");
		return NULL;
	}
	if (addr != exp_addr) {
		printf("Shared memory not attached to expected address (%p -> %p) %lx %lx\n", exp_addr, addr, SHMLBA, SHM_RND);
		shmctl(shmid, IPC_RMID, NULL);
		err("shmat failed");
		return NULL;
	}

	mc->shmkey = shmid;
	return addr;
}

static void free_shmem2(struct mem_chunk *mc) {
	if (shmdt((const void *)mc->p))
		perror("Shmem detach failed.");
	shmctl(mc->shmkey, IPC_RMID, NULL);
}

static void prepare_memory2(struct mem_chunk *mc, void *baseaddr,
			     unsigned long offset) {
	int dev_mem_fd;

	switch (mc->mem_type) {
	case PAGECACHE:
		/* printf("open, fd %d, offset %lx\n", fd, offset); */
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_SHARED, fd, offset);
		break;
	case ANONYMOUS:
		/* printf("base:0x%lx, size:%lx\n", baseaddr, size); */
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		madvise(mc->p, mc->chunk_size, MADV_NOHUGEPAGE);
		break;
	case THP:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		if (madvise(mc->p, mc->chunk_size, MADV_HUGEPAGE) == -1) {
			printf("p %p, size %lx\n", mc->p, mc->chunk_size);
			err("madvise");
		}
		break;
	case HUGETLB_ANON:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS|MAP_HUGETLB, -1, 0);
		madvise(mc->p, mc->chunk_size, MADV_DONTNEED);
		break;
	case HUGETLB_SHMEM:
		/*
		 * TODO: currently alloc_shm_hugepage is not designed to be called
		 * multiple times, so controlling script must cleanup shmems after
		 * running the testcase.
		 */
		mc->p = alloc_shmem2(mc, baseaddr, 1);
		break;
	case HUGETLB_FILE:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_SHARED, hugetlbfd, offset);
		break;
	case KSM:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		set_mergeable(mc->p, mc->chunk_size);
		break;
	case ZERO:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		madvise(mc->p, mc->chunk_size, MADV_NOHUGEPAGE);
		break;
	case HUGE_ZERO:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		madvise(mc->p, mc->chunk_size, MADV_HUGEPAGE);
		break;
	case NORMAL_SHMEM:
		mc->p = alloc_shmem2(mc, baseaddr, 0);
		break;
	case DEVMEM:
		/* Assuming that -n 1 is given */
		dev_mem_fd = checked_open("/dev/mem", O_RDWR);
		mc->p = checked_mmap(baseaddr, PS, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, dev_mem_fd, 0);
		checked_mmap(baseaddr + PS, PS, PROT_READ,
				     MAP_SHARED, dev_mem_fd, 0xf0000);
		checked_mmap(baseaddr + 2 * PS, PS, protflag,
				     MAP_PRIVATE|MAP_ANONYMOUS, dev_mem_fd, 0);
		break;
	}
}

static void access_memory2(struct mem_chunk *mc) {
	if (mc->mem_type == ZERO || mc->mem_type == HUGE_ZERO)
		read_memory(mc->p, mc->chunk_size);
	else if (mc->mem_type == DEVMEM) {
		memset(mc->p, 'a', PS);
		memset(mc->p + 2 * PS, 'a', PS);
	} else
		memset(mc->p, 'a', mc->chunk_size);
}

static void mmap_all_chunks(void) {
	int i, j = 0, k, backend;
	void *baseaddr;

	for_each_backend(backend) {
		for (i = 0; i < nr_chunk; i++) {
			k = i + j * nr_chunk;
			baseaddr = allocate_base + k * CHUNKSIZE * PS;
			/* printf("k %d, base %p\n", k, baseaddr); */

			chunkset[k].chunk_size = get_size_of_chunked_mmap_area(i);
			chunkset[k].mem_type = backend;

		/* printf("base:0x%lx, size:%lx\n", baseaddr, size); */
		/* p[i] = checked_mmap(baseaddr, size, protflag, mapflag, -1, 0); */
			prepare_memory2(&chunkset[k], baseaddr, i * CHUNKSIZE * PS);
			/* printf("p[%d]:%p + 0x%lx, btype %d\n", i, chunkset[k].p, */
			/*        chunkset[k].chunk_size, chunkset[k].mem_type); */
			access_memory2(&chunkset[k]);
		}
		j++;
	}
}

static void munmap_memory2(struct mem_chunk *mc) {
	if (mc->mem_type == HUGETLB_SHMEM || mc->mem_type == NORMAL_SHMEM)
		free_shmem2(mc);
	else if (mc->mem_type == DEVMEM) {
		checked_munmap(mc->p, 3 * PS);
	} else
		checked_munmap(mc->p, mc->chunk_size);
}

static void munmap_all_chunks(void) {
	int i, j;

	for (j = 0; j < nr_mem_types; j++)
		for (i = 0; i < nr_chunk; i++)
			munmap_memory2(&chunkset[i + j * nr_chunk]);
}

static void access_all_chunks() {
	int i, j;

	for (j = 0; j < nr_mem_types; j++)
		for (i = 0; i < nr_chunk; i++)
			access_memory2(&chunkset[i + j * nr_chunk]);
}

int do_work_memory2(int (*func)(char *p, int size, void *arg), void *args) {
	int i, j;
	int ret;

	for (j = 0; j < nr_mem_types; j++) {
		for (i = 0; i < nr_chunk; i++) {
			struct mem_chunk *tmp = &chunkset[i + j * nr_chunk];

			/* printf("%s, %d %d\n", __func__, i, j); */
			ret = (*func)(tmp->p, tmp->chunk_size, args);
			if (ret != 0)
				break;
		}
	}
	return ret;
}

/* #define mmap_all(p)	__mmap_all(p) */
/* #define munmap_all(p)	__munmap_all(p) */
/* #define access_all(p)	__access_all(p) */
/* #define do_work_memory(p, f, a)	__do_work_memory(p, f, a) */

#define mmap_all(p)	mmap_all_chunks()
#define munmap_all(p)	munmap_all_chunks()
#define access_all(p)	access_all_chunks()
#define do_work_memory(p, f, a)	do_work_memory2(f, a)

/*
 * Below here is exposed interface.
 */

extern void do_alloc_exit(void);
extern void do_memory_error_injection(void);
extern void do_injection(void);
extern void do_mmap_munmap_iteration(void);
extern void do_normal_allocation(void);
extern void do_multi_backend(void);


int hp_partial;

/*
 * Memory block size is 128MB (1 << 27) = 32k pages (1 << 15)
 */
#define MEMBLK_ORDER	15
#define MEMBLK_SIZE	(1 << MEMBLK_ORDER)
#define MAX_MEMBLK	1024

static void __busyloop(void) {
	pprintf("entering busy loop\n");
	if (busyloop)
		while (flag)
			access_all_chunks();
	else
		pause();
}

static int set_mempolicy_node(int mode, unsigned long nid) {
	/* Assuming that max node number is < 64 */
	unsigned long nodemask = 1UL << nid;
	if (mode == MPOL_DEFAULT)
		set_mempolicy(mode, NULL, nr_nodes);
	else
		set_mempolicy(mode, &nodemask, nr_nodes);
}

static void do_migratepages(void) {
	__busyloop();
}

struct mbind_arg {
	int mode;
	unsigned flags;
	struct bitmask *new_nodes;
};

static int __mbind_chunk(char *p, int size, void *args) {
	int i;
	struct mbind_arg *mbind_arg = (struct mbind_arg *)args;

	if (hp_partial) {
		for (i = 0; i < (size - 1) / 512 + 1; i++)
			mbind(p + i * HPS, PS,
			      mbind_arg->mode, mbind_arg->new_nodes->maskp,
			      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
	} else
		mbind(p, size,
		      mbind_arg->mode, mbind_arg->new_nodes->maskp,
		      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
}

static void do_mbind(void) {
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
	ret = do_work_memory2(__mbind_chunk, (void *)&mbind_arg);
	if (ret == -1) {
		perror("mbind");
		pprintf("mbind failed\n");
		pause();
		/* return; */
	}

	__busyloop();
}

static void initialize_random(void) {
	struct timeval tv;

	gettimeofday(&tv, NULL);
	srandom(tv.tv_usec);
}

static int __mbind_fuzz_chunk(char *p, int size, void *args) {
	struct mbind_arg *mbind_arg = (struct mbind_arg *)args;
	int node = random() % nr_nodes;
	unsigned long offset = (random() % nr_p) * PS;
	unsigned long length = (random() % (nr_p - offset / PS)) * PS;

	printf("%p: node:%x, offset:%x, length:%x\n", p, node, offset, length);
	numa_bitmask_setbit(mbind_arg->new_nodes, node);

	mbind(p + offset, size + length, mbind_arg->mode,
	      mbind_arg->new_nodes->maskp,
	      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
}

static void __do_mbind_fuzz(void) {
	int i;
	int ret;
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
	};

	initialize_random();

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);

	/* TODO: more race consideration, chunk, busyloop case? */
	pprintf("doing mbind_fuzz\n");
	while (flag) {
		ret = do_work_memory2(__mbind_fuzz_chunk, (void *)&mbind_arg);
		if (ret == -1) {
			perror("mbind_fuzz");
			pprintf("mbind_fuzz failed\n");
		}
	}
}

static void do_mbind_fuzz(void) {
	mmap_all_chunks();
	__do_mbind_fuzz();
	munmap_all_chunks();
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

static void do_move_pages(void) {
	int ret;

	pprintf("call move_pages()\n");
	ret = do_work_memory2(__move_pages_chunk, NULL);
	if (ret == -1) {
		perror("move_pages");
		pprintf("move_pages failed\n");
		pause();
		/* return; */
	}

	__busyloop();
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
static int memblock_check(void) {
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

static void do_hotremove(void) {
	int pmemblk; /* preferred memory block for hotremove */

	if (set_mempolicy_node(MPOL_PREFERRED, 1) == -1)
		err("set_mempolicy(MPOL_PREFERRED) to 1");

	pmemblk = memblock_check();

	/* pass pmemblk into control script */
	pprintf("before memory_hotremove: %d\n", pmemblk);
	pause();

	__busyloop();
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

static void do_madv_soft(void) {
	int ret;
	int loop = 10;
	int do_unpoison = 1;

	pprintf("call madvise(MADV_SOFT_OFFLINE)\n");
	ret = do_work_memory2(__madv_soft_chunk, NULL);
	if (ret == -1) {
		perror("madvise(MADV_SOFT_OFFLINE)");
		pprintf("madvise(MADV_SOFT_OFFLINE) failed\n");
		pause();
		/* return; */
	}

	__busyloop();
}

static void do_auto_numa(void) {
	int ret;
	struct bitmask *new_cpus = numa_bitmask_alloc(numa_num_configured_cpus());

	if (numa_node_to_cpus(1, new_cpus))
		err("numa_node_to_cpus");

	if (numa_sched_setaffinity(0, new_cpus))
		err("numa_sched_setaffinity");
	printf("sched_setaffinity to node 1\n");

	__busyloop();
}

static void do_change_cpuset(void) {
	__busyloop();
}

static void mmap_all_chunks_numa(void) {
	struct bitmask *init_cpus = numa_bitmask_alloc(numa_num_configured_cpus());

	/*
	 * All migration testing assume that data is migrated from node 0
	 * to node 1, and some testcase like auto numa need to locate running
	 * CPU to some node, so let's assign affined CPU to node 0 too.
	 */
	if (numa_node_to_cpus(0, init_cpus))
		err("numa_node_to_cpus");

	if (numa_sched_setaffinity(0, init_cpus))
		err("numa_sched_setaffinity");

	/* node 0 is preferred */
	if (set_mempolicy_node(mpol_mode_for_page_migration, 0) == -1)
		errmsg("set_mempolicy(%lx) to 0", mpol_mode_for_page_migration);

	mmap_all_chunks();

	if (set_mempolicy_node(MPOL_DEFAULT, 0) == -1)
		err("set_mempolicy to MPOL_DEFAULT");
}

void __do_page_migration(void) {
	switch (migration_src) {
	case MS_MIGRATEPAGES:
		do_migratepages();
		break;
	case MS_MBIND:
		do_mbind();
		break;
	case MS_MOVE_PAGES:
		do_move_pages();
		break;
	case MS_HOTREMOTE:
		do_hotremove();
		break;
	case MS_MADV_SOFT:
		do_madv_soft();
		break;
	case MS_AUTO_NUMA:
		do_auto_numa();
		break;
	case MS_CHANGE_CPUSET:
		do_change_cpuset();
		break;
	}
}

void do_page_migration(void) {
	mmap_all_chunks_numa();
	pprintf("page_fault_done\n");
	pause();
	__do_page_migration();
	pprintf("exited busy loop\n");
	pause();
	munmap_all_chunks();
}

static int __process_vm_access_chunk(char *p, int size, void *args) {
	int i;
	struct iovec local[1024];
	struct iovec remote[1024];
	ssize_t nread;
	pid_t pid = *(pid_t *)args;

	for (i = 0; i < size / HPS; i++) {
		local[i].iov_base = p + i * HPS;
		local[i].iov_len = HPS;
		remote[i].iov_base = p + i * HPS;
		remote[i].iov_len = HPS;
	}
	nread = process_vm_readv(pid, local, size / HPS, remote, size / HPS, 0);
	/* printf("0x%lx bytes read, p[0] = %c\n", nread, p[0]); */
}

void __do_process_vm_access(void) {
	int ret;
	pid_t pid;

	/* node 0 is preferred */
	if (set_mempolicy_node(MPOL_PREFERRED, 0) == -1)
		err("set_mempolicy(MPOL_PREFERRED) to 0");

	pid = fork();

	if (!pid) {
		/* Expecting COW, but it doesn't happend in zero page */
		access_all_chunks();
		pause();
		return;
	}

	pprintf("parepared_for_process_vm_access\n");
	pause();

	ret = do_work_memory2(__process_vm_access_chunk, &pid);
	if (ret == -1) {
		perror("mlock");
		pprintf("mlock failed\n");
		pause();
		/* return; */
	}

	pprintf("exit\n");
	pause();
}

void do_process_vm_access(void) {
	mmap_all_chunks();
	__do_process_vm_access();
	munmap_all_chunks();
}

static int __mlock_chunk(char *p, int size, void *args) {
	int i;

	if (hp_partial) {
		for (i = 0; i < (size - 1) / 512 + 1; i++)
			mlock(p + i * HPS, PS);
	} else
		mlock(p, size);
}

void __do_mlock(void) {
	int ret;
	pid_t pid;

	pprintf("page_fault_done\n");
	pause();

	if (forkflag) {
		pid = fork();

		if (!pid) {
			access_all_chunks();
			pause();
			return;
		}
		printf("forked\n");
	}

	ret = do_work_memory2(__mlock_chunk, NULL);
	if (ret == -1) {
		perror("mlock");
		pprintf("mlock failed\n");
		pause();
		/* return; */
	}

	pprintf("entering busy loop\n");
	if (busyloop)
		while (flag)
			access_all_chunks();
	else
		pause();
}

void do_mlock(void) {
	mmap_all_chunks();
	__do_mlock();
	munmap_all_chunks();
}

static int __mprotect_chunk(char *p, int size, void *args) {
	int i;

	if (hp_partial) {
		for (i = 0; i < (size - 1) / 512 + 1; i++)
			mprotect(p + i * HPS, PS, protflag|PROT_EXEC);
	} else
		mprotect(p, size, protflag|PROT_EXEC);
}

void __do_mprotect(void) {
	int ret;
	pid_t pid;

	pprintf("page_fault_done\n");
	pause();

	if (forkflag) {
		pid = fork();

		if (!pid) {
			access_all_chunks();
			pause();
			return;
		}
		printf("forked\n");
	}

	ret = do_work_memory2(__mprotect_chunk, NULL);
	if (ret == -1) {
		perror("mprotect");
		pprintf("mprotect failed\n");
		pause();
		/* return; */
	}

	pprintf("entering busy loop\n");
	if (busyloop)
		while (flag)
			access_all_chunks();
	else
		pause();
}

void do_mprotect(void) {
	int ret;
	pid_t pid;

	mmap_all_chunks();
	__do_mprotect();
	munmap_all_chunks();
}
