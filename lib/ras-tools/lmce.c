// SPDX-License-Identifier: GPL-2.0

#define _GNU_SOURCE
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <sched.h>
#include <signal.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <setjmp.h>

extern unsigned long long vtop(unsigned long long addr, pid_t pid);

#define NR_THREADS 	2
#define NR_CPUS 	2
#define NR_ADDRS 	2

#define EINJ_TABLE "/sys/firmware/acpi/tables/EINJ"
#define EINJ_AVAIL_TYPE "/sys/kernel/debug/apei/einj/available_error_type"
#define EINJ_TYPE "/sys/kernel/debug/apei/einj/error_type"
#define EINJ_PARAM1 "/sys/kernel/debug/apei/einj/param1"
#define EINJ_PARAM2 "/sys/kernel/debug/apei/einj/param2"
#define EINJ_NOTRIGGER "/sys/kernel/debug/apei/einj/notrigger"
#define EINJ_INJECT "/sys/kernel/debug/apei/einj/error_inject"

struct thr_arg {
	char *addr;
	int ac_type;
	int cpu;
	char name[32];
	sigjmp_buf *s_buf;
};

long pagesize;
sigjmp_buf recover[NR_THREADS];
pthread_t thread[NR_THREADS];
char *vaddr[NR_ADDRS] = { NULL };
volatile int ready = 0;
static int ncpus;
static int nmasks;

int write_file(char *path, uint64_t val)
{
	FILE *fp;

	fp = fopen(path, "w");
	if (!fp) {
		fprintf(stderr, "Fail to open %s\n", path);
		return -1;
	}
	fprintf(fp, "0x%lx\n", val);
	fclose(fp);
	return 0;
}

void check_einj_available(void)
{
	if (access(EINJ_TABLE, R_OK) == -1) {
		fprintf(stderr, "EINJ table isn't supported, please check BIOS setting\n");
		exit(1);
	}
	if (access(EINJ_AVAIL_TYPE, R_OK) == -1) {
		fprintf(stderr, "Please check if einj.ko module is installed\n");
		exit(1);
	}
}

void do_inject(uint64_t addr)
{
	write_file(EINJ_TYPE, 0x10);
	write_file(EINJ_PARAM1, addr);
	write_file(EINJ_PARAM2, 0xfffffffffffff000ul);
	write_file(EINJ_NOTRIGGER, 1);
	write_file(EINJ_INJECT, 1);
}

void* thread_func(void *data)
{
	struct thr_arg *ptarg = (struct thr_arg *)data;
	char buf[256], *err;
	cpu_set_t cpus;
	int flag = -1;

	CPU_ZERO(&cpus);
	CPU_SET(ptarg->cpu, &cpus);
	if (sched_setaffinity(0, sizeof(cpu_set_t), &cpus) == -1) {
		err = strerror_r(errno, buf, 256);
		fprintf(stderr, "%s failed: sched_setaffinity(%s)\n",
			ptarg->name, err);
		return NULL;
	}
	if (sigsetjmp(*ptarg->s_buf, 1) == 0) {
		/*
		 * Wait until master thread tells us to access the data
		 */
		while (!ready)
			/*spin*/;

		if (ptarg->ac_type == 0)
			printf("%x\n", *(char *)ptarg->addr);
		else {
			int (*func)(void) = (int (*)(void))ptarg->addr;
			printf("%x\n", func());
		}
	} else {
		flag = 0;
		printf("%s: recovered\n", ptarg->name);
	}
	if (flag == -1)
		printf("%s: failed\n", ptarg->name);
	return NULL;
}

static unsigned int *get_cpu_mask(int cpu, char *type)
{
	unsigned int bits, *mask;
	char path[100];
	FILE *fp;
	int c, commas = 0, idx;

	idx = nmasks;
	mask = calloc(idx, sizeof *mask);
	if (!mask)
		return NULL;

	sprintf(path, "/sys/devices/system/cpu/cpu%d/topology/%s", cpu, type);
	fp = fopen(path, "r");
	if (!fp) {
		perror(path);
		return NULL;
	}

	while ((c = fgetc(fp)) != EOF)
		if (c == ',')
			commas++;
	rewind(fp);
	while (commas > idx - 1) {
		c = fgetc(fp);
		if (c == ',')
			commas--;
	}

	while (fscanf(fp, "%x,", &bits) == 1) {
		mask[--idx] = bits;
//		printf("mask[%d] = 0x%x\n", idx, mask[idx]);
	}
	fclose(fp);

	if (idx) {
		fprintf(stderr, "failed to parse %s\n", path);
		free(mask);
		return NULL;
	}

	return mask;
}

