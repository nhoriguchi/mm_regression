#include <sys/uio.h>
#include <sys/time.h>
#include <stdlib.h>
#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"
#include "test_core/lib/pfn.h"

int flag = 1;

void sig_handle(int signo) { ; }

#define ADDR_INPUT 0x700000000000

/* for multi_backend operation */
void *allocate_base = (void *)ADDR_INPUT;

unsigned long nr_nodes;
unsigned long nodemask;

#define BUFNR 0x10000 /* 65536 */
#define CHUNKSIZE 0x1000 /* 4096 pages */

int protflag = PROT_READ|PROT_WRITE;

int nr_p = 512;
int nr_chunk = 1;

char *workdir = "work";
char *filebase = "testfile";
int fd;
int hugetlbfd;

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

struct op_control {
	char *name;
	int wait_before;
	int wait_after;
	char *tag;
	char **args;
	char **keys;
	char **values;
	int nr_args;
};

struct backend {
	int type;
	int npages;
	char *file;
};

/*
 * Return true if opc has an argument "key".
 */
static int opc_defined(struct op_control *opc, char *key) {
	int i;

	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->keys[i], key))
			return 1;
	}
	return 0;
}

static char *opc_get_value(struct op_control *opc, char *key) {
	int i;

	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->keys[i], key)) {
			if (!strcmp(opc->values[i], ""))
				return NULL;
			else
				return opc->values[i];
		}
	}
	return NULL;
}

static void print_opc(struct op_control *opc) {
	int i;

	Dprintf("===> op_name:%s", opc->name);
	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->values[i], ""))
			Dprintf(", %s", opc->keys[i]);
		else
			Dprintf(", %s=%s", opc->keys[i], opc->values[i]);
	}
	Dprintf("\n");
}

static char *opc_set_value(struct op_control *opc, char *key, char *value) {
	int i;

	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->keys[i], key)) {
			/* existing value is overwritten */
			/* TODO: error check? */
			return strcpy(opc->values[i], value);
		}
	}
	/* key not found in existing args, so new arg is added */
	/* TODO: remove arg? */
	opc->keys[i] = calloc(1, 64);
	opc->values[i] = calloc(1, 64);
	opc->nr_args++;
	strcpy(opc->keys[i], key);
	strcpy(opc->values[i], value);
	return NULL;
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

static void read_memory(char *p, int size) {
	int i;
	char c;

	for (i = 0; i < size; i += PS) {
		c = p[i];
	}
}

static void create_workdir(char *dpath) {
	if (mkdir(dpath, 0700))
		if (errno != EEXIST) /* 'already exist' is ok */
			errmsg("failed to mkdir %s\n", dpath);
}

static void create_regular_file(void) {
	int i;
	char fpath[256];
	char buf[PS];

	create_workdir(workdir);
	sprintf(fpath, "%s/%s", workdir, filebase);

	Dprintf("%s: fpath %s\n", __func__, fpath);
	if(access(fpath, F_OK) != -1) {
		printf("%s: %s already exists.\n", __func__, fpath);
		fd = open(fpath, O_RDWR, 0755);
		if (fd == -1)
			err("open");
	} else {
		printf("%s: %s not found, now create it.\n", __func__, fpath);
		fd = open(fpath, O_CREAT|O_RDWR, 0755);
		if (fd == -1)
			err("open");
		memset(buf, 'a', PS);
		for (i = 0; i < nr_p; i++)
			write(fd, buf, PS);
		fsync(fd);
	}
}

/*
 * Assuming that hugetlbfs is mounted on @workdir/hugetlbfs. And cleanup is
 * supposed to be done by control scripts.
 */
static void create_hugetlbfs_file(void) {
	int i;
	char dpath[256];
	char fpath[256];
	char buf[PS];
	char *phugetlb;

	sprintf(dpath, "%s/hugetlbfs", workdir);
	sprintf(fpath, "%s/%s", dpath, filebase);
	create_workdir(dpath);
	hugetlbfd = open(fpath, O_CREAT|O_RDWR, 0755);
	if (hugetlbfd == -1)
		err("open");
	phugetlb = checked_mmap(NULL, nr_p * PS, protflag, MAP_SHARED,
				hugetlbfd, 0);
	memset(phugetlb, 'a', nr_p * PS);
	munmap(phugetlb, nr_p * PS);
}

