/*
 * Author: Naoya Horiguchi <n-horiguchi@ah.jp.nec.com>
 */
#define _GNU_SOURCE 1
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <getopt.h>
#include <sys/mman.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/types.h>
#include <sys/prctl.h>
#include <sys/wait.h>

#include "test_core/lib/include.h"
#include "test_core/lib/hugepage.h"

#define ADDR_INPUT  0x700000000000

#define ALLOCPAGE   4096
#define ALLOCBYTE   ALLOCPAGE*PSIZE
#define VADDR       0x700000000000
#define VADDRINT    0x001000000000

#define SEGNR	7
char *p[SEGNR];
int fd[4];

int flag = 1;

void sig_handle(int signo) { flag = 0; }

void do_mmap() {
	int i;

	/* anon */
	p[0] = checked_mmap((void*)VADDR + VADDRINT * 0, ALLOCBYTE, MMAP_PROT,
			    MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	/* thp */
	p[1] = checked_mmap((void*)VADDR + VADDRINT * 1, ALLOCBYTE, MMAP_PROT,
			    MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	/* file shared */
	p[2] = checked_mmap((void*)VADDR + VADDRINT * 2, ALLOCBYTE, MMAP_PROT,
			    MAP_SHARED, fd[0], 0);
	/* file private */
	p[3] = checked_mmap((void*)VADDR + VADDRINT * 3, ALLOCBYTE, MMAP_PROT,
			    MAP_PRIVATE, fd[1], 0);
	/* hugetlb shared */
	p[4] = checked_mmap((void*)VADDR + VADDRINT * 4, ALLOCBYTE, MMAP_PROT,
			    MAP_SHARED|MAP_ANONYMOUS|MAP_HUGETLB, -1, 0);
	/* hugetlb private */
	p[5] = checked_mmap((void*)VADDR + VADDRINT * 5, ALLOCBYTE, MMAP_PROT,
			    MAP_PRIVATE|MAP_ANONYMOUS|MAP_HUGETLB, -1, 0);
	/* shm hugetlb */
	p[6] = alloc_shm_hugepage(ALLOCBYTE);

	/* Forbid readahead and ksm merging, which could kill TP with SIGBUS */
	for (i = 0; i < SEGNR; i++) {
		madvise(p[i], ALLOCBYTE, MADV_RANDOM);
		madvise(p[i], ALLOCBYTE, MADV_UNMERGEABLE);
		madvise(p[i], ALLOCBYTE, MADV_NOHUGEPAGE);
		/* printf("p[%d] = %p\n", i, p[i]); */
	}
	madvise(p[1], ALLOCBYTE, MADV_HUGEPAGE);
}

void do_munmap() {
	checked_munmap(p[0], ALLOCBYTE);
	checked_munmap(p[1], ALLOCBYTE);
	checked_munmap(p[2], ALLOCBYTE);
	checked_munmap(p[3], ALLOCBYTE);
	checked_munmap(p[4], ALLOCBYTE);
	checked_munmap(p[5], ALLOCBYTE);
	free_shm_hugepage(shmkey, p[6]);
}

void do_access() {
	int i, j;

	for (i = 0; i < ALLOCPAGE; i++)
		for (j = 0; j < SEGNR; j++)
			p[j][i * PSIZE] = 'a';
}

int main(int argc, char *argv[])
{
	char *addr;
	int i, j;
	char c;
	int nr_hps = 2;
	char buf[PSIZE];
	int map_unmap_iteration = 0;

	signal(SIGUSR1, sig_handle);

	while ((c = getopt(argc, argv, "vp:n:m")) != -1) {
		switch (c) {
		case 'v':
			verbose = 1;
			break;
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
			nr_hps = strtol(optarg, NULL, 10);
			break;
		case 'm':
			map_unmap_iteration = 1;
			break;
		}
	}

	for (i = 0; i < 4; i++) {
		char fname[PSIZE];
		sprintf(fname, "/root/testfile%d", i+1);
		fd[i] = open(fname, O_RDWR|O_CREAT, 0644);
		if (fd[i] == -1)
			err("open");
		memset(buf, 'a', PSIZE);
		for (j = 0; j < ALLOCPAGE; j++)
			write(fd[i], buf, PSIZE);
		fsync(fd[i]);
	}

	if (map_unmap_iteration) {
		pprintf("memeater_random prepared\n");
		while (flag) {
			do_mmap();
			do_access();
			do_munmap();
		}
	} else {
		do_mmap();
		do_access();
		pprintf("memeater_random prepared\n");
		while (flag)
			do_access();
		do_munmap();
	}

	pprintf_wait(SIGUSR1, "memeater_random exit\n");
	return 0;
}
