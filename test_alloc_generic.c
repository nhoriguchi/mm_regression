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
#include "test_core/lib/include.h"

#define ADDR_INPUT 0x700000000000

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

/*
 * @i is current chunk index. In the last chunk mmaped size will be truncated.
 */
static int get_size_of_chunked_mmap_area(int i) {
	if (i == nr_chunk - 1)
		return ((nr_p - 1) % CHUNKSIZE + 1) * PS;
	else
		return CHUNKSIZE * PS;
}

static void mmap_all(char **p) {
	int i;
	int size;
	void *baseaddr = (void *)ADDR_INPUT;

	for (i = 0; i < nr_chunk; i++) {
		size = get_size_of_chunked_mmap_area(i);

		/* printf("base:0x%lx, size:%lx\n", baseaddr, size); */
		p[i] = checked_mmap(baseaddr, size, protflag, mapflag, -1, 0);
		/* printf("p[%d]:%p + 0x%lx\n", i, p[i], size); */
		/* TODO: generalization, making this configurable */
		madvise(p[i], size, MADV_HUGEPAGE);
		memset(p[i], 'a', size);
		baseaddr += size;
	}

}

static void munmap_all(char **p) {
	int i;
	int size;
	void *baseaddr = (void *)ADDR_INPUT;

	for (i = 0; i < nr_chunk; i++) {
		size = get_size_of_chunked_mmap_area(i);
		checked_munmap(p[i], size);
		baseaddr += size;
	}
}

static void access_all(char **p) {
	int i;
	int size;
	void *baseaddr = (void *)ADDR_INPUT;

	for (i = 0; i < nr_chunk; i++) {
		size = get_size_of_chunked_mmap_area(i);
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

int main(int argc, char *argv[]) {
	char c;
        unsigned long nr_nodes = numa_max_node() + 1;
        /* struct bitmask *new_nodes; */
        unsigned long nodemask = (1UL << nr_nodes) - 1; /* all nodes in default */
	int mmap_munmap_iteration = 0;

	while ((c = getopt(argc, argv, "vp:n:bm:i")) != -1) {
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
			mmap_munmap_iteration = 1;
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

        /* new_nodes = numa_bitmask_alloc(nr_nodes); */
        /* numa_bitmask_setbit(new_nodes, 1); */

	signal(SIGUSR1, sig_handle_flag);

	nr_chunk = (nr_p - 1) / CHUNKSIZE + 1;
	printf("nr_p %lx, nr_chunk %lx\n", nr_p, nr_chunk);

	if (mmap_munmap_iteration)
		do_mmap_munmap_iteration();
	else
		do_normal_allocation();
}
