#define _GNU_SOURCE
#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <error.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include "../test_core/lib/include.h"

int pipefd = 1;
int flag = 1;

void sig_handle_flag(int signo) {
	pprintf("Received SIGUSR1\n");
	flag = 0;
}

static void sigbus_handler(int sig, siginfo_t *siginfo, void *ptr)
{
	pprintf("Received SIGBUS\n");
	pprintf("SIGBUS:%d, si_code:0x%lx, si_status:0x%lx\n",
		sig, siginfo->si_code, siginfo->si_status);
	exit(EXIT_FAILURE);
}

#define ADDR_INPUT	0x700000000000UL
#define MADV_SOFT_OFFLINE 101

struct sigaction sa = {
	.sa_sigaction = sigbus_handler,
	.sa_flags = SA_SIGINFO,
};

void setup_signal_handler() {
	signal(SIGUSR1, sig_handle_flag);
	if (sigaction(SIGBUS, &sa, 0)) {
		perror("sigaction");
		return;
	}
}

struct op_control {
	char *name;
	int wait_before;
	int wait_after;
	char *tag;
	char **args;
	char **keys;
	char **values;
	int nr_args;
};

static int opc_defined(struct op_control *opc, char *key) {
	int i;

	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->keys[i], key))
			return 1;
	}
	return 0;
}

static char *opc_get_value(struct op_control *opc, char *key) {
	int i;

	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->keys[i], key)) {
			if (!strcmp(opc->values[i], ""))
				return NULL;
			else
				return opc->values[i];
		}
	}
	return NULL;
}

static char *opc_set_value(struct op_control *opc, char *key, char *value) {
	int i;

	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->keys[i], key)) {
			/* existing value is overwritten */
			/* TODO: error check? */
			return strcpy(opc->values[i], value);
		}
	}
	/* key not found in existing args, so new arg is added */
	/* TODO: remove arg? */
	opc->keys[i] = calloc(1, 64);
	opc->values[i] = calloc(1, 64);
	opc->nr_args++;
	strcpy(opc->keys[i], key);
	strcpy(opc->values[i], value);
	return NULL;
}

static void print_opc(struct op_control *opc) {
	int i;

	Dprintf("===> op_name:%s", opc->name);
	for (i = 0; i < opc->nr_args; i++) {
		if (!strcmp(opc->values[i], ""))
			Dprintf(", %s", opc->keys[i]);
		else
			Dprintf(", %s=%s", opc->keys[i], opc->values[i]);
	}
	Dprintf("\n");
}

static int parse_operation_arg(struct op_control *opc) {
	int i, j;
	int supported;

	for (i = 0; i < opc->nr_args; i++) {
		opc->keys[i] = calloc(1, 64);
		opc->values[i] = calloc(1, 64);

		sscanf(opc->args[i], "%[^=]=%s", opc->keys[i], opc->values[i]);

		if (!strcmp(opc->keys[i], "wait_before")) {
			opc->wait_before = 1;
			continue;
		}
		if (!strcmp(opc->keys[i], "wait_after")) {
			opc->wait_after = 1;
			continue;
		}
		if (!strcmp(opc->keys[i], "tag")) {
			opc->tag = opc->values[i];
			continue;
		}
	}
	return 0;
}

char *op_args[256];
static void parse_operation_args(struct op_control *opc, char *str) {
	char delimiter[] = ":";
	char *ptr;
	int i = 0, j, k;
	char buf[256];

	memset(opc, 0, sizeof(struct op_control));
	strcpy(buf, str);

	/* TODO: need overrun check */
	opc->name = malloc(256);
	opc->args = malloc(10 * sizeof(void *));
	opc->keys = malloc(10 * sizeof(void *));
	opc->values = malloc(10 * sizeof(void *));

	ptr = strtok(buf, delimiter);
	strcpy(opc->name, ptr);
	while (1) {
		ptr = strtok(NULL, delimiter);
		if (!ptr)
			break;
		opc->args[i++] = ptr;
	}
	opc->nr_args = i;

	parse_operation_arg(opc);
	// print_opc(opc);
}

static void do_wait_before(struct op_control *opc) {
	char *sleep = opc_get_value(opc, "wait_before");
	char wait_key_string[256];

	if (!opc->wait_before)
		return;

	if (opc->tag)
		sprintf(wait_key_string, "before_%s_%s", opc->name, opc->tag);
	else
		sprintf(wait_key_string, "before_%s", opc->name);

	if (sleep) {
		unsigned int sleep_us = strtoul(sleep, NULL, 0);

		Dprintf("wait %d usecs %s\n", sleep_us, wait_key_string);
		usleep(sleep_us);
	} else {
		pprintf("%s\n", wait_key_string);
		pause();
	}
}

