/*
 * Usage:
 *   ./test_dax <devdax_device_path> <memsize> <iotype> [<iosize>]
 *   ./test_dax <fsdax_file_path> <memsize> <iotype> [<iosize>]
 *
 *   - iotype: read, write, sysread, syswrite
 */

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
#include <sys/types.h>
#include <sys/syscall.h>
#include <linux/stat.h>
#include <sys/xattr.h>
#include <sys/ioctl.h>
#include <sys/ioctl.h>
#include <linux/fs.h>

#define GB      0x40000000UL

/* perform synchronous page faults for the mapping */
#define MAP_SYNC        0x80000
#define ALIGN(x, a)     (((x) + (a) - 1) & ~((a) - 1))
#define PAGE_ALIGN(x)     ALIGN(x, 4096)

#define PAGE_SIZE 4096
#define ADDR_INPUT 0x700000000000
#define HPS             0x200000

#define MADV_HWPOISON   100

#define AT_EMPTY_PATH	0x1000
#define AT_STATX_SYNC_TYPE      0x6000
#define AT_STATX_SYNC_AS_STAT   0x0000
#define AT_STATX_FORCE_SYNC     0x2000
#define AT_STATX_DONT_SYNC      0x4000
#define AT_EMPTY_PATH	0x1000
#define STATX_ALL	0x00000fffU

char *path;

unsigned long chunk_size(int index, unsigned long size) {
	unsigned long tmp = size - index * GB;
	return tmp > GB ? GB : tmp;
}

void prepare_fsdax_file(int fd, unsigned long size) {
	int i;
	char *buf = malloc(HPS);

	memset(buf, 'a', HPS);
	for (i = 0; i < size / HPS; i++)
		pwrite(fd, buf, HPS, i*HPS);
	free(buf);
}

static void sigbus_handler(int sig, siginfo_t *siginfo, void *ptr)
{
	printf("SIGBUS:%d, si_code:0x%lx, si_status:0x%lx\n", sig, siginfo->si_code, siginfo->si_status);
	exit(EXIT_FAILURE);
}

