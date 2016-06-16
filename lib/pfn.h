#ifndef _TEST_CORE_LIB_PFN_H
#define _TEST_CORE_LIB_PFN_H

#include <stdio.h>
#include <sys/types.h> /* for getpid, getpagesize */
#include <unistd.h>
#include <sys/stat.h>  /* for open */
#include <fcntl.h>
#include <stdlib.h>    /* for exit */
#include <stdint.h>    /* for uint64_t */
#include <limits.h>    /* for ULONG_MAX */
#include <errno.h>

#include "/src/linux-dev/include/uapi/linux/kernel-page-flags.h"

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

/*
 * pagemap kernel ABI bits
 */

#define PM_ENTRY_BYTES		8
#define PM_PFRAME_BITS		55
#define PM_PFRAME_MASK		((1LL << PM_PFRAME_BITS) - 1)
#define PM_PFRAME(x)		((x) & PM_PFRAME_MASK)
#define PM_SOFT_DIRTY		(1ULL << 55)
#define PM_MMAP_EXCLUSIVE	(1ULL << 56)
#define PM_FILE			(1ULL << 61)
#define PM_SWAP			(1ULL << 62)
#define PM_PRESENT		(1ULL << 63)

/***********************************************************************
 * Borrowed lots of code from tools/vm/page-types.c tool
 ***********************************************************************/

#ifndef MAX_PATH
# define MAX_PATH 256
#endif

#ifndef STR
# define _STR(x) #x
# define STR(x) _STR(x)
#endif

#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))

static void fatal(const char *x, ...)
{
	va_list ap;

	va_start(ap, x);
	vfprintf(stderr, x, ap);
	va_end(ap);
	exit(EXIT_FAILURE);
}

static unsigned long long parse_number(const char *str)
{
	unsigned long long n;

	n = strtoll(str, NULL, 0);

	if (n == 0 && str[0] != '0')
		fatal("invalid name or number: %s\n", str);

	return n;
}

/*
 * kernel page flags
 */

#define KPF_BYTES		8
#define PROC_KPAGEFLAGS		"/proc/kpageflags"

/* [32-] kernel hacking assistances */
#define KPF_RESERVED		32
#define KPF_MLOCKED		33
#define KPF_MAPPEDTODISK	34
#define KPF_PRIVATE		35
#define KPF_PRIVATE_2		36
#define KPF_OWNER_PRIVATE	37
#define KPF_ARCH		38
#define KPF_UNCACHED		39
#define KPF_SOFTDIRTY		40

/* [48-] take some arbitrary free slots for expanding overloaded flags
 * not part of kernel API
 */
#define KPF_READAHEAD		48
#define KPF_SLOB_FREE		49
#define KPF_SLUB_FROZEN		50
#define KPF_SLUB_DEBUG		51
#define KPF_FILE		62
#define KPF_MMAP_EXCLUSIVE	63

#define KPF_ALL_BITS		((uint64_t)~0ULL)
#define KPF_HACKERS_BITS	(0xffffULL << 32)
#define KPF_OVERLOADED_BITS	(0xffffULL << 48)
#define BIT(name)		(1ULL << KPF_##name)
#define BITS_COMPOUND		(BIT(COMPOUND_HEAD) | BIT(COMPOUND_TAIL))

#define KPF_ZERO_PAGE	24
#define KPF_IDLE	25