static void *alloc_shmem(struct mem_chunk *mc, void *exp_addr, int hugetlb) {
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

static void free_shmem(struct mem_chunk *mc) {
	if (shmdt((const void *)mc->p))
		perror("Shmem detach failed.");
	shmctl(mc->shmkey, IPC_RMID, NULL);
}

static void prepare_memory(struct mem_chunk *mc, void *baseaddr,
			     unsigned long offset) {
	int dev_mem_fd;

	switch (mc->mem_type) {
	case PAGECACHE:
		mc->p = checked_mmap(baseaddr, mc->chunk_size, protflag,
				     MAP_SHARED, fd, offset);
		/* printf("open, fd %d, offset %lx, %p\n", fd, offset, mc->p); */
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
		 * multiple times, so controlling scruipt must cleanup shmems after
		 * running the testcase.
		 */
		mc->p = alloc_shmem(mc, baseaddr, 1);
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
		mc->p = alloc_shmem(mc, baseaddr, 0);
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

static void access_memory(struct mem_chunk *mc, char *type) {
	if (!type) { /* default access type of a given backend type */
		if (mc->mem_type == ZERO || mc->mem_type == HUGE_ZERO)
			read_memory(mc->p, mc->chunk_size);
		else if (mc->mem_type == DEVMEM) {
			memset(mc->p, 'a', PS);
			memset(mc->p + 2 * PS, 'a', PS);
		} else
			memset(mc->p, 'a', mc->chunk_size);
	} else if (!strcmp(type, "read")) {
		read_memory(mc->p, mc->chunk_size);
	} else if (!strcmp(type, "write")) {
		memset(mc->p, 'a', mc->chunk_size);
	}
}

static int check_memory(struct mem_chunk *mc) {
	uint64_t kpflags;
	char buf[2000];

	switch (mc->mem_type) {
	case KSM:
		printf("--- %d\n", getpid());
		sprintf(buf, "/src/linux-dev/tools/vm/page-types -p %d -Nrl -a 0x700000000+0x1000000 | head", getpid());
		/* printf("--2\n"); */
		system(buf);
		/* printf("--\n"); */
		/* get_pflags(mc->p, &kpflags, 1); */
		/* printf("flags: %s\n", kpflags); */
		;;;;
		break;
	}
}

static void do_mmap(struct op_control *opc) {
	int i, j = 0, k, backend;
	void *baseaddr;

	/* printf("backend %lx, nr_chunk %lx\n", backend, nr_chunk); */
	for_each_backend(backend) {
		for (i = 0; i < nr_chunk; i++) {
			k = i + j * nr_chunk;
			baseaddr = allocate_base + k * CHUNKSIZE * PS;

			chunkset[k].chunk_size = get_size_of_chunked_mmap_area(i);
			chunkset[k].mem_type = backend;

			prepare_memory(&chunkset[k], baseaddr, i * CHUNKSIZE * PS);
		}
		j++;
	}
}

/* TODO: using NR_<operation> for error message */
static int do_work_memory(int (*func)(struct mem_chunk *mc, void *arg),
			  void *args) {
	int i, j;
	int ret;

	for (j = 0; j < nr_mem_types; j++) {
		for (i = 0; i < nr_chunk; i++) {
			struct mem_chunk *tmp = &chunkset[i + j * nr_chunk];

			ret = (*func)(tmp, args);
			if (ret != 0) {
				char buf[64];
				sprintf(buf, "%p", func);
				perror(buf);
				break;
			}
		}
	}
	return ret;
}

struct munmap_arg {
	int hp_partial;
};

static int __munmap_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	int i;
	struct munmap_arg *munmap_arg = (struct munmap_arg *)args;

	if (mc->mem_type == HUGETLB_SHMEM || mc->mem_type == NORMAL_SHMEM)
		free_shmem(mc);
	else if (mc->mem_type == DEVMEM) {
		checked_munmap(p, 3 * PS);
	} else {
		if (munmap_arg->hp_partial)
			for (i = 0; i < (size - 1) / HPS + 1; i++)
				checked_munmap(p + i * HPS, 511 * PS);
		else
			checked_munmap(p, size);
	}
}

static void do_munmap(struct op_control *opc) {
	int i, j;
	/* useful to create fragmentation situation */
	struct munmap_arg munmap_arg = {
		.hp_partial = opc_defined(opc, "hp_partial"),
	};

	do_work_memory(__munmap_chunk, (void *)&munmap_arg);
}

static int do_access(void *ptr) {
	int i, j;
	struct op_control *opc = (struct op_control *)ptr;
	char *type = opc_get_value(opc, "type");
	int check = opc_defined(opc, "check");

	if (type && !strcmp(type, "read") && !strcmp(type, "write"))
		errmsg("invalid parameter access:type=%s\n", type);
	for (j = 0; j < nr_mem_types; j++)
		for (i = 0; i < nr_chunk; i++) {
			access_memory(&chunkset[i + j * nr_chunk], type);
			if (check)
				check_memory(&chunkset[i + j * nr_chunk]);
		}
}

static void do_busyloop(struct op_control *opc) {
	pprintf_wait_func(do_access, opc, "entering busy loop\n");
}

/* borrowed from ltp:testcases/kernel/mem/include/mem.h */
#define BITS_PER_LONG           (8 * sizeof(long))
#define MAXNODES		256
static inline void set_node(unsigned long *array, unsigned int node)
{
        array[node / BITS_PER_LONG] |= 1UL << (node % BITS_PER_LONG);
}

static int set_mempolicy_node(int mode, int nid) {
	unsigned long nmask[MAXNODES / BITS_PER_LONG] = { 0 };

	set_node(nmask, nid);
	if (mode == MPOL_DEFAULT)
		set_mempolicy(mode, NULL, MAXNODES);
	else
		set_mempolicy(mode, nmask, MAXNODES);
}

static int numa_sched_setaffinity_node(int nid) {
	struct bitmask *new_cpus = numa_bitmask_alloc(32);

	if (numa_node_to_cpus(nid, new_cpus))
		err("numa_node_to_cpus");

	if (numa_sched_setaffinity(0, new_cpus))
		err("numa_sched_setaffinity");

	numa_bitmask_free(new_cpus);
}

static void do_migratepages(struct op_control *opc) {
	pprintf_wait_func(opc_defined(opc, "busyloop") ? do_access : NULL, opc,
			  "waiting for migratepages\n");
}

struct mbind_arg {
	int mode;
	unsigned flags;
	struct bitmask *new_nodes;
	int hp_partial;
};

static int __mbind_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	int i;
	struct mbind_arg *mbind_arg = (struct mbind_arg *)args;

	if (mbind_arg->hp_partial) {
		for (i = 0; i < (size - 1) / HPS + 1; i++)
			mbind(p + i * HPS, PS,
			      mbind_arg->mode, mbind_arg->new_nodes->maskp,
			      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
	} else
		mbind(p, size,
		      mbind_arg->mode, mbind_arg->new_nodes->maskp,
		      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
}

/* TODO: make mode, nid configurable from caller */
static void do_mbind(struct op_control *opc) {
	char *tmp;
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
		.hp_partial = opc_defined(opc, "hp_partial"),
	};

	tmp = opc_get_value(opc, "flags");
	if (tmp && !strcmp(tmp, "move")) /* default on, so meaningless now */
		mbind_arg.flags |= MPOL_MF_MOVE;
	else if (tmp && !strcmp(tmp, "move_all")) {
		mbind_arg.flags &= ~MPOL_MF_MOVE;
		mbind_arg.flags |= MPOL_MF_MOVE_ALL;
	}

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);
	numa_bitmask_setbit(mbind_arg.new_nodes, 1);

	do_work_memory(__mbind_chunk, (void *)&mbind_arg);
}

static void initialize_random(void) {
	struct timeval tv;

	gettimeofday(&tv, NULL);
	srandom(tv.tv_usec);
}

static int __mbind_fuzz_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	struct mbind_arg *mbind_arg = (struct mbind_arg *)args;
	int node = random() % nr_nodes;
	unsigned long offset = (random() % nr_p) * PS;
	unsigned long length = (random() % (nr_p - offset / PS)) * PS;

	Dprintf("%p: node:%x, offset:%x, length:%x\n", p, node, offset, length);
	numa_bitmask_setbit(mbind_arg->new_nodes, node);

	mbind(p + offset, size + length, mbind_arg->mode,
	      mbind_arg->new_nodes->maskp,
	      mbind_arg->new_nodes->size + 1, mbind_arg->flags);
}

