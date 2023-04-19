#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>

#define PS	4096

int main(int argc, char **argv) {
	int ret;
	int fd1, fd2;
	char buf[PS];
	char *ptr;
	int pipefd[2];

	if (argc < 2) {
		fprintf(stderr, "need one argument file_in\n");
		return -1;
	}

	fd1 = open(argv[1], O_CREAT|O_RDWR, 0666);
	if (fd1 < 0) {
		fprintf(stderr, "failed to open file %s\n", argv[1]);
		return -1;
	}
	memset(buf, 'a', PS);
	ret = pwrite(fd1, buf, PS, 0);
	printf("pwrite to fd1 returns %d\n", ret);
	ptr = mmap(NULL, PS, PROT_READ|PROT_WRITE, MAP_SHARED, fd1, 0);
	printf("mmap fd1 address is %p\n", ptr);
	ret = madvise(ptr, PS, MADV_HWPOISON);
	printf("madvise(MADV_HWPOISON) returns %d\n", ret);

	ret = pipe(pipefd);
	if (ret < 0) {
		perror("pipe");
		return -1;
	}
	printf("pipe %d %d\n", pipefd[0], pipefd[1]);

	ret = splice(fd1, NULL, pipefd[1], NULL, PS, SPLICE_F_MOVE);
	printf("splice() returns %d\n", ret);
	if (ret < 0) {
		perror("splice");
		return -1;
	}
	return 0;
}
