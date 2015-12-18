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
#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"
#include "test_core/lib/pfn.h"
#include "include.h"

#define ADDR_INPUT 0x700000000000

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

int nr_hp = 2;

enum {
	MS_MIGRATEPAGES,
	MS_MBIND,
	MS_MOVE_PAGES,
	MS_HOTREMOTE,
	MS_MADV_SOFT,
	NR_MIGRATION_SRCS,
};
int migration_src;


unsigned long nr_nodes;
struct bitmask *new_nodes;

int thp;
int partialmbind;

unsigned long pageflag_mask;

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

void *addrs[CHUNKSIZE + 1];
int status[CHUNKSIZE + 1];
int nodes[CHUNKSIZE + 1];

static int __move_pages_chunk(char *p, int size, void *args) {
	int i;

	for (i = 0; i < size / PS; i++) {
		addrs[i] = p + i * PS;
		nodes[i] = 1;
		status[i] = 0;
	}
	numa_move_pages(0, size / PS, addrs, nodes, status, MPOL_MF_MOVE_ALL);
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

static void do_page_migration(void) {
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

static void setup(void) {
	nr_nodes = numa_max_node() + 1;
        if (nr_nodes < 2)
                errmsg("A minimum of 2 nodes is required for this test.\n");

	signal(SIGUSR1, sig_handle);
	signal(SIGUSR2, sig_handle_flag);

	if (backend_type == PAGECACHE) {
		if (!workdir)
			err("you must set workdir with -d option to allocate pagecache");
		create_regular_file();
	}

	if (backend_type == HUGETLB_FILE) {
		if (!workdir)
			err("you must set workdir with -d option to allocate hugetlbfs file");
		create_hugetlbfs_file();
	}

	nr_chunk = (nr_p - 1) / CHUNKSIZE + 1;
}

int main(int argc, char *argv[]) {
	int i;
	int ret;
	char c;
	char *p;

	while ((c = getopt(argc, argv, "vp:m:n:N:h:Rs:PB:bd:M:")) != -1) {
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
		case 'm':
			if (!strcmp(optarg, "private")) {
				mapflag |= MAP_PRIVATE;
				mapflag &= ~MAP_SHARED;
			} else if (!strcmp(optarg, "shared")) {
				mapflag &= ~MAP_PRIVATE;
				mapflag |= MAP_SHARED;
			} else
				errmsg("invalid optarg for -m\n");
			break;
		case 'n':
			nr_p = strtoul(optarg, NULL, 10);
			nr_hp = (nr_p - 1) / 512 + 1;
			break;
		case 'N':
			nr_hp = strtoul(optarg, NULL, 10);
			nr_p = nr_hp * 512;
			break;
		case 'h':
			HPS = strtoul(optarg, NULL, 10) * 1024;
			mapflag |= MAP_HUGETLB;
			/* todo: arch independent */
			if (HPS != 2097152 && HPS != 1073741824)
				errmsg("Invalid hugepage size\n");
			break;
		case 'R':
			mapflag |= MAP_NORESERVE;
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
		case 'd': /* tmpdir/workdir */
			workdir = optarg;
			break;
		case 'M':
			parse_bits_mask(optarg);
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	setup();

	pprintf("just started\n");
	pause();

	do_page_migration();
}