static void do_mbind_fuzz(struct op_control *opc) {
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
	};

	initialize_random();

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);

	/* TODO: more race consideration, chunk, busyloop case? */
	pprintf("doing mbind_fuzz\n");
	while (flag)
		do_work_memory(__mbind_fuzz_chunk, (void *)&mbind_arg);
}

static int __move_pages_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	int i;
	int node = *(int *)args;
	void *__move_pages_addrs[CHUNKSIZE + 1];
	int __move_pages_status[CHUNKSIZE + 1];
	int __move_pages_nodes[CHUNKSIZE + 1];

	for (i = 0; i < size / PS; i++) {
		__move_pages_addrs[i] = p + i * PS;
		__move_pages_nodes[i] = node;
		__move_pages_status[i] = 0;
	}
	numa_move_pages(0, size / PS, __move_pages_addrs, __move_pages_nodes,
			__move_pages_status, MPOL_MF_MOVE_ALL);
}

static void do_move_pages(struct op_control *opc) {
	int node = 1;

	do_work_memory(__move_pages_chunk, &node);
}

unsigned long memblk_order, memblk_size;

static unsigned long probe_memory_block_size() {
	FILE *f;
	char str[256];

	f = fopen("/sys/devices/system/memory/block_size_bytes", "r");
	while (fgets(str, 256, f)) {
		sscanf(str, "%lx", &memblk_size);
	}
	return memblk_size;
}

static unsigned long get_memblk_size() {
	if (!memblk_size)
		memblk_size = probe_memory_block_size();
	return memblk_size;
}

static unsigned long get_memblk_order() {
	if (!memblk_order){
		unsigned long i;
		unsigned long size = get_memblk_size();

		for (i = 0; i < 64; i++) {
			if ((size >> i) == 1) {
				memblk_order = i;
				break;
			}
		}
	}
	return memblk_order;
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
	/* Values in /proc/zoneinfo is in page size unit */
	return (spanned + start_pfn) >> (get_memblk_order() - PAGE_SHIFT);
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
	uint64_t *pageflags;
	int pmemblk = -1;
	int max_matched_pages = 0;
	int compound = check_compound();
	unsigned long _memblk_size = get_memblk_size() >> PAGE_SHIFT;

	pageflags = malloc(_memblk_size * sizeof(uint64_t));

	kpageflags_fd = open("/proc/kpageflags", O_RDONLY);
	for (i = 2; i < max_memblock; i++) {
		int pfn = i * _memblk_size;
		int matched = 0;

		ret = kpageflags_read(pageflags, pfn, _memblk_size);
		for (j = 0; j < _memblk_size; j++) {
			if (bit_mask_ok(pageflags[j])) {
				if (compound)
					matched += 512;
				else
					matched++;
			}
		}
		printf("memblock:%d, readret:%d matched:%d (%d%), 1:%lx, 2:%lx\n",
		       i, ret, matched, matched*100/_memblk_size,
		       pageflags[0], pageflags[1]);
		if (max_matched_pages < matched) {
			max_matched_pages = matched;
			pmemblk = i;
			if (matched == _memblk_size) /* full of target pages */
				break;
		}
	}
	if (pmemblk == -1)
		errmsg("%s: failed to get perferred memblock for given pageflag set %lx\n", __func__, pageflags[j]);
	close(kpageflags_fd);
	free(pageflags);

	return pmemblk;
}

static void do_hotremove(struct op_control *opc) {
	int pmemblk; /* preferred memory block for hotremove */
	char *pageflags = opc_get_value(opc, "pageflags");

	if (!pageflags)
		errmsg("hotremove:pageflags parameter not given\n");
	parse_bits_mask(pageflags);

	if (set_mempolicy_node(MPOL_PREFERRED, 1) == -1)
		err("set_mempolicy(MPOL_PREFERRED) to 1");

	pmemblk = memblock_check();
	pprintf_wait_func(opc_defined(opc, "busyloop") ? do_access : NULL, opc,
			  "waiting for memory_hotremove: %d\n", pmemblk);
}

