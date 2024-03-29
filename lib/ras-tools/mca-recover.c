// SPDX-License-Identifier: GPL-2.0

/*
 * Copyright (C) 2013 Intel Corporation
 * Authors: Tony Luck
 *
 * This software may be redistributed and/or modified under the terms of
 * the GNU General Public License ("GPL") version 2 only as published by the
 * Free Software Foundation.
 */

/*
 * Set up to get zapped by a machine check (injected elsewhere)
 * recovery function reports physical address of new page - so
 * we can inject to that and repeat over and over.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/mman.h>

extern unsigned long long vtop(unsigned long long addr, pid_t pid);
static int pagesize;

/*
 * Older glibc headers don't have the si_addr_lsb field in the siginfo_t
 * structure ... ugly hack to get it
 */
struct morebits {
	void	*addr;
	short	lsb;
};

char	*buf;
unsigned long long	phys;
int tried_recovery;
pid_t pid;

/*
 * "Recover" from the error by allocating a new page and mapping
 * it at the same virtual address as the page we lost. Fill with
 * the same (trivial) contents.
 */
void recover(int sig, siginfo_t *si, void *v)
{
	struct morebits *m = (struct morebits *)&si->si_addr;
	char	*newbuf;

	tried_recovery = 1;
	printf("recover: sig=%d si=%p v=%p\n", sig, si, v);
	printf("Platform memory error at %p\n", si->si_addr);
	printf("addr = %p lsb=%d\n", m->addr, m->lsb);

	newbuf = mmap(buf, pagesize, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_FIXED|MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);
	if (newbuf == MAP_FAILED) {
		fprintf(stderr, "Can't get a single page of memory!\n");
		exit(1);
	}
	if (newbuf != buf) {
		fprintf(stderr, "Could not allocate at original virtual address\n");
		exit(1);
	}
	buf = newbuf;
	memset(buf, '*', pagesize);
	phys = vtop((unsigned long long)buf, pid);

	printf("Recovery allocated new page at physical 0x%llx\n", phys);
}

struct sigaction recover_act = {
	.sa_sigaction = recover,
	.sa_flags = SA_SIGINFO,
};

int consume_poison(void)
{
	return *(volatile char *)buf;
}

int main(int argc, char **argv)
{
	int	i;
	char	reply[100];

	pagesize = getpagesize();

	buf = mmap(NULL, pagesize, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);

	if (buf == MAP_FAILED) {
		fprintf(stderr, "Can't get a single page of memory!\n");
		return 1;
	}
	pid = getpid();
	memset(buf, '*', pagesize);
	phys = vtop((unsigned long long)buf, pid);

	printf("vtop(%llx) = %llx\n", (unsigned long long)buf, phys);
	printf("Use /sys/kernel/debug/apei/einj/... to inject\n");
	printf("Then press <ENTER> to access:");
	fflush(stdout);

	sigaction(SIGBUS, &recover_act, NULL);

	if (fgets(reply, sizeof reply, stdin) == NULL)
		printf("\nI said 'Press <ENTER>'. Continuing anyway\n");

	i = consume_poison();

	if (tried_recovery == 0) {
		fprintf(stderr, "%s: didn't trigger error\n", argv[0]);
		return 1;
	}
	if (i != '*') {
		fprintf(stderr, "%s: triggered error, but got bad data\n", argv[0]);
		return 1;
	}

	printf("Successful recovery\n");
	return 0;
}
