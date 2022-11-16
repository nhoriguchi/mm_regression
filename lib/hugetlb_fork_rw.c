/*
 * ./hugetlb_fork_rw shmem [sysrw|mmap]
 * ./hugetlb_fork_rw <file> [sysrw|mmap]
 * ./hugetlb_fork_rw [shmem|<file>] nofork [read|write|mmap]
 */
#define _GNU_SOURCE  
#include <stdio.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <string.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>
#include <sys/shm.h>

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
	int shmkey = 0;
	char buf[PS];

	if (argc < 2) {
		fprintf(stderr, "need to pass hugetlb file.\n");
		return -1;
	}

	if (!strcmp(argv[1], "shmem")) {
		int shmid;
		int flags = IPC_CREAT | SHM_R | SHM_W | SHM_HUGETLB;
		if ((shmid = shmget(shmkey, HPS, flags)) < 0) {
			perror("shmget");
			return -1;
		}
		addr = shmat(shmid, (void *)ADDR_INPUT, 0);
		if (addr == (char *)-1) {
			perror("Shared memory attach failure");
			shmctl(shmid, IPC_RMID, NULL);
			perror("shmat failed");
			return -1;
		}
		if (addr != (void *)ADDR_INPUT) {
			printf("Shared memory not attached to expected address (%p -> %p) %lx %lx\n", (void *)ADDR_INPUT, addr, SHMLBA, SHM_RND);
			shmctl(shmid, IPC_RMID, NULL);
			perror("shmat failed");
			return -1;
		}
		shmkey = shmid;
	} else {
		fd = open(argv[1], O_RDWR);
		if (fd == -1) {
			fprintf(stderr, "failed to open file %s.\n", argv[1]);
			return -1;
		}
		addr = mmap((void *)ADDR_INPUT, HPS, PROT_READ | PROT_WRITE,
			    MAP_SHARED, fd, 0);
	}

	if (!strcmp(argv[2], "nofork")) {
		madvise(buf, PS, MADV_NORMAL);
		if (!strcmp(argv[3], "read")) {
			ret = pread(fd, buf, PS, 0);
			printf("pread returned %d, errno %d\n", ret, errno);
			if (ret)
				return errno;
		} else if (!strcmp(argv[3], "write")) {
			memset(buf, 'a', PS);
			ret = pwrite(fd, buf, PS, 0);
			printf("pwrite returned %d, errno %d\n", ret, errno);
			if (ret)
				return errno;
		} else if (!strcmp(argv[3], "mmap")) {
			memset(addr, 'a', HPS);
		}
		return 0;
	}

	pid = fork();

	if (pid) {
		// parent
		memset(addr, 'a', HPS);
		ret = madvise(addr, PS, MADV_HWPOISON);
		printf("[parent %d] madvise(MADV_HWPOISON) returned %d\n", getpid(), ret);
		wait(&wstatus);
		if (WIFEXITED(wstatus)) {
			printf("[parent %d] child exited with status %d\n", getpid(), WEXITSTATUS(wstatus));
			return WEXITSTATUS(wstatus) == 0 ? 0 : 2;
		} else {
			// WIFSIGNALED()
			printf("[parent %d] child terminated by signal %d\n", getpid(), WTERMSIG(wstatus));
			return 1;
		}
	} else {
		// child
		// the hugepage is not fault-in here.
		usleep(1000000);
		// fault-in now after hwpoisoned
		if (!strcmp(argv[2], "sysrw")) {
			ret = pread(fd, buf, PS, 0);
			if (ret == -1) {
				printf("[child %d] pread() hwpoison hugepage failed as expected: %d\n", getpid(), errno);
			} else {
				printf("[child %d] pread() hwpoison hugepage passed.\n", getpid());
				return -1;
			}
			// ret = fallocate(fd, FALLOC_FL_PUNCH_HOLE, 0, HPS);
			ret = fallocate(fd, 3, 0, HPS);
			if (ret == -1) {
				printf("[child %d] fallocate() hwpoison hugepage failed: %d %d\n", getpid(), errno);
				perror("fallocate");
				return -1;
			} else {
				printf("[child %d] fallocate() hwpoison hugepage passed.\n", getpid());
			}
			ret = pread(fd, buf, PS, 0);
			if (ret == -1) {
				printf("[child %d] pread() hwpoison hugepage failed: %d\n", getpid(), errno);
				return -1;
			} else {
				printf("[child %d] pread() hwpoison hugepage passed (error was cancelled by fallocate().\n", getpid());
			}
		} else {
			printf("[child %d] try to access to hwpoison memory by memset().\n", getpid());
			memset(addr, 'a', HPS);
			printf("[child %d] access after hwpoison by parent process.\n", getpid());
		}
		return 0;
	}

	return 0;
}