static void do_auto_numa(struct op_control *opc) {
	numa_sched_setaffinity_node(1);
	pprintf_wait_func(opc_defined(opc, "busyloop") ? do_access : NULL, opc,
			  "waiting for auto_numa\n");
}

static void do_change_cpuset(struct op_control *opc) {
	pprintf_wait_func(opc_defined(opc, "busyloop") ? do_access : NULL, opc,
			  "waiting for change_cpuset\n");
}

static void do_mmap_numa(struct op_control *opc) {
	char *p_cpu = opc_get_value(opc, "preferred_cpu_node");
	char *p_mem = opc_get_value(opc, "preferred_mem_node");
	int preferred_cpu_node = -1; /* default (-1) means no preferred node */
	int preferred_mem_node = 0;

	if (p_cpu)
		preferred_cpu_node = strtol(p_cpu, NULL, 0);
	if (p_mem)
		preferred_mem_node = strtol(p_mem, NULL, 0);

	if (preferred_cpu_node != -1)
		numa_sched_setaffinity_node(preferred_cpu_node);

	if (set_mempolicy_node(MPOL_BIND, preferred_mem_node) == -1)
		err("set_mempolicy");

	do_mmap(opc);

	if (set_mempolicy_node(MPOL_DEFAULT, 0) == -1)
		err("set_mempolicy");
}

/* inject only onto the first page, so allocating big region makes no sense. */
static void do_memory_error_injection(struct op_control *opc) {
	char *error_type = opc_get_value(opc, "error_type");

	if (!error_type)
		errmsg("parameter error_type not given\n");

	if (!strcmp(error_type, "mce-srao")
	    || !strcmp(error_type, "hard-offline")
	    || !strcmp(error_type, "soft-offline")) {
		pprintf_wait_func(NULL, opc, "waiting for injection from outside\n");
	} else if (!strcmp(error_type, "madv_hard")
		   || !strcmp(error_type, "madv_soft")) {
		char rbuf[256];
		unsigned long offset = 0;
		int ret;

		pprintf_wait_func(NULL, opc, "error injection with madvise\n");
		pipe_read(rbuf);
		offset = strtol(rbuf, NULL, 0);
		Dprintf("madvise inject to addr %lx\n", chunkset[0].p + offset * PS);
		if ((ret = madvise(chunkset[0].p + offset * PS, PS,
				   !strcmp(error_type, "madv_hard") ?
				   MADV_HWPOISON : MADV_SOFT_OFFLINE)) != 0)
			perror("madvise");
		pprintf_wait_func(NULL, opc, "after madvise injection\n");
	} else {
		errmsg("unknown error_type: %s\n", error_type);
	}

	if (opc_defined(opc, "access_after_injection")) {
		pprintf_wait_func(NULL, opc, "writing affected region\n");
		do_access(opc);
	}
}

static int __mlock_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	int i;
	struct op_control *opc = (struct op_control *)args;

	if (opc_defined(opc, "hp_partial")) {
		for (i = 0; i < (size - 1) / HPS + 1; i++)
			mlock(p + i * HPS, PS);
	} else
		mlock(p, size);
}

static void do_mlock(struct op_control *opc) {
	do_work_memory(__mlock_chunk, opc);
}

/* only true for x86_64 */
#define __NR_mlock2 325

static int __mlock2_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	int i;
	struct op_control *opc = (struct op_control *)args;

	if (opc_defined(opc, "hp_partial")) {
		for (i = 0; i < (size - 1) / HPS + 1; i++)
			syscall(__NR_mlock2, p + i * HPS, PS, 1);
	} else
		syscall(__NR_mlock2, p, size, 1);
}

static void do_mlock2(struct op_control *opc) {
	do_work_memory(__mlock2_chunk, opc);
}

struct mprotect_arg {
	int permission;
	int hp_partial;
};

static int __mprotect_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	int i;
	int prot = protflag | PROT_EXEC;
	struct mprotect_arg *arg = (struct mprotect_arg *)args;

	if (arg->permission != -1)
		prot = arg->permission;

	if (arg->hp_partial) {
		for (i = 0; i < (size - 1) / HPS + 1; i++)
			mprotect(p + i * HPS, PS, prot);
	} else
		mprotect(p, size, prot);
}