static void do_wait_after(struct op_control *opc) {
	char *sleep = opc_get_value(opc, "wait_after");
	char wait_key_string[256];

	if (!opc->wait_after)
		return;

	if (opc->tag)
		sprintf(wait_key_string, "after_%s_%s", opc->name, opc->tag);
	else
		sprintf(wait_key_string, "after_%s", opc->name);

	if (sleep) {
		unsigned int sleep_us = strtoul(sleep, NULL, 0);

		Dprintf("wait %d usecs %s\n", sleep_us, wait_key_string);
		usleep(sleep_us);
	} else {
		pprintf("%s\n", wait_key_string);
		pause();
	}
}

/*
 * Testing logic is from here.
 */

long size;
char *ghp;

static int do_allocate_anon(struct op_control *opc) {
	ghp = mmap((void *)ADDR_INPUT, size, PROT_READ|PROT_WRITE,
		 MAP_ANONYMOUS|MAP_PRIVATE|MAP_HUGETLB|(30 << 26), -1, 0);
	if (ghp == (void *)-1) {
		perror("mmap");
		return 1;
	}
	Dprintf("anonymous hugetlb allocation ok: %p %d\n", ghp, getpid());
	return 0;
}

static int do_free_anon(struct op_control *opc) {
	munmap(ghp, size);
}

int ghfd = 0;

static int do_allocate_file(struct op_control *opc) {
	char buf[8192];

	if (ghfd <= 0) {
		ghfd = open("tmp/hugetlbfs/testfile", O_CREAT|O_RDWR);
		if (ghfd == -1) {
			puts("opening hugetlbfs file failed");
			return 1;
		}

		memset(buf, 'c', 8192);
		pwrite(ghfd, buf, 8192, 0);
	}

	ghp = mmap((void *)ADDR_INPUT, size, PROT_READ|PROT_WRITE, MAP_SHARED, ghfd, 0);
	if (ghp == (void *)-1) {
		perror("mmap");
		return 1;
	}
	Dprintf("file hugetlb allocation ok: %p\n", ghp);
	return 0;
}

static int do_free_file(struct op_control *opc) {
	munmap(ghp, size);
}

static int do_allocate_shmem(struct op_control *opc) {
	int shmid;
	int flags = IPC_CREAT | SHM_R | SHM_W | SHM_HUGETLB | 30 << 26;

	if ((shmid = shmget(0, 1, flags)) < 0) {
		perror("shmget");
		return 1;
	}
	ghp = shmat(shmid, (void *)ADDR_INPUT, 0);
	if (ghp == (char *)-1) {
		perror("Shared memory attach failure");
		shmctl(shmid, IPC_RMID, NULL);
		return 1;
	}
	Dprintf("shmem hugetlb allocation ok: %p\n", ghp);
	return 0;
}

static int do_allocate(struct op_control *opc) {
	int ret = 1;
	char *type = opc_get_value(opc, "type");

	if (!strcmp(type, "anon")) {
		ret = do_allocate_anon(opc);
	} else if (!strcmp(type, "file")) {
		ret = do_allocate_file(opc);
	} else if (!strcmp(type, "shmem")) {
		ret = do_allocate_shmem(opc);
	} else {
		pprintf("Invalid hugepage type: %s\n", type);
	}
	return ret;
}

static int do_access(struct op_control *opc) {
	int ret = 0;
	char buf[4096];
	char *access = opc_get_value(opc, "type");

	if (!access)
		access = "memwrite";

	if (!strcmp(access, "memread")) {
		memcpy(buf, ghp, 4096);
	} else if (!strcmp(access, "memwrite")) {
		memset(ghp, 'x', size);
	} else if (!strcmp(access, "sysread")) {
		ret = pread(ghfd, buf, 4096, 0);
		if (ret != 4096) {
			perror("pread");
			ret = 1;
		} else {
			ret = 0;
		}
	} else if (!strcmp(access, "syswrite")) {
		memset(buf, 'y', 4096);
		ret = pwrite(ghfd, buf, 4096, 0);
		if (ret != 4096) {
			perror("pwrite");
			ret = 1;
		} else {
			ret = 0;
		}
	}
	return ret;
}

