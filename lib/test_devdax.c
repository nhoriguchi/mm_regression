#include <sys/mman.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

#define MADV_HWPOISON   100

#define MAP_SYNC        0x80000         /* perform synchronous page faults for the mapping */

#define ALIGN(x, a)     (((x) + (a) - 1) & ~((a) - 1))
#define PAGE_ALIGN(x)     ALIGN(x, 4096)

#define ADDR_INPUT 0x700000000000

#define ALLOC_SIZE 0x200000

int main(int argc, char **argv)
{
	int ret;
	int i;
	int fd;
	char *array = malloc(4096);
	char *addr;
	int mmapflag = MAP_SHARED;
	char buf[256];
	struct stat st;

	fd = open("/dev/dax0.0", O_RDWR, 0666);
	printf("fd: %d\n", fd);
	memset(array, 'a', 4096);
	pwrite(fd, array, 4096, 0);

	i = fstat(fd, &st);
	if (i == -1)
		perror("fstat");
	printf("inode: %lx\n", st.st_ino);

	if (!strcmp(argv[1], "true")) {
		printf("MAP_SYNC flag set.\n");
		mmapflag |= MAP_SYNC;
	}

	printf("calling mmap() ...\n");
	addr = mmap((void *)ADDR_INPUT, ALLOC_SIZE, PROT_READ|PROT_WRITE, mmapflag, fd, 0);
	printf("addr is %p\n", addr);
	if (addr == (void *)MAP_FAILED) {
		perror("mmap");
		printf("Failed to mmap(), abort\n");
		return 1;
	}

	/* system("cat /proc/self/smaps"); */

	for (i = 0; i < ALLOC_SIZE; i++)
		addr[i] = 'c';

	sprintf(buf, "cat /proc/%d/numa_maps", getpid());
	system(buf);
	return 0;
}