static void do_mprotect(struct op_control *opc) {
	char *tmp;
	struct mprotect_arg mprotect_arg = {
		.permission = -1,
	};

	if (tmp = opc_get_value(opc, "hp_partial"))
		mprotect_arg.hp_partial = strtoul(tmp, NULL, 0);
	if (tmp = opc_get_value(opc, "permission"))
		mprotect_arg.permission = strtoul(tmp, NULL, 0);

	do_work_memory(__mprotect_chunk, &mprotect_arg);
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

struct memory_compaction_arg {
	size_t ram;
	size_t len;
	void *ptr;
};

static int __do_memory_compaction(void *args) {
	char *p;
	struct memory_compaction_arg *mc_arg = (struct memory_compaction_arg *)args;

	for (p = mc_arg->ptr;
	     (unsigned long)p < (unsigned long)mc_arg->ptr + mc_arg->len;
	     p += THPS) {
		allocate_transhuge(p);
		/* split transhuge page, keep last page */
		if (madvise(p, THPS - PAGE_SIZE, MADV_DONTNEED))
			err("MADV_DONTNEED");
	}
}

static void do_memory_compaction(struct op_control *opc) {
	struct memory_compaction_arg mc_arg = {
		.ram = 0,
	};

	mc_arg.ram = sysconf(_SC_PHYS_PAGES);
	if (mc_arg.ram > SIZE_MAX / sysconf(_SC_PAGESIZE) / 4)
		mc_arg.ram = SIZE_MAX / 4;
	else
		mc_arg.ram *= sysconf(_SC_PAGESIZE);
	mc_arg.len = mc_arg.ram;
	mc_arg.len -= mc_arg.len % THPS;
	mc_arg.ptr = mmap((void *)ADDR_INPUT, mc_arg.len + THPS,
			  PROT_READ | PROT_WRITE,
			  MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE, -1, 0);

	if (madvise(mc_arg.ptr, mc_arg.len, MADV_HUGEPAGE))
		err("MADV_HUGEPAGE");

	pprintf_wait_func(__do_memory_compaction, &mc_arg,
			  "now doing memory compaction\n");
}

static void do_allocate_more(struct op_control *opc) {
	char *panon;
	int size = nr_p * PS;

	panon = checked_mmap((void *)(ADDR_INPUT + size), size, MMAP_PROT,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	/* should cause swap out with external cgroup setting */
	pprintf("anonymous address starts at %p\n", panon);
	memset(panon, 'a', size);
}

static void do_fork_stress(struct op_control *opc) {
	while (flag) {
		pid_t pid = fork();
		if (!pid) {
			do_access(opc);
			return;
		}
		/* get status? */
		waitpid(pid, NULL, 0);
	}
}

static int __mremap_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	int offset = nr_chunk * CHUNKSIZE * PS;
	int back = *(int *)args; /* 0: +offset, 1: -offset*/
	void *new;

	if (back) {
		Dprintf("mremap p:%p+%lx -> %p\n", p + offset, size, p);
		new = mremap(p + offset, size, size, MREMAP_MAYMOVE|MREMAP_FIXED, p);
	} else {
		Dprintf("mremap p:%p+%lx -> %p\n", p, size, p + offset);
		new = mremap(p, size, size, MREMAP_MAYMOVE|MREMAP_FIXED, p + offset);
	}
	return new == MAP_FAILED ? -1 : 0;
}

static void do_mremap_stress(struct op_control *opc) {
	while (flag) {
		int back = 0;

		back = 0;
		do_work_memory(__mremap_chunk, (void *)&back);

		back = 1;
		do_work_memory(__mremap_chunk, (void *)&back);
	}
}

static void do_mremap(struct op_control *opc) {
	int back = 0;
	do_work_memory(__mremap_chunk, (void *)&back);
}

static void do_iterate_mapping(struct op_control *opc) {
	while (flag) {
		do_mmap(opc);
		do_access(opc);
		do_munmap(opc);
	}
}

static int iterate_mbind_pingpong(void *arg) {
	struct mbind_arg *mbind_arg = (struct mbind_arg *)arg;

	numa_bitmask_clearall(mbind_arg->new_nodes);
	numa_bitmask_setbit(mbind_arg->new_nodes, 1);
	do_work_memory(__mbind_chunk, mbind_arg);

	numa_bitmask_clearall(mbind_arg->new_nodes);
	numa_bitmask_setbit(mbind_arg->new_nodes, 0);
	do_work_memory(__mbind_chunk, mbind_arg);
}

static void do_mbind_pingpong(struct op_control *opc) {
	struct mbind_arg mbind_arg = {
		.mode = MPOL_BIND,
		.flags = MPOL_MF_MOVE|MPOL_MF_STRICT,
	};

	mbind_arg.new_nodes = numa_bitmask_alloc(nr_nodes);

	pprintf_wait_func(iterate_mbind_pingpong, &mbind_arg,
			  "entering iterate_mbind_pingpong\n");
}

static void do_move_pages_pingpong(struct op_control *opc) {
	while (flag) {
		int node;

		node = 1;
		do_work_memory(__move_pages_chunk, &node);

		node = 0;
		do_work_memory(__move_pages_chunk, &node);
	}
}

static pid_t do_fork(struct op_control *opc) {
	pid_t pid = fork();

	if (!pid) {
		opc->name = "access";
		opc->wait_after = 1;
		opc_set_value(opc, "type", "read");
		testpipe = NULL;
		do_access(opc);
		return 0;
	}

	return pid;
}

/* TODO: chunk should be thp */
static int __do_split_thp_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	int i;

	for (i = 0; i * THPS < size; i++)
		madvise(p + i * THPS, PS, MADV_DONTNEED);
}

static void do_split_thp(struct op_control *opc) {
	if (opc_defined(opc, "only_pmd"))
		do_work_memory(__do_split_thp_chunk, opc);
	else if (1) {
		system("echo 1 > /sys/kernel/debug/split_huge_pages");
	} else {
		opc_set_value(opc, "hp_partial", "");
		do_mbind(opc);
	}
}

struct madvise_arg {
	int advice;
	int size;
	int hp_partial;

	int offset;
	int length;
	int step;
};

static int __do_madvise_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
	struct madvise_arg *madv_arg = (struct madvise_arg *)args;
	int i;
	int ret;

	if (madv_arg->size) {
		ret = madvise(p, madv_arg->size,
			      madv_arg->advice);
		if (ret)
			return ret;
	} else if (madv_arg->hp_partial) {
		for (i = 0; i < (size - 1) / HPS + 1; i++) {
			ret = madvise(p + i * HPS, madv_arg->hp_partial * PS,
					madv_arg->advice);
			if (ret)
				return ret;
		}
		return 0;
	} else if (madv_arg->offset || madv_arg->length || madv_arg->step) {
		i = madv_arg->offset;
		while (1) {
			int tmplen = madv_arg->length * PS;

			if (i * PS + tmplen > size)
				tmplen = size - i * PS;
			ret = madvise(p + i * PS, tmplen, madv_arg->advice);
			if (ret)
				return ret;
			if (madv_arg->step == 0)
				break;
			i += madv_arg->step;
			if (i * PS > size)
				break;
		}
		return 0;
	} else {
		return madvise(p, size, madv_arg->advice);
	}
}

