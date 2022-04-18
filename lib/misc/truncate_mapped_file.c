#define _GNU_SOURCE

#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>

#include <sys/types.h>
#include <unistd.h>
#include <stdlib.h>

#define PS 4096

void write_region(char *addr, int size) {
	int i = 0;
	while (i < size) {
		addr[i] = 1;
		i += PS;
	}
}

void read_region(char *addr, int size) {
	int i = 0;
	char c;
	while (i < size) {
		c = addr[i];
		i += PS;
	}
}

void check_region(char *ptr, int size) {
	char cmd[256];
	sprintf(cmd, "/root/page-types -p %d -a 0x%lx+%d -Nrl", getpid(), ((unsigned long)ptr) >> 12, size);
	puts(cmd);
	system(cmd);
}

int main(int argc, char **argv) {
	int fd = open(argv[1], O_CREAT|O_RDWR, 0644);
	char *ptr1, *ptr2;
	int size = 2 * 1024 * 1024;

	int shared = strtol(argv[2], NULL, 0);
	int mapflag = MAP_PRIVATE;
	printf("shared %d %d\n", shared, mapflag);
	if (shared)
		mapflag = MAP_SHARED;

	fallocate(fd, 0, 0, size);
	ptr1 = mmap(NULL, size, PROT_READ|PROT_WRITE, mapflag, fd, 0);
	write_region(ptr1, size);
	ptr2 = mmap(NULL, size, PROT_READ|PROT_WRITE, mapflag, fd, 0);
	write_region(ptr2, size);
	printf("p1 %p, p2 %p\n", ptr1, ptr2);

	check_region(ptr1, 3);
	check_region(ptr2, 3);

	madvise(ptr1, size, MADV_DONTNEED);
	madvise(ptr1, 10 * PS, MADV_DONTNEED);

	check_region(ptr1, 3);
	check_region(ptr2, 3);

	madvise(ptr1, 10 * PS, MADV_REMOVE);

	check_region(ptr1, 3);
	check_region(ptr2, 3);
}
