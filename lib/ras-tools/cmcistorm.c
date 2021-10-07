/*
 * Copyright (C) 2015 Intel Corporation
 * Author: Tony Luck
 *
 * This software may be redistributed and/or modified under the terms of
 * the GNU General Public License ("GPL") version 2 only as published by the
 * Free Software Foundation.
 */

/*
 * Allocate memory - use EINJ to inject a bunch of soft errors,
 * then consume them all as fast a possible.
 */
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <ctype.h>

#define EINJ_ETYPE "/sys/kernel/debug/apei/einj/error_type"
#define EINJ_ADDR "/sys/kernel/debug/apei/einj/param1"
#define EINJ_MASK "/sys/kernel/debug/apei/einj/param2"
#define EINJ_NOTRIGGER "/sys/kernel/debug/apei/einj/notrigger"
#define EINJ_DOIT "/sys/kernel/debug/apei/einj/error_inject"

volatile int trigger;

#define	BUFSZ	(64 * 1024)

static void wfile(char *file, unsigned long val)
{
	FILE *fp;
	static int total_errors;

tryagain:
	fp = fopen(file, "w");
	if (fp == NULL) {
		perror(file);
		exit(1);
	}
	fprintf(fp, "0x%lx\n", val);
	if (fclose(fp) == EOF) {
		perror(file);
		if (++total_errors == 10)
			exit(1);
		sleep(3);
		goto tryagain;
	}
}

static void inject(int nerrors, double interval)
{
	char	*b, *buf;
	long long paddr;
	extern long long vtop(char *);
	int	i;
	unsigned long s, e;
	int	bufsz = nerrors * 4096;

	buf = malloc(bufsz);
	if (buf == NULL) {
		perror("malloc");
		exit(1);
	}
	memset(buf, '*', bufsz);

	for (i = 0; i < nerrors; i++) {
		b = buf + i * 4096;
		paddr = vtop(b);

		printf("%d: vaddr = %p paddr = %llx\n", i, b, paddr);
		wfile(EINJ_ADDR, paddr);
		wfile(EINJ_DOIT, 1);

		/* wait a bit to make sure SMI is all done on all cpus */
		usleep((int)(interval * 1.0e6));
	}


	/* Trigger error by reading from target location */
	for (i = 0; i < bufsz; i++)
		trigger += *(buf + i);

	/* wait a bit to allow CMCI handlers to complete */
	usleep((int)(interval * 1.0e6));
}

int main(int argc, char **argv)
{
	int nerrors = (argc > 1) ? atoi(argv[1]) : 20;
	double interval = (argc > 2) ? atof(argv[2]) : 1.0;

	wfile(EINJ_ETYPE, 0x8);
	wfile(EINJ_MASK, ~0x0ul);
	wfile(EINJ_NOTRIGGER, 1);

	inject(nerrors, interval);

	return 0;
}
