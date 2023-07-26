
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <signal.h>
#include <limits.h>
#include <libpmem.h>
#include <sys/prctl.h>

#define GB      0x40000000UL

/* perform synchronous page faults for the mapping */
#define MAP_SYNC        0x80000
#define ALIGN(x, a)     (((x) + (a) - 1) & ~((a) - 1))
#define PAGE_ALIGN(x)     ALIGN(x, 4096)

#define PS	4096
#define ADDR_INPUT 0x700000000000
#define HPS             0x200000

#define MADV_HWPOISON   100

int main() {
	int fd;
	int mmapflag = MAP_SHARED|MAP_SYNC;
	char *ptr;
	int ret = 0;
	char c;

	fd = open("/dev/dax0.6", O_CREAT|O_RDWR, 0666);
	if (fd == -1) {
		fprintf(stderr, "Failed to open devdax device or fsdax file.");
		return -1;
	}

	ptr = mmap((void *)ADDR_INPUT, HPS, PROT_READ|PROT_WRITE, mmapflag, fd, 1 * GB);
	if (ptr == (void *)MAP_FAILED) {
		perror("mmap");
		printf("If you try mmap()ing for devdax device, make sure that the mapping size is aligned to devdax block size (might be 2MB).\n");
		return -1;
	}
	for (int i = 0; i < HPS/PS; i++) {
		memset(ptr + i * PS, 'a', PS);
	}
	madvise(ptr, PS, MADV_NORMAL);
	ret = madvise(ptr, PS, MADV_HWPOISON);
	madvise(ptr, PS, MADV_NORMAL);
	if (ret < 0) {
		perror("madvise");
		printf("madvise(MADV_HWPOISON) failed.\n");
		return 1;
	} else {
		printf("madvise(MADV_HWPOISON) passed.\n");
		c = ptr[0];
		printf("Accessing from poisoned memory wrongly succeeded?\n");
		return 2;
	}
}
