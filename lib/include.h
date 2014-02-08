#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <sys/sem.h>
#include <sys/ipc.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>
#include <signal.h>
#include <sys/mman.h>

#define MADV_HUGEPAGE           14
#define MADV_NOHUGEPAGE         15
#define MADV_HWPOISON          100
#define MADV_SOFT_OFFLINE      101
#define MMAP_PROT PROT_READ|PROT_WRITE
#define err(x) perror(x),exit(EXIT_FAILURE)
#define errmsg(x, ...) fprintf(stderr, x, ##__VA_ARGS__),exit(EXIT_FAILURE)
#define PSIZE 4096
#define PS PSIZE
#define THPS 0x200000UL
#define strpair(x) x, strlen(x)

/* Control early_kill/late_kill */
#define PR_MCE_KILL 33
#define PR_MCE_KILL_CLEAR   0
#define PR_MCE_KILL_SET     1
#define PR_MCE_KILL_LATE    0
#define PR_MCE_KILL_EARLY   1
#define PR_MCE_KILL_DEFAULT 2
#define PR_MCE_KILL_GET 34

#define KPF_LOCKED              0
#define KPF_ERROR               1
#define KPF_REFERENCED          2
#define KPF_UPTODATE            3
#define KPF_DIRTY               4
#define KPF_LRU                 5
#define KPF_ACTIVE              6
#define KPF_SLAB                7
#define KPF_WRITEBACK           8
#define KPF_RECLAIM             9
#define KPF_BUDDY               10
#define KPF_MMAP                11
#define KPF_ANON                12
#define KPF_SWAPCACHE           13
#define KPF_SWAPBACKED          14
#define KPF_COMPOUND_HEAD       15
#define KPF_COMPOUND_TAIL       16
#define KPF_HUGE                17
#define KPF_UNEVICTABLE         18
#define KPF_HWPOISON            19
#define KPF_NOPAGE              20
#define KPF_KSM                 21
#define KPF_THP                 22
#define KPF_RESERVED            32
#define KPF_MLOCKED             33
#define KPF_MAPPEDTODISK        34
#define KPF_PRIVATE             35
#define KPF_PRIVATE_2           36
#define KPF_OWNER_PRIVATE       37
#define KPF_ARCH                38
#define KPF_UNCACHED            39
#define KPF_READAHEAD           48
#define KPF_SLOB_FREE           49
#define KPF_SLUB_FROZEN         50
#define KPF_SLUB_DEBUG          51

int verbose = 0;
char *testpipe = NULL;

static int checked_open(const char *pathname, int flags)
{
	int fd = open(pathname, flags);
	if (fd < 0) {
		perror(pathname);
		exit(EXIT_FAILURE);
	}
	return fd;
}

static int checked_close(int fd) {
	int ret = close(fd);
	if (ret < 0) {
		perror("close");
		exit(EXIT_FAILURE);
	}
	return ret;
}

void *checked_mmap(void *start, size_t length, int prot, int flags,
		   int fd, off_t offset) {
	void *map = mmap((void *)start, length, prot, flags, fd, offset);
	if (map == (void*)-1L)
		err("mmap");
	if (start) {
		if (map != start) {
			printf("expected %p, given %p\n", start, map);
			errmsg("Not mapped in expected vaddr.\n");
		}
	}
	return map;
}

void *checked_malloc(size_t size) {
	void *p;
	p = malloc(size);
	if (!p)
		err("malloc");
	return p;
}

int *checked_munmap(void *start, size_t length) {
	if (munmap(start, length) == -1)
		err("munmap");
	return 0;
}

void set_mergeable(char *ptr, int size) {
	if (madvise(ptr, size, MADV_MERGEABLE) == -1)
		perror("madvise");
}

void clear_mergeable(char *ptr, int size) {
	if (madvise(ptr, size, MADV_UNMERGEABLE) == -1)
		perror("madvise");
}

void set_hugepage(char *ptr, int size) {
	if (madvise(ptr, size, MADV_HUGEPAGE) == -1)
		perror("madvise");
}

void clear_hugepage(char *ptr, int size) {
	if (madvise(ptr, size, MADV_NOHUGEPAGE) == -1)
		perror("madvise");
}

union semun {
	int		val;
	struct semid_ds *buf;
	unsigned short  *array;
	struct seminfo  *__buf;
};

