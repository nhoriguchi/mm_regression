#define _GNU_SOURCE  
#include <stdio.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <string.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

#define ADDR_INPUT 0x700000000000
#define PS	0x1000
#define HPS	0x200000
#define GPS	0x40000000

#define MADV_HWPOISON          100
#define MADV_SOFT_OFFLINE      101

int main(int argc, char **argv)
{
	int i;
	unsigned long nodemask = 4;
	void *addr;
	int fd;
	pid_t pid;
	int ret;
	int wstatus;

	if (argc < 2) {
		fprintf(stderr, "need to pass hugetlb file.\n");
		return -1;
	}

	fd = open(argv[1], O_RDWR);
	if (fd == -1) {
		fprintf(stderr, "failed to open file %s.\n", argv[1]);
		return -1;
	}

	addr = mmap((void *)ADDR_INPUT, HPS, PROT_READ | PROT_WRITE,
		    MAP_SHARED, fd, 0);
	pid = fork();

	if (pid) {
		// parent
		memset(addr, 'a', HPS);
		ret = madvise(addr, PS, MADV_HWPOISON);
		printf("[parent %d] madvise(MADV_HWPOISON) returned %d\n", getpid(), ret);
		wait(&wstatus);
		if (WIFEXITED(wstatus)) {
			printf("[parent %d] child exited with status %d\n", getpid(), WEXITSTATUS(wstatus));
			return 0;
		} else {
			// WIFSIGNALED()
			printf("[parent %d] child terminated by signal %d\n", getpid(), WTERMSIG(wstatus));
			return 1;
		}
	} else {
		// child
		// the hugepage is not fault-in here.
		usleep(100000);
		// fault-in now after hwpoisoned
		if (!strcmp(argv[2], "sysrw")) {
			char buf[PS];
			ret = pread(fd, buf, PS, 0);
			if (ret == -1) {
				printf("[child %d] pread() hwpoison hugepage failed as expected: %d\n", getpid());
			} else {
				printf("[child %d] pread() hwpoison hugepage passed: %d (%d)\n", getpid(), buf[0]);
				return -1;
			}
			// ret = fallocate(fd, FALLOC_FL_PUNCH_HOLE, 0, HPS);
			ret = fallocate(fd, 3, 0, HPS);
			if (ret == -1) {
				printf("[child %d] fallocate() hwpoison hugepage failed: %d\n", getpid(), ret);
				perror("fallocate");
				return -1;
			} else {
				printf("[child %d] fallocate() hwpoison hugepage passed: %d\n", getpid(), ret);
			}
			ret = pread(fd, buf, PS, 0);
			if (ret == -1) {
				printf("[child %d] pread() hwpoison hugepage failed: %d\n", getpid());
				return -1;
			} else {
				printf("[child %d] pread() hwpoison hugepage passed: %d (%d)\n", getpid(), buf[0]);
			}
			ret = pwrite(fd, buf, PS, 0);
			if (ret == -1) {
				printf("[child %d] pwrite() hwpoison hugepage failed: %d\n", getpid());
				return -1;
			} else {
				printf("[child %d] pwrite() hwpoison hugepage passed: %d\n", getpid());
			}
		} else {
			memset(addr, 'a', HPS);
			printf("[child %d] access after hwpoison by parent process.\n", getpid());
		}
		return 0;
	}

	return 0;
}