static const char * const page_flag_names[] = {
	[KPF_LOCKED]		= "L:locked",
	[KPF_ERROR]		= "E:error",
	[KPF_REFERENCED]	= "R:referenced",
	[KPF_UPTODATE]		= "U:uptodate",
	[KPF_DIRTY]		= "D:dirty",
	[KPF_LRU]		= "l:lru",
	[KPF_ACTIVE]		= "A:active",
	[KPF_SLAB]		= "S:slab",
	[KPF_WRITEBACK]		= "W:writeback",
	[KPF_RECLAIM]		= "I:reclaim",
	[KPF_BUDDY]		= "B:buddy",

	[KPF_MMAP]		= "M:mmap",
	[KPF_ANON]		= "a:anonymous",
	[KPF_SWAPCACHE]		= "s:swapcache",
	[KPF_SWAPBACKED]	= "b:swapbacked",
	[KPF_COMPOUND_HEAD]	= "H:compound_head",
	[KPF_COMPOUND_TAIL]	= "T:compound_tail",
	[KPF_HUGE]		= "G:huge",
	[KPF_UNEVICTABLE]	= "u:unevictable",
	[KPF_HWPOISON]		= "X:hwpoison",
	[KPF_NOPAGE]		= "n:nopage",
	[KPF_KSM]		= "x:ksm",
	[KPF_THP]		= "t:thp",
	[KPF_BALLOON]		= "o:balloon",
	[KPF_ZERO_PAGE]		= "z:zero_page",
	[KPF_IDLE]              = "i:idle_page",

	[KPF_RESERVED]		= "r:reserved",
	[KPF_MLOCKED]		= "m:mlocked",
	[KPF_MAPPEDTODISK]	= "d:mappedtodisk",
	[KPF_PRIVATE]		= "P:private",
	[KPF_PRIVATE_2]		= "p:private_2",
	[KPF_OWNER_PRIVATE]	= "O:owner_private",
	[KPF_ARCH]		= "h:arch",
	[KPF_UNCACHED]		= "c:uncached",
	[KPF_SOFTDIRTY]		= "f:softdirty",

	[KPF_READAHEAD]		= "I:readahead",
	[KPF_SLOB_FREE]		= "P:slob_free",
	[KPF_SLUB_FROZEN]	= "A:slub_frozen",
	[KPF_SLUB_DEBUG]	= "E:slub_debug",

	[KPF_FILE]		= "F:file",
	[KPF_MMAP_EXCLUSIVE]	= "1:mmap_exclusive",
};

static int		opt_raw;	/* for kernel developers */

/* only one filter supported (unlikely with upstream) */
#define MAX_BIT_FILTERS	1
static int		nr_bit_filters;
static uint64_t		opt_mask[MAX_BIT_FILTERS];
static uint64_t		opt_bits[MAX_BIT_FILTERS];

/*
 * page flag filters
 */

static int bit_mask_ok(uint64_t flags)
{
	int i;

	for (i = 0; i < nr_bit_filters; i++) {
		if (opt_bits[i] == KPF_ALL_BITS) {
			if ((flags & opt_mask[i]) == 0)
				return 0;
		} else {
			if ((flags & opt_mask[i]) != opt_bits[i])
				return 0;
		}
	}

	return 1;
}

static uint64_t expand_overloaded_flags(uint64_t flags, uint64_t pme)
{
	/* SLOB/SLUB overload several page flags */
	if (flags & BIT(SLAB)) {
		if (flags & BIT(PRIVATE))
			flags ^= BIT(PRIVATE) | BIT(SLOB_FREE);
		if (flags & BIT(ACTIVE))
			flags ^= BIT(ACTIVE) | BIT(SLUB_FROZEN);
		if (flags & BIT(ERROR))
			flags ^= BIT(ERROR) | BIT(SLUB_DEBUG);
	}

	/* PG_reclaim is overloaded as PG_readahead in the read path */
	if ((flags & (BIT(RECLAIM) | BIT(WRITEBACK))) == BIT(RECLAIM))
		flags ^= BIT(RECLAIM) | BIT(READAHEAD);

	if (pme & PM_SOFT_DIRTY)
		flags |= BIT(SOFTDIRTY);
	if (pme & PM_FILE)
		flags |= BIT(FILE);
	if (pme & PM_MMAP_EXCLUSIVE)
		flags |= BIT(MMAP_EXCLUSIVE);

	return flags;
}

static uint64_t well_known_flags(uint64_t flags)
{
	/* hide flags intended only for kernel hacker */
	flags &= ~KPF_HACKERS_BITS;

	/* hide non-hugeTLB compound pages */
	if ((flags & BITS_COMPOUND) && !(flags & BIT(HUGE)))
		flags &= ~BITS_COMPOUND;

	return flags;
}

static uint64_t kpageflags_flags(uint64_t flags, uint64_t pme)
{
	if (opt_raw)
		flags = expand_overloaded_flags(flags, pme);
	else
		flags = well_known_flags(flags);

	return flags;
}