/* this new feature might not be available in distro's header */
#define MADV_FREE	8

static void do_madvise(struct op_control *opc) {
	char *tmp;
	struct madvise_arg madv_arg = {};

	tmp = opc_get_value(opc, "advice");
	if (!tmp)
		errmsg("%s need to set advice:MADV_*\n", __func__);
	if (!strcmp(tmp, "normal"))
		madv_arg.advice = MADV_NORMAL;
	else if (!strcmp(tmp, "random"))
		madv_arg.advice = MADV_RANDOM;
	else if (!strcmp(tmp, "sequential"))
		madv_arg.advice = MADV_SEQUENTIAL;
	else if (!strcmp(tmp, "willneed"))
		madv_arg.advice = MADV_WILLNEED;
	else if (!strcmp(tmp, "dontneed"))
		madv_arg.advice = MADV_DONTNEED;
	else if (!strcmp(tmp, "free"))
		madv_arg.advice = MADV_FREE;
	else if (!strcmp(tmp, "remove"))
		madv_arg.advice = MADV_REMOVE;
	else if (!strcmp(tmp, "dontfork"))
		madv_arg.advice = MADV_DONTFORK;
	else if (!strcmp(tmp, "fork"))
		madv_arg.advice = MADV_DOFORK;
	else if (!strcmp(tmp, "hwpoison") || !strcmp(tmp, "hard_offline"))
		madv_arg.advice = MADV_HWPOISON;
	else if (!strcmp(tmp, "soft_offline"))
		madv_arg.advice = MADV_SOFT_OFFLINE;
	else if (!strcmp(tmp, "mergeable"))
		madv_arg.advice = MADV_MERGEABLE;
	else if (!strcmp(tmp, "unmergeable"))
		madv_arg.advice = MADV_UNMERGEABLE;
	else if (!strcmp(tmp, "hugepage"))
		madv_arg.advice = MADV_HUGEPAGE;
	else if (!strcmp(tmp, "nohugepage"))
		madv_arg.advice = MADV_NOHUGEPAGE;
	else if (!strcmp(tmp, "dontdump"))
		madv_arg.advice = MADV_DONTDUMP;
	else if (!strcmp(tmp, "dodump"))
		madv_arg.advice = MADV_DODUMP;
	else
		errmsg("unsupported madvice: %s\n", tmp);

	if (tmp = opc_get_value(opc, "size"))
		madv_arg.size = strtoul(tmp, NULL, 0);

	if (tmp = opc_get_value(opc, "hp_partial"))
		madv_arg.hp_partial = strtoul(tmp, NULL, 0);

	if (tmp = opc_get_value(opc, "offset"))
		madv_arg.offset = strtoul(tmp, NULL, 0);
	if (tmp = opc_get_value(opc, "length"))
		madv_arg.length = strtoul(tmp, NULL, 0);
	if (tmp = opc_get_value(opc, "step"))
		madv_arg.step = strtoul(tmp, NULL, 0);

	do_work_memory(__do_madvise_chunk, &madv_arg);
}

/* unpoison option? */
static void do_madv_soft(struct op_control *opc) {
	/* int loop = 10; */
	/* int do_unpoison = 1; */
	opc_set_value(opc, "advice", "soft_offline");
	opc_set_value(opc, "size", "4096");
	do_madvise(opc);
}

static void do_iterate_fault_dontneed(struct op_control *opc) {
	do_mmap(opc);
	opc_set_value(opc, "advice", "dontneed");
	while (flag) {
		do_access(opc);
		do_madvise(opc);
	}
}

