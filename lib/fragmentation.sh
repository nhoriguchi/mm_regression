cat <<EOF > /tmp/fragmentation.c
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/sysinfo.h>
#include <signal.h>

void sig_handle_flag(int signo) { ; }

#define ADDR_INPUT	0x700000000000UL
#define PS		4096
#define THPS		0x200000UL

struct sysinfo si;
int usage_control = 0;
int free_control = 256; // [0, 256]
int pipe_fd;

int count_order_9() {
	char buf[256];
	FILE *fs;
	int nr9, nr10;
	int ret = -1;

	fs = fopen("/proc/buddyinfo", "r");
	if (!fs) {
		perror("fopen");
		exit(1);
	}

	while(fgets(buf, 256, fs)) {
		char *ptr = strstr(buf, "Node 1, zone   Normal");

		if (ptr) {
			if (sscanf(ptr, "Node 1, zone   Normal %*d %*d %*d %*d %*d %*d %*d %*d %*d %d %d", &nr9, &nr10)) {
				ret = nr9 + 2 * nr10;
				break;
			}
		}
	}
	fclose(fs);

	if (ret == -1) {
		perror("failed to parse /proc/buddyinfo");
		exit(1);
	}

	return ret;
}

char *mmap_thp(size_t size) {
	char *p;

	p = mmap((void *)ADDR_INPUT, size, PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);
	if (p == (void *)-1) {
		perror("mmap");
		exit(1);
	}

	if (madvise(p, size, MADV_HUGEPAGE) == -1) {
		perror("madvise");
		exit(1);
	}

	return p;
}

int main(int argc, char **argv) {
	int ret;
	char *p;
	int thps;
	int anons;
	char *panon;
	int i;

	signal(SIGUSR1, sig_handle_flag);

	if (argc > 1)
		usage_control = strtol(argv[1], NULL, 0);
	if (argc > 2)
		free_control = strtol(argv[2], NULL, 0);

	pipe_fd = open("/tmp/ffifo", O_RDWR);
	if (pipe_fd == -1)
		pipe_fd = 1;

	sysinfo(&si);
	p = mmap_thp(si.totalram);
	thps = count_order_9() + usage_control;

	dprintf(pipe_fd, "usage_control %d, free_control %d\n", usage_control, free_control);
	dprintf(pipe_fd, "allocate %d thps, then free %d/512 of them.\n", thps, free_control);
	for (i = 0; i < thps; i++) {
		char *ptr = p + i * THPS;
		memset(ptr, 'a', THPS);
	}

	dprintf(pipe_fd, "thp allocated\n");
	pause();

	for (i = 0; i < thps; i++) {
		char *ptr = p + i * THPS;

		for (int j = 0; j < free_control; j++) {
			// ret = madvise(ptr + (2 * j + 1) * PS, PS, MADV_DONTNEED);
			ret = madvise(ptr + (2 * j + 1) * PS, PS, MADV_PAGEOUT);
			// ret = madvise(ptr + (2 * j + 1) * PS, PS, MADV_REMOVE);
			if (ret == -1) {
				perror("madvise");
				exit(1);
			}
		}
	}
	dprintf(pipe_fd, "fragmentation generated\n");
	pause();
}
EOF

fragmentation_monitor() {
	echo "##### $(cat /proc/uptime)"
	while read f ; do
	    echo "### $f"
		cat $f
	done <<EOF
/proc/buddyinfo
/sys/kernel/debug/extfrag/extfrag_index
/sys/kernel/debug/extfrag/unusable_index
/proc/sys/vm/extfrag_threshold
EOF
	echo "### grep compact /proc/vmstat"
	grep compact /proc/vmstat
	echo "### free"
	free
}

if [ "$1" == monitor ] ; then
	fragmentation_monitor
	exit 0
fi

PROACTIVNESS=20
if [ "$1" ] && [[ "$1" =~ ^[0-9]*$ ]] ; then
	PROACTIVNESS=$1
fi
USAGE_CONTROL=0
if [ "$2" ] && [[ "$2" =~ ^[\-0-9]*$ ]] ; then
	USAGE_CONTROL=$2
fi
FREE_CONTROL=256
if [ "$3" ] && [[ "$3" =~ ^[0-9]*$ ]] ; then
	FREE_CONTROL=$3
fi

gcc -o /tmp/fragmentation /tmp/fragmentation.c || exit 1

[ ! -e /tmp/ffifo ] && mkfifo /tmp/ffifo

echo 1 > /proc/sys/vm/compact_memory
echo 3 > /proc/sys/vm/drop_caches
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
echo 1 > /proc/sys/vm/compact_unevictable_allowed
echo $PROACTIVNESS > /proc/sys/vm/compaction_proactiveness
echo 0 > /proc/sys/vm/compaction_proactiveness
echo 60 > /proc/sys/vm/swappiness

fragmentation_monitor > 0.log
trace-cmd record -q -p function -l proactive_compact_node -l kcompactd_do_work -l compact_zone -T bash -c "numactl --membind 1 --cpunodebind 1 /tmp/fragmentation $USAGE_CONTROL $FREE_CONTROL" &
sleep 3
pid=$(pgrep -f -x "/tmp/fragmentation $USAGE_CONTROL $FREE_CONTROL")
echo "pid:$pid"

while true ; do
	if ! kill -0 $pid 2> /dev/null ; then
		echo "fragmentation process was killed."
		exit 1
	elif read -t3 line <> /tmp/ffifo ; then
		echo ">> $line"
		case "$line" in
			"thp allocated")
				fragmentation_monitor > 1.log
				echo 12 > /proc/sys/vm/compaction_proactiveness
				sleep 1
				kill -SIGUSR1 $pid
				;;
			"fragmentation generated")
				sleep 1
				fragmentation_monitor > 2.log
				kill -SIGUSR1 $pid
				sleep 3
				break
				;;
			*)
				;;
		esac
	fi
done
sleep 1
trace-cmd report
