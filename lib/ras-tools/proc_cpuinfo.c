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
 * 4) Logical cpu# to apicd mappings
 */
void proc_cpuinfo(int *nsockets, int *ncpus, char *model, int *modelnum, int **apicmap)
{
	FILE	*fp = fopen("/proc/cpuinfo", "r");
	char	*p, line[4096];
	long	apicid, lcpu, s, sockmask = 0;
	int	i, maxcpus = 4;

	*nsockets = 0;
	*ncpus = 0;
	*apicmap = (int *)calloc(sizeof (int), maxcpus);

	if (fp == NULL)
		return;

	while (fgets(line, sizeof line, fp)) {
		if (model[0] == '\0' && strncmp(line, "model name", 10) == 0) {
			p = strchr(&line[10], ':');
			while (isspace(*++p))
				;
			strcpy(model, p);
		} else if (strncmp(line, "model\t", 6) == 0) {
			p = strchr(&line[6], ':');
			*modelnum = atoi(p);
		} else if (strncmp(line, "physical id", 11) == 0) {
			(*ncpus)++;
			p = strchr(&line[10], ':');
			s = strtol(p+1, NULL, 10);
			sockmask |= 1 << s;
		} else if (strncmp(line, "processor", 9) == 0) {
			p = strchr(&line[8], ':');
			lcpu = strtol(p+1, NULL, 10);
		} else if (strncmp(line, "apicid", 6) == 0) {
			p = strchr(&line[5], ':');
			apicid = strtol(p+1, NULL, 10);
			if (lcpu >= maxcpus) {
				maxcpus *= 2;
				*apicmap = realloc(*apicmap, maxcpus * sizeof (int));
			}
			(*apicmap)[lcpu] = apicid;
		}
	}
	for (i = 0; i < 8 * sizeof sockmask; i++)
		if (sockmask & (1l << i))
			(*nsockets)++;

	fclose(fp);
}