static int do_madvise(struct op_control *opc) {
	int ret;
	char *advice = opc_get_value(opc, "advice");

	if (!strcmp(advice, "hwpoison")) {
		ret = madvise(ghp, 4096, MADV_HWPOISON);
	} else if (!strcmp(advice, "soft-offline")) {
		ret = madvise(ghp, 4096, MADV_SOFT_OFFLINE);
	} else if (!strcmp(advice, "dontneed")) {
		ret = madvise(ghp, size, MADV_DONTNEED);
	}
	return ret;
}

static int do_iterate_mapping(struct op_control *opc) {
	int ret = 1;
	char *type = opc_get_value(opc, "type");

	flag = 1;

	if (!strcmp(type, "anon")) {
		while (flag) {
			ret = do_allocate_anon(opc);
			if (ret)
				break;
			memset(ghp, 'y', size);
			munmap(ghp, size);
		}
	} else if (!strcmp(type, "file")) {
		while (flag) {
			ret = do_allocate_file(opc);
			if (ret)
				break;
			memset(ghp, 'y', size);
			munmap(ghp, size);
		}
	} else if (!strcmp(type, "shmem")) {
		pprintf("Not implemented yet for hugepage type: %s\n", type);
	} else {
		pprintf("Invalid hugepage type: %s\n", type);
	}
}

static int do_fork(struct op_control *opc) {
	pid_t pid;

	pid = fork();
	if (pid) { // parent
		int cstatus;

		pprintf("forked %d\n", pid);
		wait(&cstatus);
		pprintf("child exited %d\n", cstatus);
	} else { // child
		int c;
		c = ghp[0];
		pause();
	}
}

static int do_mremap(struct op_control *opc) {
	char *type = opc_get_value(opc, "type");
	int back = 0; //*(int *)args; /* 0: +offset, 1: -offset*/
	void *new;

	if (back) {
		pprintf("mremap p:%p -> %p\n", ghp, ghp + size);
		new = mremap(ghp + size, size, size, MREMAP_MAYMOVE|MREMAP_FIXED, ghp);
	} else {
		pprintf("mremap p:%p -> %p\n", ghp + size, ghp);
		new = mremap(ghp, size, size, MREMAP_MAYMOVE|MREMAP_FIXED, ghp + size);
	}
	pprintf("new %p\n", new);
	perror("mremap");
	return new == MAP_FAILED ? -1 : 0;
}

int main(int argc, char **argv) {
	char c;
	int ret;
	int argindex = 1;
	int nr_gp = 1;
	struct op_control opc;

	setup_signal_handler();

	while ((c = getopt(argc, argv, "vp:n:")) != -1) {
		switch(c) {
                case 'v':
                        verbose = 1;
                        break;
                case 'p':
                        testpipe = optarg;
                        {
                                struct stat stat;
                                lstat(testpipe, &stat);
                                if (!S_ISFIFO(stat.st_mode))
                                        errmsg("Given file is not fifo.\n");
                        }
			argindex += 2;
                        break;
		case 'n':
			nr_gp = strtol(optarg, NULL, 0);
			argindex += 2;
			break;
		}
	}

	size = nr_gp * (1UL << 30);

	for (int iarg = argindex; iarg < argc; iarg++) {
		char tag_string[256];

		parse_operation_args(&opc, argv[iarg]);
		if (opc.tag)
			sprintf(tag_string, "%s_%s", opc.name, opc.tag);
		else
			strcpy(tag_string, opc.name);

		do_wait_before(&opc);

		if (!strcmp(opc.name, "allocate")) {
			ret = do_allocate(&opc);
		} else if (!strcmp(opc.name, "access")) {
			ret = do_access(&opc);
		} else if (!strcmp(opc.name, "madvise")) {
			ret = do_madvise(&opc);
		} else if (!strcmp(opc.name, "iterate_mapping")) {
			ret = do_iterate_mapping(&opc);
		} else if (!strcmp(opc.name, "fork")) {
			ret = do_fork(&opc);
		} else if (!strcmp(opc.name, "mremap")) {
			ret = do_mremap(&opc);
		} else if (!strcmp(opc.name, "pause")) {
			pprintf("%s\n", tag_string);
			pause();
			ret = 0;
		}

		pprintf("%s returned %d\n", tag_string, ret);
		if (ret != 0)
			perror(tag_string);

		do_wait_after(&opc);
	}
	return 0;
}