static void add_bits_filter(uint64_t mask, uint64_t bits)
{
	if (nr_bit_filters >= MAX_BIT_FILTERS)
		fatal("too much bit filters\n");
	opt_mask[nr_bit_filters] = mask;
	opt_bits[nr_bit_filters] = bits;
	nr_bit_filters++;
}

static unsigned long do_u64_read(int fd, char *name,
				 uint64_t *buf,
				 unsigned long index,
				 unsigned long count)
{
	long bytes;

	if (index > ULONG_MAX / 8)
		fatal("index overflow: %lu\n", index);

	bytes = pread(fd, buf, count * 8, (off_t)index * 8);
	if (bytes < 0) {
		perror(name);
		exit(EXIT_FAILURE);
	}
	if (bytes % 8)
		fatal("partial read: %lu bytes\n", bytes);

	return bytes / 8;
}

static unsigned long pagemap_read(uint64_t *buf,
				  unsigned long index,
				  unsigned long pages) {
	return do_u64_read(pagemap_fd, "/proc/pid/pagemap", buf, index, pages);
}

static unsigned long kpageflags_read(uint64_t *buf,
				    unsigned long index,
				    unsigned long pages) {
	return do_u64_read(kpageflags_fd, "/proc/kpageflags", buf, index, pages);
}

static unsigned long kpagecount_read(uint64_t *buf,
				    unsigned long index,
				    unsigned long pages) {
	return do_u64_read(kpagecount_fd, "/proc/kpagecount", buf, index, pages);
}

static unsigned long pagemap_pfn(uint64_t val) {
        unsigned long pfn;

        if (val & PM_PRESENT)
                pfn = PM_PFRAME(val);
        else
                pfn = 0;

        return pfn;
}

static uint64_t parse_flag_name(const char *str, int len)
{
	size_t i;

	if (!*str || !len)
		return 0;

	if (len <= 8 && !strncmp(str, "compound", len))
		return BITS_COMPOUND;

	for (i = 0; i < ARRAY_SIZE(page_flag_names); i++) {
		if (!page_flag_names[i])
			continue;
		if (!strncmp(str, page_flag_names[i] + 2, len))
			return 1ULL << i;
	}

	return parse_number(str);
}

static uint64_t parse_flag_names(const char *str, int all)
{
	const char *p    = str;
	uint64_t   flags = 0;

	while (1) {
		if (*p == ',' || *p == '=' || *p == '\0') {
			if ((*str != '~') || (*str == '~' && all && *++str))
				flags |= parse_flag_name(str, p - str);
			if (*p != ',')
				break;
			str = p + 1;
		}
		p++;
	}

	return flags;
}

static void parse_bits_mask(const char *optarg)
{
	uint64_t mask;
	uint64_t bits;
	const char *p;

	p = strchr(optarg, '=');
	if (p == optarg) {
		mask = KPF_ALL_BITS;
		bits = parse_flag_names(p + 1, 0);
	} else if (p) {
		mask = parse_flag_names(optarg, 0);
		bits = parse_flag_names(p + 1, 0);
	} else if (strchr(optarg, '~')) {
		mask = parse_flag_names(optarg, 1);
		bits = parse_flag_names(optarg, 0);
	} else {
		mask = parse_flag_names(optarg, 0);
		bits = KPF_ALL_BITS;
	}

	add_bits_filter(mask, bits);
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

int get_pflags(unsigned long pfn, uint64_t *buf, int count) {
	/* uint64_t *tmpbuf = (uint64_t *)malloc(8 * count); */
	int pages;
	int i;

	if ((kpageflags_fd = open("/proc/kpageflags", O_RDONLY)) < 0) {
		perror("opening /proc/kpageflags");
		exit(EXIT_FAILURE);
	}
	/* TODO */
#if 0
	pages = kpageflags_read(tmpbuf, pfn, 1);
	for (i = 0; i < pages; i++) {
		buf[i] = tmpbuf[i];
	}
#endif
	pages = pread(kpageflags_fd, buf, pages * 8, pfn) / 8;
	close(kpageflags_fd);
#if 0
	free(tmpbuf);
#endif
	return pages;
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

#endif /* _TEST_CORE_LIB_PFN_H */
