#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/mman.h>
#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"

void sig_handle(int signo) { ; }

#define ADDR_INPUT 0x700000000000

int main(int argc, char *argv[])
{
	int nr = 512;
	int size;
	int ret;
	char *p;
	char c;

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
			break;
		case 'v':
			verbose = 1;
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	signal(SIGUSR1, sig_handle);
	pprintf_wait(SIGUSR1, "malloc_madv_willneed start\n");
	size = nr * PS;
	p = checked_mmap((void *)ADDR_INPUT, size, MMAP_PROT, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	/* should cause swap out by external configuration */
	memset(p, 'a', size);
	pprintf_wait(SIGUSR1, "call madvise with MADV_WILLNEED\n");
	ret = madvise(p, size, MADV_WILLNEED);
	if (ret == -1) {
		perror("madvise");
		return 1;
	}
	pprintf_wait(SIGUSR1, "malloc_madv_willneed exit\n");
	return 0;
}
