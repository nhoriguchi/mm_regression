#include <stdio.h>
#include <sys/types.h> /* for getpid, getpagesize */
#include <unistd.h>
#include <sys/stat.h>  /* for open */
#include <fcntl.h>
#include <stdlib.h>    /* for exit */
#include <stdint.h>    /* for uint64_t */
#include <limits.h>    /* for ULONG_MAX */

struct pagestat {
	unsigned long pfn;
	unsigned long pflags;
	unsigned long pcount;
};

static int pagemap_fd;
static int kpageflags_fd;
static int kpagecount_fd;
static int hwpoison_inject_fd;
static int soft_offline_fd;

/* pagemap kernel ABI bits */
#define PM_ENTRY_BYTES      sizeof(uint64_t)
#define PM_STATUS_BITS      3
#define PM_STATUS_OFFSET    (64 - PM_STATUS_BITS)
#define PM_STATUS_MASK      (((1LL << PM_STATUS_BITS) - 1) << PM_STATUS_OFFSET)
#define PM_STATUS(nr)       (((nr) << PM_STATUS_OFFSET) & PM_STATUS_MASK)
#define PM_PSHIFT_BITS      6
#define PM_PSHIFT_OFFSET    (PM_STATUS_OFFSET - PM_PSHIFT_BITS)
#define PM_PSHIFT_MASK      (((1LL << PM_PSHIFT_BITS) - 1) << PM_PSHIFT_OFFSET)
#define PM_PSHIFT(x)        (((u64) (x) << PM_PSHIFT_OFFSET) & PM_PSHIFT_MASK)
#define PM_PFRAME_MASK      ((1LL << PM_PSHIFT_OFFSET) - 1)
#define PM_PFRAME(x)        ((x) & PM_PFRAME_MASK)

#define PM_PRESENT          PM_STATUS(4LL)
#define PM_SWAP             PM_STATUS(2LL)

static unsigned long do_u64_read(int fd, char *name,
				 uint64_t *buf,
				 unsigned long index,
				 unsigned long count)
{
        long bytes;

        if (index > ULONG_MAX / 8) {
                fprintf(stderr, "index overflow: %lu\n", index);
		exit(EXIT_FAILURE);
	}

        if (lseek(fd, index * 8, SEEK_SET) < 0) {
                perror(name);
                exit(EXIT_FAILURE);
        }

        if ((bytes = read(fd, buf, count * 8)) < 0) {
                perror(name);
                exit(EXIT_FAILURE);
        }

        if (bytes % 8) {
                fprintf(stderr, "partial read: %lu bytes\n", bytes);
		exit(EXIT_FAILURE);
	}

        return bytes / 8;
}

static unsigned long pagemap_read(uint64_t *buf,
				  unsigned long index,
				  unsigned long pages) {
	return do_u64_read(pagemap_fd, "/proc/pid/pagemap", buf, index, pages);
}

static unsigned long pagemap_pfn(uint64_t val) {
        unsigned long pfn;

        if (val & PM_PRESENT)
                pfn = PM_PFRAME(val);
        else
                pfn = 0;

        return pfn;
}

int get_pfn(void *vaddr, uint64_t *buf, int pid, int count) {
	char filename[128];
	uint64_t *tmpbuf = (uint64_t *)malloc(8 * count);
	int ret;
	unsigned long index = ((unsigned long)vaddr) / getpagesize();
	int i;

	if (!pid)
		pid = getpid();

	sprintf(filename, "/proc/%d/pagemap", pid);
	pagemap_fd = checked_open(filename, O_RDONLY);
	ret = pagemap_read(tmpbuf, index, count);
	if (ret < count)
		err("pagemap_read");
	checked_close(pagemap_fd);
	for (i = 0; i < ret; i++)
		buf[i] = pagemap_pfn(tmpbuf[i]);
	free(tmpbuf);
	return ret;
}

static unsigned long kpageflags_read(uint64_t *buf,
				    unsigned long index,
				    unsigned long pages) {
	return do_u64_read(kpageflags_fd, "/proc/kpageflags", buf, index, pages);
}

