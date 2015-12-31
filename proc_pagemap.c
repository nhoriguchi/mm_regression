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
 * get information about address from /proc/self/pagemap
 */
unsigned long long vtop(unsigned long long addr)
{
	static int pagesize;
	unsigned long long pinfo;
	long offset;
	int fd;

	if (pagesize == 0)
		pagesize = getpagesize();
	offset = addr / pagesize * (sizeof pinfo);
	fd = open("/proc/self/pagemap", O_RDONLY);
	if (fd == -1) {
		perror("pagemap");
		exit(1);
	}
	if (pread(fd, &pinfo, sizeof pinfo, offset) != sizeof pinfo) {
		perror("pagemap");
		exit(1);
	}
	close(fd);
	if ((pinfo & (1ull << 63)) == 0) {
		printf("page not present\n");
		return ~0ull;
	}
	return ((pinfo & 0x007fffffffffffffull) << 12) + (addr & (pagesize - 1));
}
