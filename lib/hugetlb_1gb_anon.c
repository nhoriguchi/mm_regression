#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <error.h>

int flag = 1;
void sig_handle_flag(int signo) { flag = 0; }

#define ADDR_INPUT	0x700000000000UL

int main(int argc, char **argv) {
	char *p;
	int hps;
	int allocate = 0;
	int pipefd;

	signal(SIGUSR1, sig_handle_flag);

	hps = strtol(argv[1], NULL, 10);

	if (!strcmp(argv[2], "reserve"))
		allocate = 0;
	else if (!strcmp(argv[2], "allocate"))
		allocate = 1;

	if (!strcmp(argv[3], "")) {
		pipefd = 1;
	} else {
		pipefd = open(argv[3], O_WRONLY);
		if (pipefd == -1) {
			puts("opening pipe failed");
			return 1;
		}
	}

	p = mmap((void *)ADDR_INPUT, (1UL << 30) * hps, PROT_READ|PROT_WRITE,
		 MAP_ANONYMOUS|MAP_PRIVATE|MAP_HUGETLB|(30 << 26), -1, 0);
	if (p == (void *)-1) {
		perror("mmap");
		return 1;
	}

	if (allocate) {
		for (int i = 0; i < hps; i++)
			memset(p + i * (1UL << 30), 'a', 4 << 20);
		dprintf(pipefd, "allocated %d\n", hps);
	} else {
		dprintf(pipefd, "reserved %d\n", hps);
	}

	pause();
	dprintf(pipefd, "--- %c\n", p[0]);
	dprintf(pipefd, "access after page-offline\n");
	pause();
}
