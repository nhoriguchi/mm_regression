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

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

int main(int argc, char *argv[]) {
	char c;

	while ((c = getopt(argc, argv, "p:v")) != -1) {
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
		case 'v':
			verbose = 1;
			break;
		}
	}

	signal(SIGUSR1, sig_handle);
	pprintf("checkpoint_1\n");
	pause();
	pprintf_wait(SIGUSR1, "checkpoint_2\n");
	signal(SIGUSR1, sig_handle_flag);
	pprintf("checkpoint_3\n");
	while (flag)
		usleep(1000);
	pprintf("checkpoint_4\n");
	pause();
	exit(EXIT_SUCCESS);
}