int main(int argc, char **argv)
{
	int i;
	int fd;
	int ret;
	char **addr;
	int mmapflag = MAP_SHARED;
	unsigned long size = HPS;
	char *iotype;
	unsigned long iosize = HPS;
	int nr_mmaps;
	struct sigaction act;
	struct stat filestat;
	struct statx filestatx;
	long repeat = 0;
	unsigned long mapsync = 0;
	unsigned long nowarmup = 0;
	unsigned long norepeat = 0;

	if (getenv("REPEATS"))
		repeat = strtoul(getenv("REPEATS"), NULL, 0);
	if (getenv("MAP_SYNC"))
		mapsync = strtoul(getenv("MAP_SYNC"), NULL, 0);
	if (getenv("NO_WARMUP"))
		nowarmup = strtoul(getenv("NO_WARMUP"), NULL, 0);
	if (getenv("NO_REPEAT"))
		norepeat = strtoul(getenv("NO_REPEAT"), NULL, 0);

	memset (&act, 0, sizeof(act));
	act.sa_sigaction = sigbus_handler;
	act.sa_flags = SA_SIGINFO;

	if (sigaction(SIGBUS, &act, 0)) {
		perror ("sigaction");
		return 1;
	}

	if (argc > 1)
		path = argv[1];
	if (argc > 2)
		size = strtoul(argv[2], NULL, 0);
	if (argc > 3)
		iotype = argv[3];
	if (argc > 4)
		iosize = strtoul(argv[4], NULL, 0);

	prctl(PR_SET_DUMPABLE, 1);

	// one mmap region per 1GB
	nr_mmaps = (size - 1UL) / GB + 1UL;

	fd = open(path, O_RDWR|O_CREAT, 0666);
	if (fd == -1) {
		fprintf(stderr, "Failed to open devdax device or fsdax file.");
		exit(EXIT_FAILURE);
	}

	if (mapsync)
		mmapflag |= MAP_SYNC;

	if (getenv("SET_STATX_ATTR_DAX")) {
		int attr;

		ret = ioctl(fd, FS_IOC_GETFLAGS, &attr);
		if (ret < 0) {
			perror ("ioctl(FS_IOC_GETFLAGS)");
			exit(EXIT_FAILURE);
		}
		attr |= FS_DAX_FL;
		ret = ioctl(fd, FS_IOC_SETFLAGS, &attr);
		if (ret < 0) {
			perror ("ioctl(FS_IOC_SETFLAGS)");
			exit(EXIT_FAILURE);
		}
	}

	addr = malloc(sizeof(char *) * nr_mmaps);
	if (!addr) {
		fprintf(stderr, "Failed to malloc.");
		exit(EXIT_FAILURE);
	}

	// warmup for fsdax file
	if (!nowarmup) {
		fstat(fd, &filestat);
		if ((filestat.st_mode & S_IFMT) == S_IFREG) {
			printf("Warmup ... ");
			prepare_fsdax_file(fd, size);
			printf("done.\n");
		}
	}

	if (syscall(SYS_statx, fd, path, AT_STATX_FORCE_SYNC|AT_EMPTY_PATH, STATX_ALL, &filestatx)) {
		perror ("statx");
		exit(EXIT_FAILURE);
	}

	printf("size: 0x%lx, iosize: 0x%lx, iotype:%s, nr_mmaps:0x%lx, repeat:%d, mmapflag:%lx, xattr:%lx\n", size, iosize, iotype, nr_mmaps, repeat, mmapflag, filestatx.stx_attributes);
	if (!strcmp(iotype, "write")
	    || !strcmp(iotype, "read")
	    || !strcmp(iotype, "pmem_memset_write")
	    || !strcmp(iotype, "pmem_memset_persist_write")
	    || !strcmp(iotype, "pmem_memcpy_read")) {
		for (i = 0; i < nr_mmaps; i++) {
			addr[i] = mmap((void *)ADDR_INPUT + i * GB, chunk_size(i, size), PROT_READ|PROT_WRITE, mmapflag, fd, i * GB);
			if (addr[i] == (void *)MAP_FAILED) {
				perror("mmap");
				printf("If you try mmap()ing for devdax device, make sure that the mapping size is aligned to devdax block size (might be 2MB).\n");
				return 1;
			}
		}

		if (!strcmp(iotype, "write")) {
			printf("writing ...\n");
			while (1) {
				for (i = 0; i < size/iosize; i++) {
					/* printf("write %p\n", addr[(i * iosize) / GB] + (i * iosize) % GB); */
					memset(addr[(i * iosize) / GB] + (i * iosize) % GB, 'c', iosize);
					if (!(--repeat))
						exit(EXIT_SUCCESS);
				}
				if (norepeat)
					break;
			}
		} else if (!strcmp(iotype, "read")) {
			char **buf = malloc(iosize);
			if (!buf) {
				perror("malloc");
				return 1;
			}
			printf("reading ...\n");
			while (1) {
				for (i = 0; i < size/iosize; i++) {
					// printf("read %p\n", addr[(i * iosize) / GB] + (i * iosize) % GB);
					memcpy(buf, addr[(i * iosize) / GB] + (i * iosize) % GB, iosize);
					if (!(--repeat))
						exit(EXIT_SUCCESS);
				}
				if (norepeat)
					break;
			}
			free(buf);
		}
	} else if (!strcmp(iotype, "syswrite")) {
		char **buf = malloc(iosize);
		if (!buf) {
			perror("malloc");
			return 1;
		}
		memset(buf, 'x', iosize);
		printf("sys writing ...\n");
		while (1) {
			for (i = 0; i < size/iosize; i++) {
				ret = pwrite(fd, buf, iosize, i*iosize);
				if (ret == -1) {
					perror("pwrite");
					return 1;
				}
				if (!(--repeat)) {
					fsync(fd);
					exit(EXIT_SUCCESS);
				}
			}
			if (norepeat)
				break;
		}
		free(buf);
	} else if (!strcmp(iotype, "sysread")) {
		char **buf = malloc(iosize);
		if (!buf) {
			perror("malloc");
			return 1;
		}
		printf("sys reading ...\n");
		while (1) {
			for (i = 0; i < size/iosize; i++) {
				ret = pread(fd, buf, iosize, i*iosize);
				if (ret == -1) {
					perror("pread");
					return 1;
				}
				if (!(--repeat))
					exit(EXIT_SUCCESS);
			}
			if (norepeat)
				break;
		}
		free(buf);
	} else {
		fprintf(stderr, "Invalid iotype %s.", iotype);
		exit(EXIT_FAILURE);
	}
}
