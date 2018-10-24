#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>

#define err(x) perror(x),exit(EXIT_FAILURE)

#define BUFSIZE 64

int main(int argc, char *argv[]) {
	unsigned long buf[BUFSIZE];
	int i, j;
	int fd = open("/sys/kernel/mm/page_idle/bitmap", O_RDWR);
	unsigned long offset;

	if (!strcmp(argv[1], "read")) {
		for (i = 0; i < 1024 * 64; i++) {
			offset = i * 8 * BUFSIZE;
			if (pread(fd, (void *)buf, 8 * BUFSIZE, offset) == -1) {
				break;
			}
			/* for (j = 0; j < BUFSIZE; j++) { */
			/* 	if (buf[0]) */
			/* 		printf("i:%d, j:%d, %lx\n", i, j, buf[0]); */
			/* } */
		}
	} else if (!strcmp(argv[1], "write")) {
		for (i = 0; i < BUFSIZE; i++)
			buf[i] = ~0UL;
		/* 1024 * 64 * 64 * 64 => 2^28 pages => 1TB */
		for (i = 0; i < 1024 * 64; i++) {
			offset = i * 8 * BUFSIZE;
			if (pwrite(fd, (void *)buf, 8 * BUFSIZE, offset) == -1) {
				break;
			}
		}
	}
}
