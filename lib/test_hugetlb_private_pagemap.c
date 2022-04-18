#define _GNU_SOURCE
#include <stdio.h>
// #include <signal.h>
// #include <string.h>
// #include <stdlib.h>
#include <sys/mman.h>
// #include <sys/types.h>
// #include <sys/stat.h>
// #include <unistd.h>
#include <fcntl.h>
#include <numa.h>
#include <numaif.h>
// #include <sys/ipc.h>
// #include <sys/shm.h>
// #include <sys/wait.h>
#include "./include.h"

int main(int argc, char *argv[]) {
	size_t size = 2 * HPS;
	char *phugetlb;

	workdir = "/dev/hugepages";
	filebase = "testfile";

	/* hugetlbfd returned */
	create_hugetlbfs_file();

	phugetlb = checked_mmap((void *)ADDR_INPUT, size, PROT_READ|PROT_WRITE,
				MAP_PRIVATE, hugetlbfd, 0);
	printf("phugetlb: %p, %lx\n", phugetlb, size);
	memset(phugetlb, 'a', size);
	pause();
}
