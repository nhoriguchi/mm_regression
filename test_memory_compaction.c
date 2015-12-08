/*
 * Stress test for transparent huge pages, memory compaction and migration.
 *
 * Authors: Konstantin Khlebnikov <koct9i@gmail.com>
 *
 * This is free and unencumbered software released into the public domain.
 */

#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <err.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include "test_core/lib/include.h"
#include <signal.h>

int flag = 1;

void sig_handle(int signo) { ; }
void sig_handle_flag(int signo) { flag = 0; }

#define ADDR_INPUT 0x700000000000

#define PAGE_SHIFT 12
#define HPAGE_SHIFT 21

#define PAGE_SIZE (1 << PAGE_SHIFT)
#define HPAGE_SIZE (1 << HPAGE_SHIFT)

void allocate_transhuge(void *ptr)
{
	uint64_t ent[2];
	int i;

	/* drop pmd */
	if (mmap(ptr, HPAGE_SIZE, PROT_READ | PROT_WRITE,
		 MAP_FIXED | MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE, -1, 0) != ptr)
		err("mmap transhuge");

	if (madvise(ptr, HPAGE_SIZE, MADV_HUGEPAGE))
		err("MADV_HUGEPAGE");

	/* allocate transparent huge page */
	for (i = 0; i < (1 << (HPAGE_SHIFT - PAGE_SHIFT)); i++) {
		*(volatile void **)(ptr + i * PAGE_SIZE) = ptr;
	}
}

int main(int argc, char **argv)
{
	char c;
	size_t ram, len;
	void *ptr, *p;
	struct timespec a, b;
	double s;
	uint8_t *map;
	size_t map_len;

	while ((c = getopt(argc, argv, "p:v")) != -1) {
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
		case 'v':
			verbose = 1;
			break;
		default:
			errmsg("invalid option\n");
			break;
		}
	}

	ram = sysconf(_SC_PHYS_PAGES);
	if (ram > SIZE_MAX / sysconf(_SC_PAGESIZE) / 4)
		ram = SIZE_MAX / 4;
	else
		ram *= sysconf(_SC_PAGESIZE);
	Dprintf("===> %lx, %d\n", ram, argc);
	len = ram;
	Dprintf("===> %lx\n", len);
	signal(SIGUSR1, sig_handle);
	pprintf_wait(SIGUSR1, "test_memory_compaction start\n");

	len -= len % HPAGE_SIZE;
	ptr = mmap((void *)ADDR_INPUT, len + HPAGE_SIZE, PROT_READ | PROT_WRITE,
			MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE, -1, 0);

	if (madvise(ptr, len, MADV_HUGEPAGE))
		err("MADV_HUGEPAGE");

	signal(SIGUSR1, sig_handle_flag);
	pprintf("busyloop\n");

	while (flag) {
		for (p = ptr; p < ptr + len; p += HPAGE_SIZE) {
			allocate_transhuge(p);
			/* split transhuge page, keep last page */
			if (madvise(p, HPAGE_SIZE - PAGE_SIZE, MADV_DONTNEED))
				err("MADV_DONTNEED");
		}
	}

	pprintf_wait(SIGUSR1, "referenced\n");

	pprintf_wait(SIGUSR1, "test_memory_compaction exit\n");
	return 0;
}

/* #include <stdio.h> */
/* #include <stdlib.h> */
/* #include <signal.h> */
/* #include <string.h> */
/* #include <unistd.h> */
/* #include <sys/mman.h> */
/* #include <sys/types.h> */
/* #include <sys/ipc.h> */
/* #include <sys/shm.h> */
/* #include <stdint.h> */
/* #include "test_core/lib/include.h" */

/* int flag = 1; */

/* void sig_handle(int signo) { ; } */
/* void sig_handle_flag(int signo) { flag = 0; } */

/* #define ADDR_INPUT 0x700000000000 */

/* #define PAGE_SHIFT 12 */
/* #define HPAGE_SHIFT 21 */

