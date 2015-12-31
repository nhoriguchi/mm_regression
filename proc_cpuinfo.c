/*
 * Copyright (C) 2015 Intel Corporation
 * Author: Tony Luck
 *
 * This software may be redistributed and/or modified under the terms of
 * the GNU General Public License ("GPL") version 2 only as published by the
 * Free Software Foundation.
 */

#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <string.h>

/*
 * read /proc/cpuinfo to discover:
 * 1) number of cpu sockets
 * 2) Number of logical cpus
 * 3) Model name of the cpu
 */
void proc_cpuinfo(int *nsockets, int *ncpus, char *model)
{
	FILE	*fp = fopen("/proc/cpuinfo", "r");
	char	*p, line[4096];
	long	s, sockmask = 0;
	int	i;

	*nsockets = 0;
	*ncpus = 0;

	if (fp == NULL)
		return;

	while (fgets(line, sizeof line, fp)) {
		if (model[0] == '\0' && strncmp(line, "model name", 10) == 0) {
			p = strchr(&line[10], ':');
			while (isspace(*++p))
				;
			strcpy(model, p);
		} else if (strncmp(line, "physical id", 11) == 0) {
			(*ncpus)++;
			p = strchr(&line[10], ':');
			s = strtol(p+1, NULL, 10);
			sockmask |= 1 << s;
		}
	}
	for (i = 0; i < 8 * sizeof sockmask; i++)
		if (sockmask & (1l << i))
			(*nsockets)++;

	fclose(fp);
}
