#include <stdio.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>
#include <asm/unistd.h>
#include <string.h>
#include <stdlib.h>
#include <getopt.h>
#include <stdint.h>
#include <limits.h>
#include "test_core/lib/include.h"
#include "lib/pfn.h"
#include "lib/hugepage.h"

/*
 * on x86_64
 *  PMD_SHIFT 21   0x000000200000
 *  PUD_SHIFT 30   0x000040000000
 *  PGD_SHIFT 39   0x008000000000
 */

#define ADDR_INPUT 0x700000000000

int flag = 1;

void sig_handle_flag(int signo) { flag = 0; }

int checked_mincore(void *addr, size_t length, unsigned char *vec) {
	int ret = mincore(addr, length, vec);
	if (ret)
		err("mincore");
	return ret;
}

void show_mincore_map(char *tag, size_t length, unsigned char *vec) {
	int i;
	char *p = malloc(256 + length/PS);
	int idx = sizeof(tag) + 1;
	sprintf(p, "%s:", tag);
	for (i = 0; i < length/PS; i++)
		p[idx+i] = vec[i] ? '1' : '0';
	p[idx+i] = '\n';
	p[idx+i+1] = '\0';
	pprintf(p);
}

int main(int argc, char *argv[]) {
	int i;
	int nr = 2;
	int ret;
	int fd = -1;
	char c;
	char *p;
	unsigned long memsize = 2*1024*1024;
	int mapflag = MAP_ANONYMOUS;
	unsigned long offset;
	unsigned long address = ADDR_INPUT;
	char *pmem;
	char *phugetlb;
	char *pthp;
	char *pmem_unaligned;
	char *pfile;
	char *psmall1, *psmall2;
	char *file = NULL;
	char *vec;
	uint64_t pme[1024];
	unsigned long type = 0xffff;

	while ((c = getopt(argc, argv, "p:n:vf:t:")) != -1) {
		switch(c) {
		case 'p':
			testpipe = optarg;
			{
				struct stat stat;
				lstat(testpipe, &stat);
				if (!S_ISFIFO(stat.st_mode))
					errmsg("Given file is not fifo.\n");
			}
			break;
		case 'n':
			nr = strtoul(optarg, NULL, 10);
			memsize = nr * PS;
			break;
		case 'v':
			verbose = 1;
			break;
		case 'f':
			file = optarg;
			break;
		case 't':
			type = strtoul(optarg, NULL, 0);
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	if (type & (1 << 0)) {
		mapflag = MAP_PRIVATE|MAP_ANONYMOUS;
		pmem = checked_mmap((void *)address, memsize, MMAP_PROT, mapflag, -1, 0);
		madvise(pmem, memsize, MADV_NOHUGEPAGE);
		memset(pmem, 'a', memsize/2);
		address += memsize;
	}

	if (type & (1 << 1)) {
		mapflag = MAP_PRIVATE|MAP_ANONYMOUS|MAP_HUGETLB;
		phugetlb = checked_mmap((void *)address, memsize, MMAP_PROT, mapflag, -1, 0);
		memset(phugetlb, 'a', 1);
		address += memsize;
	}

	pprintf_wait(SIGUSR1, "start check\n");
	if (type & (1 << 2)) {
		mapflag = MAP_PRIVATE|MAP_ANONYMOUS;
		pthp = checked_mmap((void *)address, memsize, MMAP_PROT, mapflag, -1, 0);
		memset(pthp, 'a', 1);
		/* check we really have thp. */
		for (offset = 0; offset < memsize; offset += HPS) {
			if (!check_kpflags(pthp + offset, KPF_THP))
				errmsg("address 0x%x is not backed by THP.",
				       pthp + offset);
		}
		address += memsize;
	}

	/* unaligned vma */
	if (type & (1 << 3)) {
		mapflag = MAP_PRIVATE|MAP_ANONYMOUS;
		pmem_unaligned = checked_mmap((void *)address, memsize, MMAP_PROT, mapflag, -1, 0);
		madvise(pmem_unaligned, memsize, MADV_NOHUGEPAGE);
		munmap(pmem_unaligned, memsize/4);
		munmap(pmem_unaligned + memsize*3/4, memsize/2);
		pmem_unaligned = pmem_unaligned + memsize/4;
		memset(pmem_unaligned, 'a', memsize/2/2);
		address += memsize;
	}

	if (type & (1 << 4)) {
		/* hole file */
		if (file) {
			mapflag = MAP_SHARED;
			fd = checked_open(file, O_RDWR);
			pfile = checked_mmap((void *)address, 4*memsize, MMAP_PROT, mapflag, fd, 0);
			printf("pfile(for mincore5) %lx\n", pfile);
			memset(pfile, 'a', PS);
			memset(pfile + 4*memsize-2*PS, 'a', PS);
			address += memsize*4;
		}
	}

	if (type & (1 << 5)) {
		/* small vmas in a single pmd */
		printf("%lx\n", address);
		mapflag = MAP_PRIVATE|MAP_ANONYMOUS;
		psmall1 = checked_mmap((void *)address, 2*PS, MMAP_PROT, mapflag, -1, 0);
		psmall2 = checked_mmap((void *)address+4*PS, 2*PS, MMAP_PROT, mapflag, -1, 0);
		memset(psmall1, 'a', PS);
		memset(psmall2, 'a', PS);
		address += memsize;
	}

	signal(SIGUSR1, sig_handle_flag);

	vec = checked_malloc(4*memsize/PS);
	if (type & (1 << 0)) {
		checked_mincore(pmem, memsize, vec);
		show_mincore_map("mincore1", memsize, vec);
	}
	if (type & (1 << 1)) {
		checked_mincore(phugetlb, memsize, vec);
		show_mincore_map("mincore2", memsize, vec);
	}
	if (type & (1 << 2)) {
		checked_mincore(pthp, memsize, vec);
		show_mincore_map("mincore3", memsize, vec);
	}
	if (type & (1 << 3)) {
		checked_mincore(pmem_unaligned, memsize/2, vec);
		show_mincore_map("mincore4", memsize/2, vec);
	}
	if (type & (1 << 4)) {
		if (file) {
			checked_mincore(pfile, 4*memsize, vec);
			show_mincore_map("mincore5", 4*memsize, vec);
		}
	}
	if (type & (1 << 5)) {
		checked_mincore(psmall1, 2*PS, vec);
		show_mincore_map("mincore6", 2*PS, vec);
		checked_mincore(psmall2, 2*PS, vec);
		show_mincore_map("mincore7", 2*PS, vec);
	}

	pprintf("entering busy loop\n");
	while (flag) {
		usleep(1000);
		if (type & (1 << 0))
			memset(pmem, 'a', memsize);
		if (type & (1 << 1))
			memset(phugetlb, 'a', memsize);
		if (type & (1 << 2))
			memset(pthp, 'a', memsize);
		if (type & (1 << 3))
			memset(pmem_unaligned, 'a', memsize/2);
		if (type & (1 << 4)) {
			if (file) {
				memset(pfile, 'a', 2*PS);
				memset(pfile + 4*memsize-2*PS, 'a', 2*PS);
			}
		}
		if (type & (1 << 5)) {
			memset(psmall1, 'a', PS);
			memset(psmall2, 'a', PS);
		}
	}

	pprintf_wait(SIGUSR1, "mincore exit\n");
	return 0;
}
