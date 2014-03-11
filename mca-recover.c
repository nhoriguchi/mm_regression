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

static int pagesize;

/*
 * get information about address from /proc/{pid}/pagemap
 * Assumes target address is mapped as 4K (not hugepage)
 */
unsigned long long vtop(unsigned long long addr)
{
	unsigned long long pinfo;
	long offset = addr / pagesize * (sizeof pinfo);
	int fd;
	char	pagemapname[64];

	sprintf(pagemapname, "/proc/%d/pagemap", getpid());
	fd = open(pagemapname, O_RDONLY);
	if (fd == -1) {
		perror(pagemapname);
		exit(1);
	}
	if (pread(fd, &pinfo, sizeof pinfo, offset) != sizeof pinfo) {
		perror(pagemapname);
		exit(1);
	}
	close(fd);
	if ((pinfo & (1ull << 63)) == 0) {
		printf("page not present\n");
		exit(1);
	}
	return ((pinfo & 0x007fffffffffffffull) << 12) + (addr & (pagesize - 1));
}

int checksum(unsigned char *addr)
{
	int	i, sum;

	sum = 0;
	for (i = 0; i < pagesize; i++)
		sum += addr[i];
	return sum;
}

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

/*
 * "Recover" from the error by allocating a new page and mapping
 * it at the same virtual address as the page we lost. Fill with
 * the same (trivial) contents.
 */
void recover(int sig, siginfo_t *si, void *v)
{
	struct morebits *m = (struct morebits *)&si->si_addr;
	char	*newbuf;

	printf("recover: sig=%d si=%p v=%p\n", sig, si, v);
	printf("Platform memory error at 0x%p\n", si->si_addr);
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
	phys = vtop((unsigned long long)buf);

	printf("Recovery allocated new page at physical %llx\n", phys);
}

struct sigaction recover_act = {
	.sa_sigaction = recover,
	.sa_flags = SA_SIGINFO,
};

int main(int argc, char **argv)
{
	int	i, sum, rightsum;
	int	iflag = 0;
	int	tflag = 0;
	time_t	now;

	pagesize = getpagesize();

	buf = mmap(NULL, pagesize, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);

	if (buf == MAP_FAILED) {
		fprintf(stderr, "Can't get a single page of memory!\n");
		return 1;
	}
	memset(buf, '*', pagesize);
	rightsum = checksum(buf);
	phys = vtop((unsigned long long)buf);

	printf("vtop(%llx) = %llx\n", (unsigned long long)buf, phys);
	fflush(stdout);

	sigaction(SIGBUS, &recover_act, NULL);

	while (1) {
		sum = checksum(buf);
		if (sum != rightsum) {
			printf("Ooops.  Saw bad checksum %d\n", sum);
			break;
		}
	}

	return 1;
}
