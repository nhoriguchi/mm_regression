cat <<EOF > /tmp/swap.c
#include <stdio.h>
#include <sys/mman.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <signal.h>

#define VADDR		0x700000000000UL

void sig_handle_flag(int signo) { ; }

int main(int argc, char **argv) {
	char *ptr;
	int size = 0;

	signal(SIGUSR1, sig_handle_flag);

	if (argc < 2) {
		printf("need to give memory size.\n");
		return 1;
	}
	size = strtoul(argv[1], NULL, 0);
	printf("memory size: 0x%lx\n", size);

	pause();
	ptr = mmap((void *)VADDR, size, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_SHARED, -1, 0);
	if (ptr == (void *)-1) {
		perror("mmap");
		return 1;
	}
	for (int i = 0; (i << 20) < size; i++) {
		memset(ptr + (i << 20), 'a' + i % 26, 1 << 20);
	}
	pause();

	printf("check data corruption: ");
	for (int i = 0; (i << 20) < size; i++) {
		int j = i << 20;
		if (ptr[j] != 'a' + i % 26) {
			printf("ptr[%d] is expected to be %c, but [%c]\n", j, 'a' + i % 26, ptr[j]);
			return 1;
		}
	}
	printf("OK\n");
	return 0;
}
EOF

gcc -o /tmp/swap /tmp/swap.c || exit 1

SWAPFILE=tmp/swapfile
SWAPSIZE="$[6 * (1 << 20) / 4096]" # 6 MB in page
MEMSIZE="$[10 * (1 << 20)]"
CGDIR=/sys/fs/cgroup/mycgroup
mkdir -p $CGDIR

modprobe dm-flakey || exit 1
swapoff -a
dmsetup remove -f test-flakey
losetup -D

dd if=/dev/zero of=$SWAPFILE bs=4096 count=$SWAPSIZE > /dev/null 2>&1 || exit 1
losetup -fP $SWAPFILE || exit 1
LOOPDEV=$(losetup -a | grep $SWAPFILE | cut -f1 -d:)
dmsetup create test-flakey --table "0 $(blockdev --getsize $LOOPDEV) flakey $LOOPDEV 0 1 9"
DMDEV=/dev/mapper/test-flakey
mkswap $DMDEV || exit 1
swapon $DMDEV || exit 1

/tmp/swap $MEMSIZE > /tmp/a.txt &
pid=$!
sleep 0.1
echo $pid > $CGDIR/cgroup.procs

# assuming cgroup2 is mounted.
echo "----- pid:${pid}"
echo $[MEMSIZE / 2] > $CGDIR/memory.max
echo $[MEMSIZE * 3 / 2] > $CGDIR/memory.swap.max

kill -SIGUSR1 $pid

# force swapout
sleep 5
free
grep -i swap /proc/meminfo
page-types -r

echo max > $CGDIR/memory.max
echo max > $CGDIR/memory.swap.max

page-types -p $pid -Nrl -a 0x700000000+10
page-types -p $pid -r -a 0x700000000+$[MEMSIZE/4096]
grep -A22 ^700000000 /proc/$pid/smaps

echo "#### swapoff !!! ####"
swapoff -a
if [ $? -eq 0 ] ; then
	echo "swapoff succeeded."
else
	echo "swapoff failed."
fi
echo "#### swapoff done !!! ####"
free

# data corruption check
kill -SIGUSR1 $pid