void pick_same_core_cpu(int *cpu, int first_cpu)
{
	unsigned int *mask;
	int i;

	mask = get_cpu_mask(first_cpu, "thread_siblings");
	if (!mask) {
		exit(1);
	}
	for (i = 0; i < ncpus; i++)
	{
		if (mask[i / 32] & (1 << (i % 32))) {
			if (i != first_cpu) {
				cpu[0] = first_cpu;
				cpu[1] = i;
				break;
			}
		}
	}
	if (i == ncpus) {
		fprintf(stderr, "Failed to find same core CPUs\n");
		free(mask);
		exit(1);
	}
	free(mask);
}

void pick_same_socket_cpu(int *cpu, int first_cpu)
{
	unsigned int *cs_mask;
	unsigned int *ts_mask;
	int i;

	cs_mask = get_cpu_mask(first_cpu, "core_siblings");
	if (!cs_mask) exit(1);
	ts_mask = get_cpu_mask(first_cpu, "thread_siblings");
	if (!ts_mask) {
		free(cs_mask);
		exit(1);
	}

	for (i = 0; i < ncpus; i++)
	{
		if ((cs_mask[i / 32] ^ ts_mask[i / 32]) & (1 << (i % 32))) {
			cpu[0] = first_cpu;
			cpu[1] = i;
			break;
		}
	}
	if (i == ncpus) {
		fprintf(stderr, "Failed to find same socket CPUs\n");
		free(cs_mask);
		free(ts_mask);
		exit(1);
	}
	free(cs_mask);
	free(ts_mask);
}

void pick_diff_socket_cpu(int *cpu, int first_cpu)
{
	unsigned int *mask;
	int *buf;
	int i;
	int count = 0;
	int idx;

	buf = calloc(ncpus, sizeof *buf);
	if (!buf) {
		perror("calloc");
		exit(1);
	}
	memset(buf, 0, ncpus * sizeof(*buf));
	mask = get_cpu_mask(first_cpu, "core_siblings");
	if (!mask) exit(1);

	for (i = 0; i < ncpus; i++)
	{
		if (~mask[i / 32] & (1 << (i % 32)))
			buf[count++] = i;
	}
	if (count == 0) {
		fprintf(stderr, "Failed to find different socket CPUs\n");
		free(buf);
		free(mask);
		exit(1);
	}
	idx = random() % count;
	cpu[0] = first_cpu;
	cpu[1] = buf[idx];
	free(buf);
	free(mask);
}

void pick_cpu(int *cpu, int core_choice)
{
	int first_cpu;

	first_cpu = random() % ncpus;
	if (core_choice == 1) {
		pick_same_core_cpu(cpu, first_cpu);
		printf("Run on same core CPUs:");
	} else if (core_choice == 2) {
		pick_same_socket_cpu(cpu, first_cpu);
		printf("Run on same socket CPUs:");
	} else {
		pick_diff_socket_cpu(cpu, first_cpu);
		printf("Run on different socket CPUs:");
	}
	printf(" cpu0 = %d, cpu1 = %d\n", cpu[0], cpu[1]);
}

int test_func(void)
{
	volatile int ret = 0;
	int i;

	for (i = 0; i < 1000; i++)
		ret += i;
	return ret;
}

void sig_handler(int sig, siginfo_t *si, void *arg)
{
	int i;
	int flag = 0;

	for(i = 0; i < NR_THREADS; i++)
	{
                if (vaddr[i % NR_ADDRS] &&
                    si->si_addr == vaddr[i % NR_ADDRS]) {
                        flag = 1;
                        break;
                }
        }
        if (flag == 0) {
                printf("The address(%p) in signal is not we wanted\n",
                        si->si_addr);
                return;
        }
	printf("received signal %d, addr %p\n", sig, si->si_addr);
	for(i = 0; i < NR_THREADS; i++)
	{
		if (pthread_equal(pthread_self(), thread[i]))
			siglongjmp(recover[i], 1);
	}
}

