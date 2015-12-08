#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include "test_core/lib/include.h"

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

#define ADDR_INPUT 0x700000000000

int main(int argc, char *argv[])
{
	char c;
	int i, j;
	int nr = 1024;
	int nr_hp = nr / 512;
	int size;
	unsigned long pos = ADDR_INPUT;
	int ret;
	char *file;
	int fd;
	char *pfile;
	char *panon;
	char *pthp;
	char *phugetlb;

	while ((c = getopt(argc, argv, "p:n:v")) != -1) {
		switch(c) {
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
			nr = strtoul(optarg, NULL, 0);
			nr_hp = nr / 512;
			break;
		case 'v':
			verbose = 1;
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}
	file = argv[optind];
	if (!file)
		err("need argument for test file\n");

	size = nr * PS;

	signal(SIGUSR1, sig_handle);
	pprintf_wait(SIGUSR1, "test_idle_page_tracking start\n");

	fd = checked_open(file, O_RDWR);
	pfile = checked_mmap((void *)pos, size, MMAP_PROT, MAP_PRIVATE, fd, 0);
	pos = pos + size;
	panon = checked_mmap((void *)pos, size, MMAP_PROT,
		 MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (madvise(panon, size, MADV_NOHUGEPAGE) == -1)
		perror("madvise");
	pos = pos + size;
	pthp = checked_mmap((void *)pos, size, MMAP_PROT,
		 MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (madvise(pthp, size, MADV_HUGEPAGE) == -1)
		perror("madvise");
	pos = pos + size;
	phugetlb = checked_mmap((void *)pos, size, MMAP_PROT,
		 MAP_PRIVATE|MAP_ANONYMOUS|MAP_HUGETLB, -1, 0);

	printf("pfile %p\n", pfile);
	printf("panon %p\n", panon);
	printf("pthp  %p\n", pthp);
	printf("phuge %p\n", phugetlb);

	memset(pfile,    'a', size);
	memset(panon,    'b', size);
	memset(pthp,     'c', size);
	memset(phugetlb, 'd', size);

	pprintf_wait(SIGUSR1, "faulted-in\n");

	signal(SIGUSR1, sig_handle_flag);
	pprintf("busyloop\n");
	while (flag) {
		j = (j + 1) % 100;
		for (i = 0; i < nr; i++) {
			c = pfile[i*PS];
			c = panon[i*PS];
			c = pthp[i*PS];
			c = phugetlb[i*PS];
		}
		memset(pfile,    j, nr*PS);
		memset(panon,    j, nr*PS);
		memset(pthp,     j, nr*PS);
		memset(phugetlb, j, nr*PS);
	}
	sleep(1);

	pprintf_wait(SIGUSR1, "referenced\n");

	pprintf_wait(SIGUSR1, "test_idle_page_tracking exit\n");
	return 0;
}
