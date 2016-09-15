#ifndef _TEST_CORE_LIB_HUGEPAGE_H
#define _TEST_CORE_LIB_HUGEPAGE_H

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/ipc.h>
#include <sys/shm.h>

unsigned long HPSIZE = 0x200000UL;
#define HPS HPSIZE
#define GPS 0x40000000UL /* gigantic page */

#define BUF_SIZE   256
char filepath[BUF_SIZE];

#ifndef SHM_HUGETLB
#define SHM_HUGETLB 04000
#endif

char hugetlbfsdir[256];

/*
 * Function    : write_hugepage(char *addr, int nr_hugepage, char *avoid_addr)
 * Parameters  :
 *     addr            head address of hugepage range
 *     nr_hugepage     hugepage number from head address
 *     avoid_addr      the address which avoid to be operated
 */
void write_hugepage(char *addr, int nr_hugepage, char *avoid_addr)
{
	int i, j;
	for (i = 0; i < nr_hugepage; i++) {
		if ((addr + i * HPS) == avoid_addr)
			continue;
		for (j = 0; j < HPS; j++) {
			*(addr + i * HPS + j) = (char)('a' + ((i + j) % 26));
		}
	}
}

/*
 * Function    : read_hugepage(char *addr, int nr_hugepage, char *avoid_addr)
 * Parameters  :
 *     addr            head address of hugepage range
 *     nr_hugepage     hugepage number from head address
 *     avoid_addr      the address which avoid to be operated
 *
 * return      :
 *     0               OK
 *     -1              if buffer content differs from the expected ones
 */
int read_hugepage(char *addr, int nr_hugepage, char *avoid_addr)
{
	int i, j;
	int ret = 0;

	for (i = 0; i < nr_hugepage; i++) {
		if ((addr + i * HPS) == avoid_addr)
			continue;
		for (j = 0; j < HPS; j++) {
			if (*(addr + i * HPS + j) != (char)('a' + ((i + j) % 26))) {
				printf("Mismatch at %d\n", i + j);
				ret = -1;
				break;
			}
		}
	}
	return ret;
}

int hugetlbfs_root(char *dir)
{
	FILE *f = fopen("/proc/mounts", "r");
	char *line = NULL;
	char dummy1[100];
	char dummy2[100];
	int found = 0;
	size_t linelen = 0;
	if (!f) err("open /proc/mounts");
	while (getline(&line, &linelen, f) > 0) {
		if (sscanf(line, "%s %s hugetlbfs %[^ ]",
			   dummy1, dir, dummy2) >= 3) {
			found = 1;
			break;
		}
	}
	free(line);
	fclose(f);
	return found;
}

void get_hugetlbfs_filepath(char *basename)
{
	int ret = hugetlbfs_root(hugetlbfsdir);
	if (!ret) errmsg("failed to get hugetlbfs directory.\n");
	/* Construct file name */
	if (access(hugetlbfsdir, F_OK) == -1)
		errmsg("can't get hugetlbfs directory\n");
	strcpy(filepath, hugetlbfsdir);
	strcat(filepath, basename);
}

/* Assume there is only one types of hugepage size for now. */
int gethugepagesize(void)
{
	int hpagesize = 0;
	struct dirent *dent;
	DIR *dir;
	dir = opendir("/sys/kernel/mm/hugepages");
	if (!dir) err("open /sys/kernel/mm/hugepages");
	while ((dent = readdir(dir)) != NULL)
		if (sscanf(dent->d_name, "hugepages-%dkB", &hpagesize) >= 1)
			break;
	closedir(dir);
	return hpagesize * 1024;
}

int shmkey = 0;

void *alloc_shm_hugepage(int size)
{
	void *addr;
	int shmid;
	if ((shmid = shmget(shmkey, size,
			    SHM_HUGETLB | IPC_CREAT | SHM_R | SHM_W)) < 0) {
		perror("shmget");
		return NULL;
	}
	addr = shmat(shmid, (void *)0x0UL, 0);
	if (addr == (char *)-1) {
		perror("Shared memory attach failure");
		shmctl(shmid, IPC_RMID, NULL);
		return NULL;
	}
	shmkey = shmid;
	return addr;
}

