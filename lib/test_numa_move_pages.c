#include <stdio.h>
#include <stdlib.h>
#include <numaif.h>
#include <signal.h>
#include <string.h>
#include <errno.h>

#define ADDR_INPUT	0x700000000000UL
#define HPS		0x200000
#define PS		0x1000

int main(int argc, char *argv[]) {
	int i;
	int nr_hp = strtol(argv[1], NULL, 0);
	int nr_p  = nr_hp * HPS / PS;
	int ret;
	void **addrs;
	int *status;
	int *nodes;
	pid_t pid = strtol(argv[2], NULL, 0);
	int dst = strtol(argv[3], NULL, 0); /* destination node */
	int pct = strtol(argv[4], NULL, 0); /* only pct % of the given range are moved */
	int stat = 0;

	if (argc > 5 && !strcmp(argv[5], "stat"))
		stat = 1;
	
	addrs  = malloc(sizeof(char *) * nr_p + 1);
	status = malloc(sizeof(char *) * nr_p + 1);
	if (stat)
		nodes = NULL;
	else
		nodes  = malloc(sizeof(char *) * nr_p + 1);
	
	for (i = 0; i < nr_p * pct / 100; i++) {
		addrs[i] = (void *)ADDR_INPUT + i * PS;
		if (!stat)
			nodes[i] = dst;
		status[i] = 0;
	}
	ret = move_pages(pid, nr_p, addrs, nodes, status,
						  MPOL_MF_MOVE_ALL);
	if (ret == -1)
		perror("move_pages");
	
	return 0;
}
