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
#include "include.h"

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
			break;
		case 'N':
			nr_p = strtoul(optarg, NULL, 10) * 512;
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
