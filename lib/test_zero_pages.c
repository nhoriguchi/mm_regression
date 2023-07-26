#define _GNU_SOURCE 1
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <err.h>
#include <fcntl.h>
#include "test_core/lib/include.h"
#include "lib/pfn.h"

// #define PS	0x1000
#define HPS	0x200000
#define ADDR_INPUT	0x700000000000

int main() {
	int fd;
	int ret;
	char c;
	char *ptr;
	struct pagestat ps;

	ptr = mmap((void *)ADDR_INPUT, HPS, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0);
	if (ptr == (void *)MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	for (int i = 0; i < HPS / PS; i++)
		c = ptr[i * PS];
	get_pagestat(ptr, &ps);
	usleep(1000000000);
}
