#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/types.h>
#include "test_core/lib/include.h"

#define MAP_THP MAP_PRIVATE|MAP_ANONYMOUS
#define ADDR_INPUT 0x700000000000

void sig_handle(int signo) { ; }

int main(int argc, char *argv[]) {
	int i;
	int protflag = PROT_READ|PROT_WRITE;

	char **thp_addr;
	int nr_hps = 10;
	int length;
	unsigned long exp_addr = ADDR_INPUT;
	int nr_alloc = 1;

	signal(SIGUSR1, sig_handle);

	if (argc > 1)
		nr_hps = strtoul(argv[1], NULL, 10);

	nr_alloc = (nr_hps - 1) / 512 + 1;
	thp_addr = malloc(nr_alloc * sizeof(char *));

	for (i = 0; i < nr_alloc; i++) {
		if (i < nr_alloc)
			length = 512 * THPS;
		else
			length = (((nr_hps - 1) % 512) + 1) * THPS;
		thp_addr[i] = checked_mmap(NULL, length, MMAP_PROT, MAP_THP, -1, 0);
		madvise(thp_addr[i], length, MADV_HUGEPAGE);
		memset(thp_addr[i], 'a', length);
	}
	pause();
	return 0;
}