static int __process_vm_access_chunk(struct mem_chunk *mc, void *args) {
	char *p = mc->p;
	int size = mc->chunk_size;
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

static void do_process_vm_access(struct op_control *opc) {
	pid_t pid;

	pid = do_fork(opc);
	/* TODO: this waiting is not beautiful, need update */
	pprintf_wait_func(opc_defined(opc, "busyloop") ? do_access : NULL, opc,
			  "waiting for process_vm_access\n");
	do_work_memory(__process_vm_access_chunk, &pid);
}

static void do_vm86(struct op_control *opc) {
	pid_t pid;
	return;
}

enum {
	NR_start,
	NR_noop,
	NR_exit,
	NR_mmap,
	NR_mmap_numa,
	NR_access,
	NR_busyloop,
	NR_munmap,
	NR_mbind,
	NR_move_pages,
	NR_mlock,
	NR_mlock2,
	NR_memory_error_injection,
	NR_auto_numa,
	NR_mprotect,
	NR_change_cpuset,
	NR_migratepages,
	NR_memory_compaction,
	NR_allocate_more,
	NR_madv_soft,
	NR_iterate_mapping,
	NR_iterate_fault_dontneed,
	NR_mremap,
	NR_mremap_stress,
	NR_hotremove,
	NR_process_vm_access,
	NR_fork_stress,
	NR_mbind_pingpong,
	NR_move_pages_pingpong,
	NR_mbind_fuzz,
	NR_fork,
	NR_split_thp,
	NR_madvise,
	NR_vm86,
	NR_OPERATIONS,
};

static const char *operation_name[] = {
	[NR_start]			= "start",
	[NR_noop]			= "noop",
	[NR_exit]			= "exit",
	[NR_mmap]			= "mmap",
	[NR_mmap_numa]			= "mmap_numa",
	[NR_access]			= "access",
	[NR_busyloop]			= "busyloop",
	[NR_munmap]			= "munmap",
	[NR_mbind]			= "mbind",
	[NR_move_pages]			= "move_pages",
	[NR_mlock]			= "mlock",
	[NR_mlock2]			= "mlock2",
	[NR_memory_error_injection]	= "memory_error_injection",
	[NR_auto_numa]			= "auto_numa",
	[NR_mprotect]			= "mprotect",
	[NR_change_cpuset]		= "change_cpuset",
	[NR_migratepages]		= "migratepages",
	[NR_memory_compaction]		= "memory_compaction",
	[NR_allocate_more]		= "allocate_more",
	[NR_madv_soft]			= "madv_soft",
	[NR_iterate_mapping]		= "iterate_mapping",
	[NR_iterate_fault_dontneed]	= "iterate_fault_dontneed",
	[NR_mremap]			= "mremap",
	[NR_mremap_stress]		= "mremap_stress",
	[NR_hotremove]			= "hotremove",
	[NR_process_vm_access]		= "process_vm_access",
	[NR_fork_stress]		= "fork_stress",
	[NR_mbind_pingpong]		= "mbind_pingpong",
	[NR_move_pages_pingpong]	= "move_pages_pingpong",
	[NR_mbind_fuzz]			= "mbind_fuzz",
	[NR_fork]			= "fork",
	[NR_split_thp]			= "split_thp",
	[NR_madvise]			= "madvise",
	[NR_vm86]			= "vm86",
};

/*
 * TODO: hp_partial is relevant only for hugetlb/thp, so backend type check
 * should be useful.
 */
static const char *op_supported_args[][10] = {
	[NR_start]			= {},
	[NR_noop]			= {},
	[NR_exit]			= {},
	[NR_mmap]			= {},
	[NR_mmap_numa]			= {"preferred_cpu_node", "preferred_mem_node"},
	[NR_access]			= {"type", "check"},
	[NR_busyloop]			= {"type"},
	[NR_munmap]			= {"hp_partial"},
	[NR_mbind]			= {"hp_partial", "flags"},
	[NR_move_pages]			= {},
	[NR_mlock]			= {"hp_partial"},
	[NR_mlock2]			= {"hp_partial"},
	[NR_memory_error_injection]	= {"error_type", "access_after_injection"},
	[NR_auto_numa]			= {"busyloop"},
	[NR_mprotect]			= {"hp_partial", "permission"},
	[NR_change_cpuset]		= {"busyloop"},
	[NR_migratepages]		= {"busyloop"},
	[NR_memory_compaction]		= {},
	[NR_allocate_more]		= {},
	[NR_madv_soft]			= {},
	[NR_iterate_mapping]		= {},
	[NR_iterate_fault_dontneed]	= {},
	[NR_mremap]			= {},
	[NR_mremap_stress]		= {},
	[NR_hotremove]			= {"busyloop", "pageflags"},
	[NR_process_vm_access]		= {"busyloop"},
	[NR_fork_stress]		= {},
	[NR_mbind_pingpong]		= {},
	[NR_move_pages_pingpong]	= {},
	[NR_mbind_fuzz]			= {},
	[NR_fork]			= {},
	[NR_split_thp]			= {"only_pmd"},
	[NR_madvise]			= {"advice", "size", "hp_partial", "offset", "length", "step"},
	[NR_vm86]			= {},
};

static int get_op_index(struct op_control *opc) {
	int i;

	for (i = 0; i < NR_OPERATIONS; i++)
		if (!strcmp(operation_name[i], opc->name))
			return i;
}

static int parse_operation_arg(struct op_control *opc) {
	int i, j;
	int supported;
	int op_idx = get_op_index(opc);

	for (i = 0; i < opc->nr_args; i++) {
		opc->keys[i] = calloc(1, 64);
		opc->values[i] = calloc(1, 64);

		sscanf(opc->args[i], "%[^=]=%s", opc->keys[i], opc->values[i]);

		if (!strcmp(opc->keys[i], "wait_before")) {
			opc->wait_before = 1;
			continue;
		}
		if (!strcmp(opc->keys[i], "wait_after")) {
			opc->wait_after = 1;
			continue;
		}
		if (!strcmp(opc->keys[i], "tag")) {
			opc->tag = opc->values[i];
			continue;
		}

		supported = 0;
		j = 0;
		while (op_supported_args[op_idx][j]) {
			if (!strcmp(op_supported_args[op_idx][j], opc->keys[i])) {
				supported = 1;
				break;
			}
			j++;
		}
		if (!supported)
			errmsg("operation %s does not support argument %s\n",
			       opc->name, opc->keys[i]);
	}
	return 0;
}

char *op_args[256];
static void parse_operation_args(struct op_control *opc, char *str) {
	char delimiter[] = ":";
	char *ptr;
	int i = 0, j, k;
	char buf[256];

	memset(opc, 0, sizeof(struct op_control));
	strcpy(buf, str);

	/* TODO: need overrun check */
	opc->name = malloc(256);
	opc->args = malloc(10 * sizeof(void *));
	opc->keys = malloc(10 * sizeof(void *));
	opc->values = malloc(10 * sizeof(void *));

	ptr = strtok(buf, delimiter);
	strcpy(opc->name, ptr);
	while (1) {
		ptr = strtok(NULL, delimiter);
		if (!ptr)
			break;
		opc->args[i++] = ptr;
	}
	opc->nr_args = i;

	parse_operation_arg(opc);
	print_opc(opc);
}

static void need_numa() {
	if (nr_nodes < 2)
		errmsg("A minimum of 2 nodes is required for this test.\n");
}

static void do_wait_before(struct op_control *opc) {
	char *sleep = opc_get_value(opc, "wait_before");
	char wait_key_string[256];

	if (opc->tag)
		sprintf(wait_key_string, "before_%s_%s", opc->name, opc->tag);
	else
		sprintf(wait_key_string, "before_%s", opc->name);

	if (sleep) {
		unsigned int sleep_us = strtoul(sleep, NULL, 0);

		printf("wait %d usecs %s\n", sleep_us, wait_key_string);
		usleep(sleep_us);
	}
	pprintf_wait(SIGUSR1, "%s\n", wait_key_string);
}

static void do_wait_after(struct op_control *opc) {
	char *sleep = opc_get_value(opc, "wait_after");
	char wait_key_string[256];

	if (opc->tag)
		sprintf(wait_key_string, "after_%s_%s", opc->name, opc->tag);
	else
		sprintf(wait_key_string, "after_%s", opc->name);

	if (sleep) {
		unsigned int sleep_us = strtoul(sleep, NULL, 0);

		printf("wait %d usecs %s\n", sleep_us, wait_key_string);
		usleep(sleep_us);
	}
	pprintf_wait(SIGUSR1, "%s\n", wait_key_string);
}

char *op_strings[256];

static void do_operation_loop(void) {
	int i;
	struct op_control opc;

	for (i = 0; op_strings[i] > 0; i++) {
		parse_operation_args(&opc, op_strings[i]);

		if (opc.wait_before)
			do_wait_before(&opc);

		if (!strcmp(opc.name, "start")) {
			;
		} else if (!strcmp(opc.name, "noop")) {
			;
		} else if (!strcmp(opc.name, "exit")) {
			;
		} else if (!strcmp(opc.name, "mmap")) {
			do_mmap(&opc);
		} else if (!strcmp(opc.name, "mmap_numa")) {
			/* need_numa(); */
			do_mmap_numa(&opc);
		} else if (!strcmp(opc.name, "access")) {
			do_access(&opc);
		} else if (!strcmp(opc.name, "busyloop")) {
			do_busyloop(&opc);
		} else if (!strcmp(opc.name, "munmap")) {
			do_munmap(&opc);
		} else if (!strcmp(opc.name, "mbind")) {
			do_mbind(&opc);
		} else if (!strcmp(opc.name, "move_pages")) {
			do_move_pages(&opc);
		} else if (!strcmp(opc.name, "mlock")) {
			do_mlock(&opc);
		} else if (!strcmp(opc.name, "mlock2")) {
			do_mlock2(&opc);
		} else if (!strcmp(opc.name, "memory_error_injection")) {
			do_memory_error_injection(&opc);
		} else if (!strcmp(opc.name, "auto_numa")) {
			do_auto_numa(&opc);
		} else if (!strcmp(opc.name, "mprotect")) {
			do_mprotect(&opc);
		} else if (!strcmp(opc.name, "change_cpuset")) {
			do_change_cpuset(&opc);
		} else if (!strcmp(opc.name, "migratepages")) {
			do_migratepages(&opc);
		} else if (!strcmp(opc.name, "memory_compaction")) {
			do_memory_compaction(&opc);
		} else if (!strcmp(opc.name, "allocate_more")) {
			do_allocate_more(&opc);
		} else if (!strcmp(opc.name, "madv_soft")) {
			do_madv_soft(&opc);
		} else if (!strcmp(opc.name, "iterate_mapping")) {
			do_iterate_mapping(&opc);
		} else if (!strcmp(opc.name, "iterate_fault_dontneed")) {
			do_iterate_fault_dontneed(&opc);
		} else if (!strcmp(opc.name, "mremap")) {
			do_mremap(&opc);
		} else if (!strcmp(opc.name, "mremap_stress")) {
			do_mremap_stress(&opc);
		} else if (!strcmp(opc.name, "hotremove")) {
			do_hotremove(&opc);
		} else if (!strcmp(opc.name, "process_vm_access")) {
			do_process_vm_access(&opc);
		} else if (!strcmp(opc.name, "fork_stress")) {
			do_fork_stress(&opc);
		} else if (!strcmp(opc.name, "mbind_pingpong")) {
			do_mbind_pingpong(&opc);
		} else if (!strcmp(opc.name, "move_pages_pingpong")) {
			do_move_pages_pingpong(&opc);
		} else if (!strcmp(opc.name, "mbind_fuzz")) {
			do_mbind_fuzz(&opc);
		} else if (!strcmp(opc.name, "fork")) {
			do_fork(&opc);
		} else if (!strcmp(opc.name, "split_thp")) {
			do_split_thp(&opc);
		} else if (!strcmp(opc.name, "madvise")) {
			do_madvise(&opc);
		} else if (!strcmp(opc.name, "vm86")) {
			do_vm86(&opc);
		} else
			errmsg("unsupported op_string: %s\n", opc.name);

		if (opc.wait_after)
			do_wait_after(&opc);
	}
}

static void parse_operations(char *str) {
	char delimiter[] = " ";
	char *ptr;
	int i = 0;

	ptr = strtok(str, delimiter);
	op_strings[i++] = ptr;
	while (ptr) {
		ptr = strtok(NULL, delimiter);
		op_strings[i++] = ptr;
	}
}

static void parse_backend_option(char *str) {
	char delimiter[] = ":";
	char *ptr;
	int i = 0;

	ptr = strtok(str, delimiter);
	op_strings[i++] = ptr;
	while (ptr) {
		ptr = strtok(NULL, delimiter);
		op_strings[i++] = ptr;
	}
}
