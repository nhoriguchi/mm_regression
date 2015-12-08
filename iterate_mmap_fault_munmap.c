#include <stdio.h>
#include <sys/mman.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

#define ADDR_INPUT	0x700000000000UL
#define HPS		0x200000

int flag = 1;

void sig_handle_flag(int signo) { flag = 0; }

int main(int argc, char *argv[]) {
	char *p;
	char c;
	int protflag = PROT_READ | PROT_WRITE;
	int mapflag = MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB;
	int size = 2 * HPS;
	int thp;

	while ((c = getopt(argc, argv, "n:t")) != -1) {
		switch(c) {
		case 'n':
			size = strtoul(optarg, NULL, 0) * HPS;
			break;
		case 't':
			thp = 1;
			mapflag &= ~MAP_HUGETLB;
			break;
		default:
			perror("invalid option\n");
			return 1;
		}
	}

	signal(SIGUSR1, sig_handle_flag);
	while (flag) {
		p = mmap((void *)ADDR_INPUT, size, protflag, mapflag, -1, 0);
		if (p != (void *)ADDR_INPUT) {
			perror("mmap");
			break;
		}
		memset(p, 0, size);
		munmap(p, size);
	}
}