int get_pflags(unsigned long pfn, uint64_t *buf, int count) {
	uint64_t *tmpbuf = (uint64_t *)malloc(8 * count);
	int pages;
	int i;

	if ((kpageflags_fd = open("/proc/kpageflags", O_RDONLY)) < 0) {
		perror("opening /proc/kpageflags");
		exit(EXIT_FAILURE);
	}
	pages = kpageflags_read(tmpbuf, pfn, 1);
	for (i = 0; i < pages; i++) {
		buf[i] = tmpbuf[i];
	}
	close(kpageflags_fd);
	free(tmpbuf);
	return pages;
}

static unsigned long kpagecount_read(uint64_t *buf,
				    unsigned long index,
				    unsigned long pages) {
	return do_u64_read(kpagecount_fd, "/proc/kpagecount", buf, index, pages);
}

int get_pcount(unsigned long pfn, uint64_t *buf, int count) {
	uint64_t *tmpbuf = (uint64_t *)malloc(8 * count);
	int pages;
	int i;

	if ((kpagecount_fd = open("/proc/kpagecount", O_RDONLY)) < 0) {
		perror("reading /proc/kpagecount");
		exit(EXIT_FAILURE);
	}
	pages = kpagecount_read(tmpbuf, pfn, 1);
	for (i = 0; i < pages; i++) {
		buf[i] = tmpbuf[i];
	}
	close(kpagecount_fd);
	free(tmpbuf);
	return pages;
}

int kick_hard_offline(unsigned long pfn) {
	int len;
	char buf[128];

	if ((hwpoison_inject_fd = open("/sys/kernel/debug/hwpoison/corrupt-pfn",
				       O_WRONLY)) < 0) {
		perror("open debugfs:/hwpoison/corrupt-pfn");
		return 1;
	}
	len = sprintf(buf, "0x%lx\n", pfn);
	if ((len = write(hwpoison_inject_fd, buf, len)) < 0) {
		perror("kick hard offline");
		return 1;
	}
	close(hwpoison_inject_fd);
	return 0;
}

int kick_soft_offline(unsigned long pfn) {
	int len;
	char buf[128];

	if ((soft_offline_fd = open("/sys/devices/system/memory/soft_offline_page",
				    O_WRONLY)) < 0) {
		perror("open /sys/devices/system/memory/soft_offline_page");
		return 1;
	}
	len = sprintf(buf, "0x%lx000\n", pfn);
	if ((len = write(soft_offline_fd, buf, len)) < 0) {
		perror("kick soft offline");
		return 1;
	}
	close(soft_offline_fd);
	return 0;
}

void get_pagestat(char *vaddr, struct pagestat *ps) {
	get_pfn(vaddr, &ps->pfn, getpid(), 1);
	get_pflags(ps->pfn, &ps->pflags, 1);
	get_pcount(ps->pfn, &ps->pcount, 1);
	printf("pfn 0x%lx, page flags 0x%016lx, page count %ld\n",
	       ps->pfn, ps->pflags, ps->pcount);
}

unsigned long get_my_pfn(char *vaddr) {
	char filename[128];
	uint64_t tmpbuf;
	int ret;

	sprintf(filename, "/proc/%d/pagemap", getpid());
	pagemap_fd = checked_open(filename, O_RDONLY);
	ret = pagemap_read(&tmpbuf, ((unsigned long)vaddr) / getpagesize(), 1);
	if (ret != 1)
		err("pagemap_read");
	checked_close(pagemap_fd);
	return pagemap_pfn(tmpbuf);
}

int get_my_pflags(unsigned long pfn) {
	uint64_t tmpbuf;
	int pages;
	int i;

	if ((kpageflags_fd = open("/proc/kpageflags", O_RDONLY)) < 0) {
		perror("opening /proc/kpageflags");
		exit(EXIT_FAILURE);
	}
	pages = kpageflags_read(&tmpbuf, pfn, 1);
	close(kpageflags_fd);
	return tmpbuf;
}

int check_kpflags(char *vaddr, unsigned long kpf) {
        unsigned long pfn = get_my_pfn(vaddr);
        unsigned long kpflags = get_my_pflags(pfn);
	printf("pfn %lx, flags %x, ret %lx\n", pfn, kpflags, kpflags & (1 << kpf));
        return kpflags & (1 << kpf);
}
