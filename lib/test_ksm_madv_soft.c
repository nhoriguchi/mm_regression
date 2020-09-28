#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <sys/types.h>
#include <errno.h>
#include <stdlib.h>

#define MADV_SOFT_OFFLINE 101

#define err(x) perror(x),exit(EXIT_FAILURE)

int main() {
	int ret;
	int size = 100000*0x1000;

        char *p1 = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	printf("p1 %p\n", p1);
        char *p2 = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	printf("p2 %p\n", p2);

        ret = madvise(p1, size, MADV_MERGEABLE);
	printf("madvise(p1) %d\n", ret);
        ret = madvise(p2, size, MADV_MERGEABLE);
	printf("madvise(p2) %d\n", ret);

	printf("writing p1 ... ");
        memset(p1, 'a', size);
	printf("done\n");
	printf("writing p2 ... ");
        memset(p2, 'a', size);
	printf("done\n");

	printf("waiting for ksmd to merge the pages\n");
	usleep(10000000);
	printf("call soft offline\n");
        ret = madvise(p1, size, MADV_SOFT_OFFLINE);
	printf("soft offline returns %d\n", ret);
	if (ret)
		err("madvise");

        madvise(p1, size, MADV_UNMERGEABLE);
        madvise(p2, size, MADV_UNMERGEABLE);
	printf("OK\n");
}
