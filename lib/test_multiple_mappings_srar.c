#define _GNU_SOURCE 1
#include <stdio.h>
#include <sys/fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>

#define PS 4096
#define MADV_HWPOISON 100
#define ADDR_INPUT 0x700000000000
#define SHM_HUGE_SHIFT       26
#define SHM_HUGE_1GB    (30 << SHM_HUGE_SHIFT)

#include "mce.h"

void init_cpu_info(void);
void init_inject(void);
void clean_inject(void);
void submit_mce(struct mce *m);
void init_mce(struct mce *m);

typedef unsigned long long u64;

#define YYSTYPE u64

extern void yyerror(const char *fmt, ...);
extern int yylineno;
extern int yylex(void);
extern int yyparse(void);
extern char *filename;

enum mceflags {
	MCE_NOBROADCAST = (1 << 0),
	MCE_HOLD = (1 << 1),
	MCE_RAISE_MODE = (1 << 2),
	MCE_IRQBROADCAST = (1 << 3),
	MCE_NMIBROADCAST = (1 << 4),
};

extern enum mceflags mce_flags;

#define ARRAY_SIZE(x) (sizeof(x)/sizeof(*(x)))
void err(const char *msg);

#define NEW(x) ((x) = xalloc(sizeof(*(x))))
void *xalloc(size_t sz);
void *xcalloc(size_t a, size_t b);

#ifdef __GNUC__
#define barrier() asm volatile("" ::: "memory")
#else
#define barrier() do {} while(0)
#endif

enum mceflags mce_flags;

static int cpu_num;
/* map from cpu index to cpu id */
static int *cpu_map;
static struct mce **cpu_mce;

int do_dump;
int no_random;
static char **argv;
char *filename = "<stdin>";

#define BANKS "/sys/devices/system/machinecheck/machinecheck0"

