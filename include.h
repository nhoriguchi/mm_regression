#define ADDR_INPUT 0x700000000000

/* for multi_backend operation */
void *allocate_base = (void *)ADDR_INPUT;

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
