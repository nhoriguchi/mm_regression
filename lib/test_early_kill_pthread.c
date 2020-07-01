#define _GNU_SOURCE 1
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <err.h>
#include <sys/prctl.h>
#include <signal.h>
#include <sys/syscall.h>

#define ADDR_INPUT 0x700000000000

void sig_handle(int signo) {
	printf("PTHREAD_RECEIVED_SIGBUS: pid:%d, tid:%d, get SIGBUS\n", getpid(), syscall(SYS_gettid));
}

static void *func(void *data) {
	signal(SIGBUS, sig_handle);
	if (prctl(PR_MCE_KILL, PR_MCE_KILL_SET, PR_MCE_KILL_EARLY, 0, 0, 0) < 0) {
		perror("prctl");
	}
	printf("child thread running.\n");
	pause();
	pthread_exit(0);
}

/*
 * If SIGBUS is sent to the subthread, both of main and sub- threads are
 * terminated successfully. If SIGBUS is sent to the main thread, subthread
 * is running so both threads are still waiting at pthread_join().
 */
int main() {
	int i;
        void *addr;
	pthread_t *t = calloc(sizeof(pthread_t), 1);
	int pthread_ret[1];

	signal(SIGBUS, sig_handle);

        addr = mmap((void *)ADDR_INPUT, 0x200000UL, PROT_READ | PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0);
	memset(addr, 'a', 0x200000UL - 1);

	if (pthread_create(t, NULL, func, NULL)) {
		perror("pthread_create");
	}

	pthread_join(*t, (void *)pthread_ret);
	free(t);
	if (pthread_ret[0] == 0) {
		printf("main thread done. %d\n", pthread_ret[0]);
		return 0;
	} else {
		return 1;
	}
}