void *alloc_shm_hugepage2(int size, void *exp_addr)
{
	void *addr;
	int shmid;
	if ((shmid = shmget(shmkey, size,
			    SHM_HUGETLB | IPC_CREAT | SHM_R | SHM_W)) < 0) {
		perror("shmget");
		return NULL;
	}
	/* addr = shmat(shmid, exp_addr, SHM_RND); */
	addr = shmat(shmid, exp_addr, 0);
	if (addr == (char *)-1) {
		perror("Shared memory attach failure");
		shmctl(shmid, IPC_RMID, NULL);
		err("shmat failed");
		return NULL;
	}
	if (addr != exp_addr) {
		printf("Shared memory not attached to expected address (%p -> %p) %lx %lx\n", exp_addr, addr, SHMLBA, SHM_RND);
		shmctl(shmid, IPC_RMID, NULL);
		err("shmat failed");
		return NULL;
	}

	shmkey = shmid;
	return addr;
}

void *alloc_anonymous_hugepage(int size, int private, void *exp_addr)
{
	void *addr;
	int mapflag = MAP_ANONYMOUS | 0x40000; /* MAP_HUGETLB */
	if (private)
		mapflag |= MAP_PRIVATE;
	else
		mapflag |= MAP_SHARED;
	if ((addr = mmap(exp_addr, size, MMAP_PROT, mapflag, -1, 0)) == MAP_FAILED)
		errmsg("failed to allocate anonymous hugepage.\n");
	if (exp_addr && addr != exp_addr)
		errmsg("failed to mapping hugepage to expected address.\n");
	return addr;
}

int hpfd = 0;
/* Assume that global variable @filepath are set. */
void *alloc_filebacked_hugepage(int size, int private)
{
	int mapflag = MAP_SHARED;
	void *addr;
	if (private)
		mapflag = MAP_PRIVATE;
	if ((hpfd = open(filepath, O_CREAT|O_RDWR, 0777)) < 0) {
		perror("open");
		return NULL;
	}
	if ((addr = mmap(0, size, MMAP_PROT, mapflag, hpfd, 0)) == MAP_FAILED) {
		perror("mmap");
		unlink(filepath);
		return NULL;
	}
	return addr;
}

void *alloc_hugepage(int size, int hptype, int private)
{
	void *addr;
	if (hptype == 2) {
		addr = alloc_shm_hugepage(size);
		if (!addr)
			errmsg("Failed in alloc_shm_hugepage()");
	} else if (hptype == 1) {
		addr = alloc_anonymous_hugepage(size, private, 0);
		if (!addr)
			errmsg("Failed in alloc_anonymous_hugepage()");
	} else {
		addr = alloc_filebacked_hugepage(size, private);
		if (!addr)
			errmsg("Failed in alloc_filebacked_hugepage()");
	}
	return addr;
}

int free_shm_hugepage(int key, void *addr)
{
	if (shmdt((const void *)addr) != 0) {
		perror("Detach failure");
		shmctl(key, IPC_RMID, NULL);
		return -1;
	}
	shmctl(key, IPC_RMID, NULL);
	return 0;
}

int free_anonymous_hugepage(void *addr, int size)
{
	int ret = 0;
	if (munmap(addr, size)) {
		perror("munmap");
		ret = -1;
	}
	return ret;
}

int free_filebacked_hugepage(void *addr, int size)
{
	int ret = 0;
	if (munmap(addr, size)) {
		perror("munmap");
		ret = -1;
	}
	if (close(hpfd)) {
		perror("close");
		ret = -1;
	}
	if (filepath) {
		if (unlink(filepath)) {
			perror("unlink");
			ret = -1;
		}
	} else {
		fprintf(stderr, "Filepath not specified.\n");
		ret = -1;
	}
	return ret;
}

int free_hugepage(void *addr, int hptype, int size)
{
	if (hptype == 2) {
		if (free_shm_hugepage(shmkey, addr) == -1)
			exit(2);
	} else if (hptype == 1) {
		if (free_anonymous_hugepage(addr, size) == -1)
			exit(2);
	} else {
		if (free_filebacked_hugepage(addr, size) == -1)
			exit(2);
	}
}

#endif /* _TEST_CORE_LIB_HUGEPAGE_H */