int create_and_init_semaphore() {
	int sem;
	union semun arg;
	if ((sem = semget(IPC_PRIVATE, 1, 0666)) == -1)
		err("semget");
	arg.val = 1;
	if (semctl(sem, 0, SETVAL, arg) == -1)
		err("semctl");
	return sem;
}

int delete_semaphore(int sem_id) {
	return semctl(sem_id, 0, IPC_RMID, NULL);
}

int get_semaphore(int sem_id, struct sembuf *sembuffer)
{
	sembuffer->sem_num = 0;
	sembuffer->sem_op  = -1;
	sembuffer->sem_flg = SEM_UNDO;
	return semop(sem_id, sembuffer, 1);
}

int put_semaphore(int sem_id, struct sembuf *sembuffer)
{
	sembuffer->sem_num = 0;
	sembuffer->sem_op  = 1;
	sembuffer->sem_flg = SEM_UNDO;
	return semop(sem_id, sembuffer, 1);
}

static int checked_read(int fd, char *str) {
	int ret;
	ret = read(fd, str, sizeof(str));
	if (ret < 0)
		err("read");
	return ret;
}

static int checked_write(int fd, char *str) {
	int ret;
	if (fd == 0)
		fd = 1;
	ret = write(fd, strpair(str));
	if (ret < 0)
		err("write");
	return ret;
}

int pipe_read(char *buf) {
	int pipefd;
	int ret;
	if (!testpipe)
		perror("testpipe not set (with -p option)\n");
	pipefd = checked_open(testpipe, O_RDONLY);
	ret = checked_read(pipefd, buf);
	checked_close(pipefd);
	return ret;
}

static int __pipe_printf(char *buf) {
	int pipefd = checked_open(testpipe, O_WRONLY);
	int ret = checked_write(pipefd, buf);
	checked_close(pipefd);
	return ret;
}

/*
 * If testpipe is given, write to the pipe. Otherwise, write to stdout.
 */
int pprintf(char *fmt, ...) {
	int ret;
	char buf[PS];
	va_list ap;

	va_start(ap, fmt);
	vsprintf(buf, fmt, ap);
	va_end(ap);
	if (!testpipe)
		ret = printf(buf);
	else
		ret = __pipe_printf(buf);
	return ret;
}

static volatile sig_atomic_t pprintf_wait_flag = 0;

void pprintf_wait_sighandler(int signo) {
	pprintf_wait_flag = 0;
}

void pprintf_wait(int signum, char *fmt, ...) {
	int ret;
	char buf[PS];
	va_list ap;
	struct sigaction new, old;

	pprintf_wait_flag = 1;
	new.sa_handler = pprintf_wait_sighandler;
	ret = sigaction(signum, &new, &old);
	if (ret == -1)
		err("sigaction");
	va_start(ap, fmt);
	vsprintf(buf, fmt, ap);
	pprintf(buf);
	va_end(ap);
	while (pprintf_wait_flag)
		;
	ret = sigaction(signum, &old, NULL);
	if (ret == -1)
		err("sigaction");
}

void Dprintf(const char *fmt, ...)
{
	if (verbose) {
		char buf[PS];
		va_list ap;
		va_start(ap, fmt);
		vsprintf(buf, fmt, ap);
		pprintf(buf);
		va_end(ap);
	}
}

#define SYSFS_HUGEPAGES_DIR "/sys/kernel/mm/hugepages/"

int get_hugepage_sizes(unsigned long *hpsizes) {
	int i = 0;
	DIR *dir;
	struct dirent *entry;

	dir = opendir(SYSFS_HUGEPAGES_DIR);
	if (dir) {
		while ((entry = readdir(dir))) {
			char *name = entry->d_name;
			if (strncmp(name, "hugepages-", 10) != 0)
				continue;
			name += 10;
			hpsizes[i] = atol(name) * 1024;
			i++;
		}
		closedir(dir);
	}
	return i;
}

/* todo: make it arch independent */
void validate_hugepage_size(unsigned long hpsize) {
	int i;
	unsigned long hpsizes[16]; /* possible hugepage size */
	char buf[1024];
	int nr_hpsize = get_hugepage_sizes(hpsizes);
	for (i = 0; i < nr_hpsize; i++)
		if (hpsize == hpsizes[i])
			break;
	if (i == nr_hpsize) { /* not found */
		sprintf(buf, "Invalid hugepage size:\n\tpossible values: ");
		for (i = 0; i < nr_hpsize; i++)
			sprintf(buf, "%s %d", buf, hpsizes[i]/1024);
		sprintf(buf, "%s\n", buf);
		errmsg(buf);
	}
}
