// SPDX-License-Identifier: GPL-2.0

/*
 * Copyright (C) 2015 Intel Corporation
 * Author: Tony Luck
 *
 * This software may be redistributed and/or modified under the terms of
 * the GNU General Public License ("GPL") version 2 only as published by the
 * Free Software Foundation.
 */

/*
 * Convert a user mode virtual address belonging to the
 * current process to physical.
 * Does not handle huge pages.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

/*
 * get information about address from /proc/{pid}/pagemap
 */
unsigned long long vtop(unsigned long long addr, pid_t pid)
{
	static int pagesize;
	unsigned long long pinfo;
	long offset;
	int fd;
	char pagemapname[64];

	if (pagesize == 0)
		pagesize = getpagesize();
	offset = addr / pagesize * (sizeof pinfo);

	sprintf(pagemapname, "/proc/%d/pagemap", pid);
	fd = open(pagemapname, O_RDONLY);
	if (fd == -1) {
		perror(pagemapname);
		exit(1);
	}
	if (pread(fd, &pinfo, sizeof pinfo, offset) != sizeof pinfo) {
		perror(pagemapname);
		close(fd);
		exit(1);
	}
	close(fd);
	if ((pinfo & (1ull << 63)) == 0) {
		printf("page not present\n");
		return ~0ull;
	}
	return ((pinfo & 0x007fffffffffffffull) * pagesize) + (addr & (pagesize - 1));
}
