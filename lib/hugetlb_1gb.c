#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

int flag = 1;
void sig_handle_flag(int signo) { flag = 0; }

#define MADV_SOFT_OFFLINE 101

int main(int argc, char **argv) {
	char *p;
	int fd;
	int twice = 0;
	int offline = MADV_HWPOISON;
	int fork_ = 0;
	int memset_ = 0;
	int ret;
	char buf[8192];

	signal(SIGUSR1, sig_handle_flag);

	if (!strcmp(argv[1], "double"))
		twice = 1;

	if (!strcmp(argv[2], "soft"))
		offline = MADV_SOFT_OFFLINE;

	if (!strcmp(argv[3], "fork"))
		fork_ = 1;

	if (!strcmp(argv[4], "memset"))
		memset_ = 1;

	fd = open("tmp/hugetlbfs/testfile", O_CREAT|O_RDWR);
	printf("fd = %d\n", fd);

	p = mmap(NULL, 1*1024*1024*1024, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == (void *)-1) {
		puts("mmap failed");
		return 1;
	}
	printf("p = %p\n", p);

	memset(p, 'a', 8192);
	memset(buf, 'c', 8192);
	pwrite(fd, buf, 8192, 0);

	memset(p, 'a', 8192);

	if (fork_) {
		if (!fork()) {
			ret = madvise(p, 4096, offline);
			if (memset_)
				memset(p, 'a', 8192);
			else
				pwrite(fd, buf, 8192, 0);
		}
		usleep(1000);
		if (!fork()) {
			ret = madvise(p, 4096, offline);
			if (memset_)
				memset(p, 'a', 8192);
			else
				pwrite(fd, buf, 8192, 0);
		}
		usleep(1000);
	} else {
		ret = madvise(p, 4096, offline);
		printf("ret 1: %d\n", ret);
		if (twice) {
			ret = madvise(p + 4096, 4096, offline);
			printf("ret 2: %d\n", ret);
		}
	}

	pause();

	if (memset_)
		memset(p, 'b', 8192);
	else
		pwrite(fd, buf, 8192, 0);
}
