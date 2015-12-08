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

void sig_handle(int signo) { ; }

#define ADDR_INPUT 0x700000000000

int main(int argc, char *argv[])
{
	int nr = 3072;
	int size;
	int ret;
	char *pshm;
	char *panon;
	char c;
	int id;
	int pid;

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
	pprintf_wait(SIGUSR1, "swap_shmem start\n");
	size = nr * PS;

	id = shmget(IPC_PRIVATE, size, IPC_CREAT);
	pprintf("# shm id %d\n", id);
	pprintf_wait(SIGUSR1, "shmem allocated\n");

	/* pshm = checked_mmap((void *)ADDR_INPUT, size, MMAP_PROT, */
	/* 		 MAP_PRIVATE|MAP_ANONYMOUS, -1, 0); */
	pshm = shmat(id, (void *)ADDR_INPUT, 0);
	pprintf("# shm attached address %p\n", pshm);
	pprintf_wait(SIGUSR1, "shmem attached\n");

	memset(pshm, 'b', size);
	/* pid = fork(); */
	/* if (!pid) { */
	/* 	pprintf("child process running %d\n", getpid()); */
	/* 	memset(pshm, 'c', size); */
	/* 	pause(); */
	/* } */
	pprintf_wait(SIGUSR1, "shmem faulted-in\n");

	panon = checked_mmap((void *)(ADDR_INPUT + size), size, MMAP_PROT,
			 MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	/* should cause swap out by external configuration */
	pprintf("anonymous address starts at %p\n", panon);
	memset(panon, 'a', size);
	pprintf_wait(SIGUSR1, "swap_shmem exit\n");
	return 0;
}
