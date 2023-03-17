#define _GNU_SOURCE 1
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <err.h>
#include <fcntl.h>

#define PS	0x1000
#define HPS	0x200000
#define ADDR_INPUT	0x700000000000

int main(int argc, char **argv) {
	int fd;
	int ret;
	char c;
	char buf[HPS];
	char buf2[HPS];
	char *ptr;

	if (!strcmp(argv[2], "thpanon")) {
		ptr = mmap((void *)ADDR_INPUT, HPS, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANON, -1, 0);
		if (ptr == (void *)MAP_FAILED) {
			perror("mmap");
			return 1;
		}
	} else {
		fd = open("tmp/testfile", O_CREAT|O_RDWR, 0666);
		if (fd == -1) {
			perror("open");
			return -1;
		}
		memset(buf, 'a', HPS);
		ret = pwrite(fd, buf, HPS, 0);
		printf("ret: %d\n", ret);

		fsync(fd);

		if (!strcmp(argv[2], "folio")) {
			close(fd);
			system("echo 3 > /proc/sys/vm/drop_caches");

			fd = open("tmp/testfile", O_CREAT|O_RDWR, 0666);
			if (fd == -1) {
				perror("open");
				return -1;
			}
			ret = pread(fd, buf, PS, 0);
		}
		ptr = mmap((void *)ADDR_INPUT, HPS, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
		if (ptr == (void *)MAP_FAILED) {
			perror("mmap");
			return 1;
		}
	}
	printf("ret: %d\n", ret);

	c = ptr[0];
	c = ptr[PS];

	sprintf(buf, "build/page-types -p %d -a 0x700000000+10 -Nrl\n", getpid());
	// system(buf);

	if (!strcmp(argv[1], "hard")) {
		system(buf);
		ret = madvise(ptr + PS, PS, 100);
		printf("access later\n");
		system(buf);
		ptr[PS] = 'c';
	} else if (!strcmp(argv[1], "dirty_hard")) {
		ptr[PS] = 'x';
		system(buf);
		ret = madvise(ptr + PS, PS, 100);
		printf("access later\n");
		system(buf);
		ptr[PS] = 'c';
	} else if (!strcmp(argv[1], "split_hard")) {
		system(buf);
		system("echo 1 > /sys/kernel/debug/split_huge_pages\n");
		c = ptr[0]; c = ptr[PS];
		system(buf);
		ret = madvise(ptr + PS, PS, 100);
		printf("access later\n");
		system(buf);
		ptr[PS] = 'c';
	} else if (!strcmp(argv[1], "split_hard2")) {
		sprintf(buf2, "echo %d,0x700000000000,0x700000200000 > /sys/kernel/debug/split_huge_pages\n", getpid());
		system(buf);
		system(buf2);
		// c = ptr[0]; c = ptr[PS];
		system(buf);
		// system(buf);
		ret = madvise(ptr + PS, PS, 100);
		printf("access later\n");
		system(buf);
		ptr[PS] = 'c';
	} else {
		ret = madvise(ptr + PS, PS, 101);
		system(buf);
		ptr[PS] = 'c';
	}

	// system("build/page-types -f tmp/testfile -a 0+10 -Nrl");

	munmap(ptr, HPS);
	close(fd);
	unlink("tmp/testfile");

	if (ret < 0) {
		perror("madvise");
		return 1;
	} else if (ret == 0) {
		return 0;
	}
}
