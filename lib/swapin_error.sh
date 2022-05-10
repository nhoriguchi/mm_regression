cat <<EOF > /tmp/swap.c
#include <stdio.h>
#include <sys/mman.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <signal.h>

#define VADDR		0x700000000000UL
#define map_shift	20

void sig_handle_flag(int signo) { ; }

int main(int argc, char **argv) {
	char **ptr;
	int size = 0;
	int mapsize = 1 << map_shift;
	int nr_maps = 0;

	signal(SIGUSR1, sig_handle_flag);

	if (argc < 2) {
		printf("need to give memory size.\n");
		return 1;
	}
	size = strtoul(argv[1], NULL, 0);
	printf("memory size: 0x%lx\n", size);
	nr_maps = size >> map_shift;

	ptr = malloc(sizeof(char *) * nr_maps);
	pause();
	for (int i = 0; i < nr_maps; i++) {
		ptr[i] = mmap((void *)(VADDR + (unsigned long)i * mapsize), mapsize,
			      PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_SHARED, -1, 0);
		printf("ptr[%d] = %p (%c)\n", i, ptr[i], 'a' + i % 26);
		if (ptr[i] == (void *)-1) {
			perror("mmap");
			return 1;
		}
		memset(ptr[i], 'a' + i % 26, mapsize);
	}
	pause();

	printf("check data corruption: ");
	for (int i = 0; i < nr_maps; i++) {
		if (ptr[i][0] != 'a' + i % 26) {
			printf("ptr[%d] is expected to be %c, but [%c]\n",
			       i, 'a' + i % 26, ptr[i]);
			return 1;
		}
	}
	printf("OK\n");
	return 0;
}
EOF

gcc -o /tmp/swap /tmp/swap.c || exit 1

SWAPFILE=/tmp/swapfile
SWAPSIZE="$[6 * (1 << 20) / 4096]" # 6 MB in page
MEMSIZE="$[10 * (1 << 20)]"
CGDIR=/sys/fs/cgroup/mycgroup
mkdir -p $CGDIR

modprobe dm-dust || exit 1
swapoff -a
dmsetup remove -f test-dust
losetup -D

dd if=/dev/zero of=$SWAPFILE bs=4096 count=$SWAPSIZE > /dev/null 2>&1 || exit 1
losetup -fP $SWAPFILE || exit 1
LOOPDEV=$(losetup -a | grep $SWAPFILE | cut -f1 -d:)
dmsetup create test-dust --table "0 $[SWAPSIZE * 8] dust $LOOPDEV 0 512" || exit 1
DMDEV=/dev/mapper/test-dust
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

echo max > $CGDIR/memory.max
echo max > $CGDIR/memory.swap.max

echo "--- setup dm-dust"
dmsetup message test-dust 0 quiet
# BADBLOCKS="10 20 30"
BADBLOCKS="10"
for i in $BADBLOCKS ; do
	dmsetup message test-dust 0 addbadblock $i
done
dmsetup message test-dust 0 quiet
dmsetup message test-dust 0 countbadblocks
dmsetup message test-dust 0 enable

( echo "disable dm-dust in 1 sec..." ; sleep 1 ; dmsetup message test-dust 0 disable ) &

echo "#### swapoff !!! ####"
swapoff -a
if [ $? -eq 0 ] ; then
	echo "swapoff succeeded."
else
	echo "swapoff failed."
fi
echo "#### swapoff done !!! ####"
free

dmsetup message test-dust 0 disable
dmsetup message test-dust 0 clearbadblocks

# data corruption check
kill -SIGUSR1 $pid