void yyerror(char const *msg, ...)
{
	va_list ap;
	va_start(ap, msg);
	fprintf(stderr, "%s: ", filename);
	vfprintf(stderr, msg, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

void oom(void)
{
	fprintf(stderr, "Out of virtual memory\n");
	exit(1);
}

void *xcalloc(size_t a, size_t b)
{
	void *p = calloc(a, b);
	if (!p)
		oom();
	return p;
}

void *xalloc(size_t sz)
{
	void *p = calloc(sz, 1);
	if (!p)
		oom();
	return p;
}

void err(const char *msg)
{
	perror(msg);
	exit(1);
}

int max_bank(void)
{
	static int max;
	int b = 0;
	struct dirent *de;
	DIR *d;

	if (max)
		return max;
	d = opendir(BANKS);
	if (!d) {
		fprintf(stderr, "warning: cannot open %s: %s\n", BANKS,
			strerror(errno));
		return 0xff;
	}
	while ((de = readdir(d)) != NULL) {
		if (sscanf(de->d_name, "bank%u", &b) == 1)
			if (b > max)
				max = b;

	}
	closedir(d);
	return max;

}

void init_cpu_info(void)
{
	FILE *f = fopen("/proc/cpuinfo", "r");
	char *line = NULL;
	size_t linesz = 0;
	int max_cpu = sysconf(_SC_NPROCESSORS_CONF);
	if (!f)
		err("opening of /proc/cpuinfo");

	cpu_map = xcalloc(sizeof(int), max_cpu);

	while (getdelim(&line, &linesz, '\n', f) > 0) {
		unsigned cpu;
		if (sscanf(line, "processor : %u\n", &cpu) == 1 &&
			cpu_num < max_cpu)
			cpu_map[cpu_num++] = cpu;
	}
	free(line);
	fclose(f);

	if (!cpu_num)
		fprintf(stderr, "cannot get cpu ids from /proc/cpuinfo\n");
}

void init_inject(void)
{
	cpu_mce = xcalloc(cpu_num, sizeof(struct mce *));
}

void clean_inject(void)
{
	free(cpu_mce);
	free(cpu_map);
}

static inline int cpu_id_to_index(int id)
{
	int i;

	for (i = 0; i < cpu_num; i++)
		if (cpu_map[i] == id)
			return i;
	yyerror("cpu %d not online\n", id);
	return -1;
}

static void validate_mce(struct mce *m)
{
	cpu_id_to_index(m->extcpu);
	if (m->bank > max_bank()) {
		yyerror("larger machine check bank %d than supported on this cpu (%d)\n",
			(int)m->bank, max_bank());
		exit(1);
	}
}

static void write_mce(int fd, struct mce *m)
{
	int n = write(fd, m, sizeof(struct mce));
	if (n <= 0)
		err("Injecting mce on /dev/mcelog");
	if (n < sizeof(struct mce)) {
		fprintf(stderr, "mce-inject: Short mce write %d: kernel does not match?\n",
			n);
	}
}

struct thread {
	struct thread *next;
	pthread_t thr;
	struct mce *m;
	struct mce otherm;
	int fd;
	int cpu;
};

volatile int blocked;

static void *injector(void *data)
{
	struct thread *t = (struct thread *)data;
	cpu_set_t aset;

	CPU_ZERO(&aset);
	CPU_SET(t->cpu, &aset);
	sched_setaffinity(0, sizeof(aset), &aset);

	while (blocked)
		barrier();

	write_mce(t->fd, t->m);
	return NULL;
}

/* Simulate machine check broadcast.  */
void do_inject_mce(int fd, struct mce *m)
{
	int i, has_random = 0;
	struct mce otherm;
	struct thread *tlist = NULL;

	memset(&otherm, 0, sizeof(struct mce));
	// make sure to trigger exception on the secondaries
	otherm.mcgstatus = m->mcgstatus & MCG_STATUS_MCIP;
	if (m->status & MCI_STATUS_UC)
		otherm.mcgstatus |= MCG_STATUS_RIPV;
	otherm.status = m->status & MCI_STATUS_UC;
	otherm.inject_flags |= MCJ_EXCEPTION;

	blocked = 1;
	barrier();

	for (i = 0; i < cpu_num; i++) {
		unsigned cpu = cpu_map[i];
		struct thread *t;

		NEW(t);
		if (cpu == m->extcpu) {
			t->m = m;
			if (MCJ_CTX(m->inject_flags) == MCJ_CTX_RANDOM)
				MCJ_CTX_SET(m->inject_flags, MCJ_CTX_PROCESS);
		} else if (cpu_mce[i])
			t->m = cpu_mce[i];
		else if (mce_flags & MCE_NOBROADCAST) {
			free(t);
			continue;
		} else {
			t->m = &t->otherm;
			t->otherm = otherm;
			t->otherm.cpu = t->otherm.extcpu = cpu;
		}

		if (no_random && MCJ_CTX(t->m->inject_flags) == MCJ_CTX_RANDOM)
			MCJ_CTX_SET(t->m->inject_flags, MCJ_CTX_PROCESS);
		else if (MCJ_CTX(t->m->inject_flags) == MCJ_CTX_RANDOM) {
			write_mce(fd, t->m);
			has_random = 1;
			free(t);
			continue;
		}

		t->fd = fd;
		t->next = tlist;
		tlist = t;

		t->cpu = cpu;

		if (pthread_create(&t->thr, NULL, injector, t))
			err("pthread_create");
	}

	if (has_random) {
		if (mce_flags & MCE_IRQBROADCAST)
			m->inject_flags |= MCJ_IRQ_BRAODCAST;
		else
			/* default using NMI BROADCAST */
			m->inject_flags |= MCJ_NMI_BROADCAST;
	}

	/* could wait here for the threads to start up, but the kernel
	   timeout should be long enough to catch slow ones */

	barrier();
	blocked = 0;

	while (tlist) {
		struct thread *next = tlist->next;
		pthread_join(tlist->thr, NULL);
		free(tlist);
		tlist = next;
	}
}

void inject_mce(struct mce *m)
{
	int i, inject_fd;

	validate_mce(m);
	if (!(mce_flags & MCE_RAISE_MODE)) {
		if (m->status & MCI_STATUS_UC)
			m->inject_flags |= MCJ_EXCEPTION;
		else
			m->inject_flags &= ~MCJ_EXCEPTION;
	}
	if (mce_flags & MCE_HOLD) {
		int cpu_index = cpu_id_to_index(m->extcpu);
		struct mce *nm;

		NEW(nm);
		*nm = *m;
		free(cpu_mce[cpu_index]);
		cpu_mce[cpu_index] = nm;
		return;
	}

	inject_fd = open("/dev/mcelog", O_RDWR);
	if (inject_fd < 0)
		err("opening of /dev/mcelog");
	if (!(m->inject_flags & MCJ_EXCEPTION)) {
		mce_flags |= MCE_NOBROADCAST;
		mce_flags &= ~MCE_IRQBROADCAST;
		mce_flags &= ~MCE_NMIBROADCAST;
	}
	do_inject_mce(inject_fd, m);

	for (i = 0; i < cpu_num; i++) {
		if (cpu_mce[i]) {
			free(cpu_mce[i]);
			cpu_mce[i] = NULL;
		}
	}
	close(inject_fd);
}

void dump_mce(struct mce *m)
{
	printf("CPU %d\n", m->extcpu);
	printf("BANK %d\n", m->bank);
	printf("TSC 0x%Lx\n", m->tsc);
	printf("TIME %Lu\n", m->time);
	printf("RIP 0x%02x:0x%Lx\n", m->cs, m->ip);
	printf("MISC 0x%Lx\n", m->misc);
	printf("ADDR 0x%Lx\n", m->addr);
	printf("STATUS 0x%Lx\n", m->status);
	printf("MCGSTATUS 0x%Lx\n", m->mcgstatus);
	printf("PROCESSOR %u:0x%x\n\n", m->cpuvendor, m->cpuid);
}

void submit_mce(struct mce *m)
{
	if (do_dump)
		dump_mce(m);
	else
		inject_mce(m);
}

void init_mce(struct mce *m)
{
	memset(m, 0, sizeof(struct mce));
}

#define ADDR_INPUT 0x700000000000

char *sigbusvaddr = 0;

void sig_handle(int signo) { printf("SIGBUS %d\n", signo); }
void sigbus_action(int signo, siginfo_t *si, void *args)
{
        printf("Signal received: pid:%d, signo:%d, si_code:%d, si_addr:%p, si_addr_lsb:%d\n",
               getpid(), signo, si->si_code, si->si_addr, si->si_addr_lsb);
        if (si->si_code == BUS_MCEERR_AR)
		sigbusvaddr = si->si_addr;
}

struct sigaction sa = {
	.sa_sigaction = sigbus_action,
	.sa_flags = SA_SIGINFO,
};

void set_srar_no_en(struct mce *m) {
	m->status = 0xa580000000000000UL;
	m->mcgstatus = 0x6;
	m->misc = 0;
}

void set_srao_ewb_noripv(struct mce *m) {
	m->status = 0xbd0000000000017a;
	m->mcgstatus = 0x4;
	m->misc = 0x8c;
	m->cs = 0;
	m->ip = 0;
}

void set_srar_data_load(struct mce *m) {
	m->bank = 2;
	m->cs = 0x3;
	m->ip = 0x1eadbabe;
	m->misc = 0x8c;
	m->status = 0xbd80000000000134UL;
	m->mcgstatus = 0x7;
}

void send_hard_offline(unsigned long pfn) {
	char cmd[4096];

	sprintf(cmd, "echo 0x%lx000 > /sys/devices/system/memory/hard_offline_page", pfn);
	system(cmd);
}

int main(int ac, char **av)
{
        int rc = 0;
	unsigned long addr;
	char path[256];
	int pmfd;
	int i;
	unsigned long entry, pfn;
	int fd;
	char *array = malloc(4096);
	int mmapflag = MAP_SHARED;
	char *ptr, *ptr2;
	int size = PS;
	int ret;
	int mode = 0;

	sigaction(SIGBUS, &sa, NULL);
	init_cpu_info();
	init_inject();

	if (ac > 1) {
		mode = strtoul(av[1], NULL, 0);
	}
	printf("mode %d\n", mode);

	if (mode == 0) {
		system("echo 1 > /sys/kernel/mm/ksm/run");
		ptr = mmap((void *)ADDR_INPUT, size, PROT_READ | PROT_WRITE,
			   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (ptr == MAP_FAILED)
			err("mmap");
		ptr2 = mmap((void *)(ADDR_INPUT + size), size, PROT_READ | PROT_WRITE,
			    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (ptr2 == MAP_FAILED)
			err("mmap");
		ret = madvise(ptr, size, MADV_MERGEABLE);
		if (ret == -1)
			err("madvise");
		ret = madvise(ptr2, size, MADV_MERGEABLE);
		if (ret == -1)
			err("madvise");
		memset(ptr, 'a', size);
		memset(ptr2, 'a', size);
		printf("waiting for ksmd to merge the pages\n");
		usleep(2000000);
	} else if (mode == 1) { // file mmaped
		fd = open("tmp/testfile", O_RDWR|O_CREAT, 0666);
		if (fd == -1)
			err("open");
		memset(array, 'a', PS);
		pwrite(fd, array, PS, 0);
		ptr = mmap((void *)ADDR_INPUT, PS, PROT_READ|PROT_WRITE, mmapflag, fd, 0);
		if (ptr == MAP_FAILED)
			err("mmap");
		ptr2 = mmap((void *)(ADDR_INPUT + PS), PS, PROT_READ|PROT_WRITE, mmapflag, fd, 0);
		if (ptr2 == MAP_FAILED)
			err("mmap");
		ptr[0] = 'x';
		ptr2[0] = 'y';
	} else if (mode == 2) { // anonymous thp
		size = 0x200000;
		ptr = mmap((void *)ADDR_INPUT, size, PROT_READ | PROT_WRITE,
			   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		printf("ptr %p\n", ptr);
		if (ptr == MAP_FAILED)
			err("mmap");
		ptr2 = mmap((void *)(ADDR_INPUT + size), size, PROT_READ | PROT_WRITE,
			    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (ptr2 == MAP_FAILED)
			err("mmap");
		memset(ptr, 'a', size);
		memset(ptr2, 'a', size);
	} else if (mode == 3) { // shmem thp
		char buf[0x200000];
		size = 0x200000;
		fd = open("tmp/shmem/testfile", O_RDWR|O_CREAT, 0666);
		if (fd == -1)
			err("open");
		memset(buf, 'a', size);
		pwrite(fd, buf, size, 0);
		ptr = mmap((void *)ADDR_INPUT, size, PROT_READ|PROT_WRITE, mmapflag, fd, 0);
		if (ptr == MAP_FAILED)
			err("mmap");
		memset(ptr, 'a', size);
	} else if (mode == 4) { // 1gb hugetlb
		int shm_id;
		/* char buf[0x200000]; */
		size = 1024*1024*1024;

		shm_id = shmget(10, size, SHM_HUGETLB | SHM_HUGE_1GB | IPC_CREAT|0666);
		if (shm_id < 0)
			err("shmget");
		ptr = shmat(shm_id, (void *)ADDR_INPUT, SHM_RND);
		if (ptr == (void *)-1)
			err("shmat");
		memset(ptr, 'a', size);
	} else {
		printf("invalid mode\n");
		return 1;
	}

	sprintf(path, "/proc/%d/pagemap", getpid());
	pmfd = open(path, O_RDONLY);
	i = pread(pmfd, (void *)&entry, 8, 0x700000000UL*8);
	pfn = entry & 0xfffffffffff;
	printf("vaddr: %p, pfn; 0x%lx\n", ptr, pfn);

	addr = pfn << 12;

	struct mce m1 = {
		.extcpu = 0,
		.bank = 2,
		.cs = 0x3,
		.ip = 0x1eadbabe,
		.misc = 0x8c,
		.addr = addr,
		.status = 0xbd80000000000134UL,
		.mcgstatus = 0x7,
	};
	/* set_srao_ewb_noripv(&m1); */
	send_hard_offline(pfn);
	printf("inject SRAR MCE\n");
	set_srar_data_load(&m1);
	inject_mce(&m1);
	printf("inject done\n");

	printf("sigbusvaddr: %p\n", sigbusvaddr);
	if (sigbusvaddr)
		return 0;
	else
		return 1;
}
