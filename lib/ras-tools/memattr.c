/*
 * Copyright (C) 2022 Alibaba Corporation
 * Author: Shuai Xue
 *
 * This software may be redistributed and/or modified under the terms of
 * the GNU General Public License ("GPL") version 2 only as published by the
 * Free Software Foundation.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <setjmp.h>
#include <signal.h>
#define _GNU_SOURCE 1
#define __USE_GNU 1
#include <sched.h>
#include <errno.h>
#include <sys/syscall.h>
#include <linux/futex.h>

typedef struct
{
	int num;
	/*
	 * Any unaligned access to memory region with any Device memory type
	 * attribute generates an Alignment fault. Thus, add a safe padding.
	 */
	char pad[3];
	long long int paddr;
} mpgprot_drv_ctx;

extern unsigned long long vtop(unsigned long long addr, pid_t pid);
#define DEV_NAME "/dev/pgprot_drv"
#define PAGE_SHIFT 12
static mpgprot_drv_ctx *ctx = NULL;
static char *progname;

#define EINJ_ETYPE "/sys/kernel/debug/apei/einj/error_type"
#define EINJ_ETYPE_AVAILABLE "/sys/kernel/debug/apei/einj/available_error_type"
#define EINJ_ADDR "/sys/kernel/debug/apei/einj/param1"
#define EINJ_MASK "/sys/kernel/debug/apei/einj/param2"
#define EINJ_APIC "/sys/kernel/debug/apei/einj/param3"
#define EINJ_FLAGS "/sys/kernel/debug/apei/einj/flags"
#define EINJ_NOTRIGGER "/sys/kernel/debug/apei/einj/notrigger"
#define EINJ_DOIT "/sys/kernel/debug/apei/einj/error_inject"
#define EINJ_VENDOR "/sys/kernel/debug/apei/einj/vendor"

static int is_privileged(void)
{
	if (getuid() != 0) {
		fprintf(stderr, "%s: must be root to run error injection tests\n", progname);
		return 0;
	}
	return 1;
}

static void wfile(char *file, unsigned long long val)
{
	FILE *fp;

	fp = fopen(file, "w");
	if (fp == NULL)
	{
		fprintf(stderr, "%s: cannot open '%s'\n", progname, file);
		exit(1);
	}
	fprintf(fp, "0x%llx\n", val);
	if (fclose(fp) == EOF)
	{
		fprintf(stderr, "%s: write error on '%s'\n", progname, file);
		exit(1);
	}
}

static void inject_uc(unsigned long long addr, void *vaddr, int notrigger)
{
	wfile(EINJ_ETYPE, 0x20);
	wfile(EINJ_ADDR, addr);
	wfile(EINJ_MASK, ~0x0ul);
	wfile(EINJ_FLAGS, 2);
	wfile(EINJ_NOTRIGGER, notrigger);
	wfile(EINJ_DOIT, 1);
}

int trigger_write(char *addr)
{
	addr[0] = 0x69;
	return 0;
}

#define ONE p = (char **)*p;
#define FIVE ONE ONE ONE ONE ONE
#define TEN FIVE FIVE
#define FIFTY TEN TEN TEN TEN TEN
#define HUNDRED FIFTY FIFTY

static int poison = 0;
static int bench = 0;
int main(int argc, char *argv[])
{
	int kfd, c;
	long long paddr;
	void *vaddr;

	progname = argv[0];
	if (!is_privileged())
		exit(1);
	while ((c = getopt(argc, argv, "pb")) != -1)
		switch (c)
		{
		case 'p':
			poison = 1;
			break;
		case 'b':
			bench = 1;
			break;
		}

	kfd = open(DEV_NAME, O_RDWR | O_NDELAY);
	if (kfd < 0)
	{
		printf("open file %s error: Is the pgprot_drv.ko module loaded?\n", DEV_NAME);
		return -1;
	}

	vaddr = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, kfd, 0);
	if (vaddr == MAP_FAILED)
	{
		printf("allocate mem fail %d!!!\n", 4096);
		exit(1);
	}

	ctx = (mpgprot_drv_ctx *)vaddr;
	printf("check ctx: vaddr = %p, num %d, paddr %llx\n", vaddr, ctx->num, ctx->paddr);

	if (bench)
	{
		struct timeval tv1, tv2;
		int memsize = 4096;
		int stride = 128;
		int size = memsize / stride;
		unsigned *indices = malloc(size * sizeof(int));
		int i, count, tmp;
		struct timezone tz;
		char *mem = vaddr;
		unsigned long sec, usec;

		for (i = 0; i < size; i++)
			indices[i] = i;

		// trick 2: fill mem with pointer references
		for (i = 0; i < size - 1; i++)
			*(char **)&mem[indices[i] * stride] = (char *)&mem[indices[i + 1] * stride];
		*(char **)&mem[indices[size - 1] * stride] = (char *)&mem[indices[0] * stride];

		register char **p = (char **)mem;
		tmp = count / 100;

		gettimeofday(&tv1, &tz);
		for (i = 0; i < tmp; ++i)
		{
			HUNDRED;
		}
		gettimeofday(&tv2, &tz);

		if (tv2.tv_usec < tv1.tv_usec)
		{
			usec = 1000000 + tv2.tv_usec - tv1.tv_usec;
			sec = tv2.tv_sec - tv1.tv_sec - 1;
		}
		else
		{
			usec = tv2.tv_usec - tv1.tv_usec;
			sec = tv2.tv_sec - tv1.tv_sec;
		}

		/* touch pointer p to prevent compiler optimization */
		char **touch = p;
		printf("Buffer size: %ld KB, stride %d, time %d.%06d s, latency %.2f ns\n",
		       memsize / 1024, stride, sec, usec, (sec * 1000000 + usec) * 1000.0 / (tmp * 100));
	}

	if (poison)
	{
		/* pick from kernel */
		long long int paddr = ctx->paddr;
		printf("vaddr = %p paddr = %llx\n", vaddr, paddr);
		inject_uc(paddr, vaddr, 1);
		sleep(3);
		trigger_write(vaddr);
	}

	munmap(ctx, 4096);

	return 0;
}
