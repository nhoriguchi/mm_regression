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

	i = stat("/mnt/pmem/ext4/data1", &st);
	if (i == -1)
		perror("stat");
	printf("inode: %lx\n", st.st_ino);

	fd = open("/mnt/pmem/ext4/date1", O_RDWR|O_CREAT, 0666);
	/* fd = open("/mnt/pmem/ext4/data1", O_RDWR); */
	memset(array, 'a', 4096);
	pwrite(fd, array, 4096, 0);

sprintf(buf, "page-types -p %d -Nrl", getpid());
system(buf);
return 0;

	i = fstat(fd, &st);
	if (i == -1)
		perror("fstat");
	printf("inode: %lx\n", st.st_ino);

	if (!strcmp(argv[1], "true")) {
		printf("MAP_SYNC flag set.\n");
		mmapflag |= MAP_SYNC;
	}

	addr = mmap((void *)ADDR_INPUT, 4096, PROT_READ|PROT_WRITE, mmapflag, fd, 0);
	if (addr == (void *)MAP_FAILED) {
		perror("mmap");
		printf("Faield to mmap(), abort\n");
		return 1;
	}
	printf("addr is %p\n", addr);

	/* system("cat /proc/self/smaps"); */

	for (i = 0; i < 4096; i++)
		addr[i] = 'c';
	fsync(fd);

	sprintf(buf, "cat /proc/%d/numa_maps", getpid());
	system(buf);
	sprintf(buf, "/usr/local/bin/page-types -p %d -Nrl", getpid());
	system(buf);
	return 0;
}