void usage(char *str)
{
printf("Usage: %s [-a] [-c core_choice] [-t access_type] [-h]\n", str);
printf("\t-a --- Threads access same error-injected address.\n");
printf("\t       If no this option, access different error-injected addresses.\n");
printf("\t-c --- Pick which CPUs to let threads run on.\n");
printf("\t       core_choice = 1, threads run on same CPU cores.\n");
printf("\t       core_choice = 2, threads run on same socket CPUs but different cores.\n");
printf("\t       core_choice = 3, threads run on different socket CPUs, this is default option.\n");
printf("\t-t --- Control which access type to trigger the fault, instruction fetch or data access.\n");
printf("\t       there are three group choices: INSTR/INSTR, INSTR/DATA, DATA/DATA,\n");
printf("\t       the default is INSTR/DATA.\n");
printf("\t-h --- print this message.\n");
	exit(1);
}

const struct _access_type {
	int v[2];
	const char *k;
	const char *s;
} access_type[] = {
	{{1,1}, "INSTR/INSTR", "Instruction Fetch/Instruction Fetch"},
	{{1,0}, "INSTR/DATA", "Instruction Fetch/Data Access"},
	{{0,0}, "DATA/DATA", "Data Access/Data Access"}
};

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#endif

int main(int argc, char *argv[])
{
	struct sigaction sa = {
		.sa_sigaction = sig_handler,
		.sa_flags = SA_SIGINFO
	};
	struct thr_arg targ[NR_THREADS];
	int testcpu[NR_CPUS];
	uint64_t paddr[NR_ADDRS];
	int c, i;
	int same_addr = 0;
	/*default: different socket CPUs*/
	int core_choice = 3;
	/*default: INSTR/DATA*/
	int idx = 1;
	pid_t pid;

	srandom(getpid() * time(0));
	if (getuid() != (uid_t)0) {
		printf("Must be run as root\n");
		return 0;
	}
	while ((c = getopt(argc, argv, "ac:ht:")) != -1)
		switch (c) {
			case 'a':
                                same_addr = 1;
                                break;
			case 'c':
				core_choice = atoi(optarg);
				if (core_choice < 1 || core_choice > 3)
					usage(argv[0]);
				break;
			case 't':
				for (i = 0; i < ARRAY_SIZE(access_type); i++)
				{
					if (strstr(optarg, access_type[i].k)) {
						idx = i;
						break;
					}
				}
				if (i == ARRAY_SIZE(access_type))
					usage(argv[0]);
				break;
			case 'h':
			default:
				usage(argv[0]);
				break;
		}
	check_einj_available();
	ncpus = sysconf(_SC_NPROCESSORS_CONF);
	nmasks = (ncpus + 31) / 32;
	if (ncpus <= 1) {
		fprintf(stderr, "Improper number of CPUs\n");
		return 1;
	}
	pagesize = sysconf(_SC_PAGESIZE);
	pick_cpu(testcpu, core_choice);
	memset(targ, 0, sizeof(targ));
	sigaction(SIGBUS, &sa, NULL);
	pid = getpid();
        for (i = 0; i < NR_ADDRS; i++)
        {
                if ((vaddr[i] = mmap(0, pagesize, PROT_READ | PROT_WRITE | PROT_EXEC,
                                     MAP_PRIVATE | MAP_ANONYMOUS |
                                     MAP_POPULATE, -1, 0)) == MAP_FAILED) {
                        perror("mmap");
                        exit(1);
                }
		memcpy(vaddr[i], (void *)test_func, pagesize);
                if ((paddr[i] = vtop((uint64_t)vaddr[i], pid)) == 0)
                        return 1;
		printf("Inject memory error at physical address 0x%lx(virt 0x%lx)\n",
			paddr[i], (uint64_t)vaddr[i]);
                do_inject(paddr[i]);
                sleep(1);
                if (same_addr) break;
        }
	printf("Access type: %s\n", access_type[idx].s);

	for (i = 0; i < NR_THREADS; i++)
	{
		targ[i].ac_type = access_type[idx].v[i % 2];
		targ[i].cpu = testcpu[i % NR_CPUS];
		sprintf(targ[i].name, "thread%d", i);
		targ[i].s_buf = &recover[i];
                if (same_addr)
                        targ[i].addr = vaddr[0];
                else
                        targ[i].addr = vaddr[i % NR_ADDRS];
		if(pthread_create(&thread[i], NULL, thread_func, &targ[i])) {
			perror("pthread_create");
			return 1;
		}
	}

	/*
	 * Wait a second for children to initialize and
	 * bind to correct CPUs. Then tell them to run.
	 */
	sleep(1);
	ready = 1;

	for (i = 0; i < NR_THREADS; i++)
		pthread_join(thread[i], NULL);
        for (i = 0; i < NR_ADDRS; i++)
                if (vaddr[i]) munmap(vaddr[i], pagesize);
	return 0;
}
