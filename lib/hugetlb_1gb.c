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
#include <sys/ipc.h>
#include <sys/shm.h>

int flag = 1;
void sig_handle_flag(int signo) { flag = 0; }

#define ADDR_INPUT	0x700000000000UL
#define MADV_SOFT_OFFLINE 101

int main(int argc, char **argv) {
	char *p;
	int fd;
	int nums;
	int offline = 0;
	int fork_ = 0;
	int memset_ = 0;
	int ret;
	char buf[8192];
	int pipefd;

	signal(SIGUSR1, sig_handle_flag);

	nums = strtol(argv[1], NULL, 10);

	if (!strcmp(argv[2], "madvsoft"))
		offline = MADV_SOFT_OFFLINE;
	else if (!strcmp(argv[2], "madvhard"))
		offline = MADV_HWPOISON;

	if (!strcmp(argv[3], "fork"))
		fork_ = 1;

	// access with memset or write()
	if (!strcmp(argv[4], "memset"))
		memset_ = 1;

	if (!strcmp(argv[5], "")) {
		pipefd = 1;
	} else {
		pipefd = open(argv[5], O_WRONLY);
		if (pipefd == -1) {
			puts("opening pipe failed");
			return 1;
		}
	}

	if (!strcmp(argv[6], "file")) {
		fd = open("tmp/hugetlbfs/testfile", O_CREAT|O_RDWR);
		if (fd == -1) {
			puts("opening hugetlbfs file failed");
			return 1;

		}

		memset(buf, 'c', 8192);
		pwrite(fd, buf, 8192, 0);

		p = mmap((void *)ADDR_INPUT, 1 << 30, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
		if (p == (void *)-1) {
			perror("mmap");
			return 1;
		}
		dprintf(pipefd, "file hugetlb allocation ok: %p\n", p);
	} else if (!strcmp(argv[6], "anon")) {
		p = mmap((void *)ADDR_INPUT, 1 << 30, PROT_READ|PROT_WRITE,
			 MAP_ANONYMOUS|MAP_PRIVATE|MAP_HUGETLB|(30 << 26), -1, 0);
		if (p == (void *)-1) {
			perror("mmap");
			return 1;
		}
		dprintf(pipefd, "anonymous hugetlb allocation ok: %p %d\n", p, getpid());
	} else if (!strcmp(argv[6], "shmem")) {
		int shmid;
		int flags = IPC_CREAT | SHM_R | SHM_W | SHM_HUGETLB | 30 << 26;

		if ((shmid = shmget(0, 1, flags)) < 0) {
			perror("shmget");
			return 1;
		}
		p = shmat(shmid, (void *)ADDR_INPUT, 0);
		if (p == (char *)-1) {
			perror("Shared memory attach failure");
			shmctl(shmid, IPC_RMID, NULL);
			return 1;
		}
		dprintf(pipefd, "shmem hugetlb allocation ok: %p\n", p);
	} else {
		printf("invalid input\n");
		return 1;
	}

	memset(p, 'a', 4 << 20);

	if (!offline)
		goto pause;
	if (fork_) {
		pid_t child = fork();
		if (!child) {
			ret = madvise(p, 4096, offline);
			dprintf(pipefd, "child madvise 1: %d\n", ret);
			return ret;
		} else {
			dprintf(pipefd, "in waitpid\n");
			waitpid(child, NULL, 0);
			dprintf(pipefd, "out waitpid\n");
		}
	} else {
		if (nums > 0) {
			ret = madvise(p, 4096, offline);
			dprintf(pipefd, "madvise 1: %d\n", ret);
			if (ret == -1)
				perror("madvise");
			if (!ret && nums > 1) {
				ret = madvise(p + 4096, 4096, offline);
				dprintf(pipefd, "madvise 2: %d\n", ret);
				if (ret == -1)
					perror("madvise");
			}
		}
	}
pause:
	dprintf(pipefd, "faultin %d\n", nums);
	pause();

	if (memset_)
		memset(p, 'b', 8192);
	else
		pwrite(fd, buf, 8192, 0);

	dprintf(pipefd, "wrote after page-offline\n");
	pause();
}
