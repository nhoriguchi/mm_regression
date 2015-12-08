#include <stdio.h>
#include <signal.h>
#include <sys/mman.h>
#include <numa.h>
#include <numaif.h>
#include <fcntl.h>

#define ADDR_INPUT 0x700000000000
#define PS 4096
#define err(x) perror(x),exit(EXIT_FAILURE)
#define errmsg(x, ...) fprintf(stderr, x, ##__VA_ARGS__),exit(EXIT_FAILURE)

int flag = 1;

void sig_handle_flag(int signo) { flag = 0; }

void set_new_nodes(struct bitmask *mask, unsigned long node) {
	numa_bitmask_clearall(mask);
	numa_bitmask_setbit(mask, node);
}

int main(int argc, char *argv[]) {
	int nr = 1000;
	int fd = -1;
	char *pfile;
	struct timeval tv;
	struct bitmask *nodes;
	unsigned long nr_nodes;
	unsigned long memsize = nr * PS;

	nr_nodes = numa_max_node() + 1; /* numa_num_possible_nodes(); */
	nodes = numa_bitmask_alloc(nr_nodes);
	if (nr_nodes < 2)
		errmsg("A minimum of 2 nodes is required for this test.\n");

	gettimeofday(&tv, NULL);
	srandom(tv.tv_usec);

	fd = open(argv[1], O_RDWR, S_IRWXU);
	if (fd < 0)
		err("open");
	pfile = mmap((void *)ADDR_INPUT, memsize, PROT_READ|PROT_WRITE,
		      MAP_SHARED, fd, 0);
	if (pfile == (void*)-1L)
		err("mmap");

	signal(SIGUSR1, sig_handle_flag);

	while (flag) {
		int node;
		unsigned long offset;
		unsigned long length;

		memset(pfile, 'a', memsize);

		node = random() % nr_nodes;
		set_new_nodes(nodes, random() & nr_nodes);
		offset = (random() % nr) * PS;
		length = (random() % (nr - offset/PS)) * PS;
		printf("[%d] node:%x, offset:%x, length:%x\n",
		       getpid(), node, offset, length);
		mbind(pfile + offset, length, MPOL_BIND, nodes->maskp,
		      nodes->size + 1, MPOL_MF_MOVE_ALL);
	}

	munmap(pfile, memsize);
	return 0;
}