/* #define PAGE_SIZE (1 << PAGE_SHIFT) */
/* #define HPAGE_SIZE (1 << HPAGE_SHIFT) */


/* void allocate_transhuge(void *ptr) */
/* { */
/* 	uint64_t ent[2]; */
/* 	int i; */

/* 	/\* drop pmd *\/ */
/* 	if (mmap(ptr, HPAGE_SIZE, PROT_READ | PROT_WRITE, */
/* 		 MAP_FIXED | MAP_ANONYMOUS | MAP_NORESERVE | MAP_PRIVATE, -1, 0) != ptr) */
/* 		errx("mmap transhuge"); */

/* 	if (madvise(ptr, HPAGE_SIZE, MADV_HUGEPAGE)) */
/* 		err("MADV_HUGEPAGE"); */

/* 	/\* allocate transparent huge page *\/ */
/* 	for (i = 0; i < (1 << (HPAGE_SHIFT - PAGE_SHIFT)); i++) { */
/* 		*(volatile void **)(ptr + i * PAGE_SIZE) = ptr; */
/* 	} */
/* } */

/* int main(int argc, char *argv[]) */
/* { */
/* 	char c; */
/* 	int i, j; */
/* 	int nr = 1024; */
/* 	int nr_hp = nr / 512; */
/* 	int size; */
/* 	unsigned long pos = ADDR_INPUT; */
/* 	int ret; */
/* 	char *file; */
/* 	int fd; */
/* 	char *pfile; */
/* 	char *panon; */
/* 	char *pthp; */
/* 	char *phugetlb; */

/* 	while ((c = getopt(argc, argv, "p:n:v")) != -1) { */
/* 		switch(c) { */
/* 		case 'p': */
/* 			testpipe = optarg; */
/* 			{ */
/* 				struct stat stat; */
/* 				lstat(testpipe, &stat); */
/* 				if (!S_ISFIFO(stat.st_mode)) */
/* 					errmsg("Given file is not fifo.\n"); */
/* 			} */
/* 			break; */
/* 		case 'n': */
/* 			nr = strtoul(optarg, NULL, 0); */
/* 			nr_hp = nr / 512; */
/* 			size = nr * PS; */
/* 			break; */
/* 		case 'v': */
/* 			verbose = 1; */
/* 			break; */
/* 		default: */
/* 			errmsg("invalid option\n"); */
/* 			break; */
/* 		} */
/* 	} */

/* 	nr = sysconf(_SC_PHYS_PAGES) / 2; */
/* 	nr -= nr % 512; */
/* 	size = nr * sysconf(_SC_PAGESIZE); */
/* 	nr_hp = nr / 512; */

/* 	signal(SIGUSR1, sig_handle); */
/* 	pprintf_wait(SIGUSR1, "test_memory_compaction start\n"); */
/* printf("%lx\n", size); */
/* 	panon = checked_mmap((void *)pos, size, MMAP_PROT, */
/* 		 MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE, -1, 0); */
/* 	if (madvise(panon, size, MADV_HUGEPAGE)) */
/* 		err("MADV_HUGEPAGE"); */
/* 	printf("panon %p\n", panon); */

/* 	/\* pprintf_wait(SIGUSR1, "faulted-in\n"); *\/ */

/* 	signal(SIGUSR1, sig_handle_flag); */
/* 	pprintf("busyloop\n"); */
/* 	while (flag) { */
/* 		void *p; */

/* 		for (p = panon; p < panon + size; p += HPAGE_SIZE) { */
/* 			allocate_transhuge(p); */
/* 			if (madvise(p, HPAGE_SIZE - PAGE_SIZE, MADV_DONTNEED)) */
/* 				err("MADV_DONTNEED"); */
/* 		} */
/* 	} */
/* 	sleep(1); */

/* 	pprintf_wait(SIGUSR1, "referenced\n"); */

/* 	pprintf_wait(SIGUSR1, "test_memory_compaction exit\n"); */
/* 	return 0; */
/* } */
