#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <getopt.h>
#include "test_core/lib/include.h"

#define ADDR_INPUT 0x700000000000

int flag = 1;
int HPS;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

int main(int argc, char *argv[]) {
	int i;
	int nr = 2;
	char c;
	char *p;
	int mapflag = MAP_ANONYMOUS|MAP_SHARED;
	int protflag = PROT_READ|PROT_WRITE;
	int reserveonly = 0;
	unsigned long memsize = 0;

	while ((c = getopt(argc, argv, "h:rm:p:n:v")) != -1) {
		switch(c) {
                case 'h':
                        HPS = strtoul(optarg, NULL, 10) * 1024;
			mapflag |= MAP_HUGETLB;
                        break;
		case 'r': /* just reserve */
			reserveonly = 1;
			break;
		case 'm':
			if (!strcmp(optarg, "private")) {
				mapflag |= MAP_PRIVATE;
				mapflag &= ~MAP_SHARED;
			} else if (!strcmp(optarg, "shared"))
				mapflag |= MAP_SHARED;
			else
				errmsg("invalid optarg for -m\n");
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
			nr = strtoul(optarg, NULL, 10);
			break;
		case 'v':
			verbose = 1;
			break;
		}
	}

	signal(SIGUSR1, sig_handle);
	if (HPS > 0) {
		validate_hugepage_size(HPS);
		memsize = nr * HPS;
	} else
		memsize = nr * PS;
	Dprintf("memsize = 0x%x, hpsize = %d, mapflag = 0x%x\n", memsize, HPS, mapflag);
	p = checked_mmap((void *)ADDR_INPUT, nr * PS, protflag, mapflag, -1, 0);
	if (!reserveonly)
		memset(p, 'a', memsize);
	signal(SIGUSR1, sig_handle_flag);
	pprintf("busy loop to check pageflags\n");
	while (flag) {
		usleep(1000);
		if (!reserveonly)
			memset(p, 'a', memsize);
	}
	pprintf("%s exit\n", argv[0]);
	pause();
	exit(EXIT_SUCCESS);
}
