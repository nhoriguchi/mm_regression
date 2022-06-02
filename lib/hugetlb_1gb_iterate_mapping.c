#include <stdio.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

int flag = 1;
void sig_handle_flag(int signo) { flag = 0; }

#define ADDR_INPUT	0x700000000000UL

int main(int argc, char **argv) {
	char *p;
	int fd;
	char buf[8192];

	signal(SIGUSR1, sig_handle_flag);

	if (!strcmp(argv[1], "file")) {
		fd = open("tmp/hugetlbfs/testfile", O_CREAT|O_RDWR);
		if (fd == -1) {
			puts("opening hugetlbfs file failed");
			return 1;

		}

		memset(buf, 'c', 8192);
		pwrite(fd, buf, 8192, 0);
		printf("prepared\n");
		while (flag) {
			p = mmap((void *)ADDR_INPUT, 1UL << 30, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
			if (p == (void *)-1) {
				perror("mmap");
				return 1;
			}
			munmap(p, 1UL << 30);
		}
	} else if (!strcmp(argv[1], "anon")) {
		printf("prepared\n");
		while (flag) {
			p = mmap((void *)ADDR_INPUT, 1 << 30, PROT_READ|PROT_WRITE,
				 MAP_ANONYMOUS|MAP_PRIVATE|MAP_HUGETLB|(30 << 26), -1, 0);
			if (p == (void *)-1) {
				perror("mmap");
				return 1;
			}
			memset(p, 'a', 1UL << 30);
			munmap(p, 1UL << 30);
		}
	}
}
