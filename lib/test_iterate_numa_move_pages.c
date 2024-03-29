#include <stdio.h>
#include <stdlib.h>
#include <numaif.h>
#include <signal.h>

#define ADDR_INPUT	0x700000000000UL
#define HPS		0x200000
#define PS		0x1000

#define err(x) perror(x),exit(EXIT_FAILURE)

int flag = 1;

void sig_handle_flag(int signo) { flag = 0; }

int main(int argc, char *argv[]) {
	int i;
	int nr_hp = strtol(argv[1], NULL, 0);
	int nr_p  = nr_hp * HPS / PS;
	int ret;
	void **addrs;
	int *status;
	int *nodes;
	pid_t pid;

	pid = strtol(argv[2], NULL, 0);
	addrs  = malloc(sizeof(char *) * nr_p + 1);
	status = malloc(sizeof(char *) * nr_p + 1);
	nodes  = malloc(sizeof(char *) * nr_p + 1);

	signal(SIGUSR1, sig_handle_flag);
	while (flag) {
		for (i = 0; i < nr_p; i++) {
			addrs[i] = (void *)ADDR_INPUT + i * PS;
			nodes[i] = 1;
			status[i] = 0;
		}
		ret = move_pages(pid, nr_p, addrs, nodes, status,
				      MPOL_MF_MOVE_ALL);
		if (ret == -1)
			err("move_pages");

		for (i = 0; i < nr_p; i++) {
			addrs[i] = (void *)ADDR_INPUT + i * PS;
			nodes[i] = 0;
			status[i] = 0;
		}
		ret = move_pages(pid, nr_p, addrs, nodes, status,
				      MPOL_MF_MOVE_ALL);
		if (ret == -1)
			err("move_pages");
	}
	return 0;
}
