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

#define PM_ENTRY_BYTES		8
#define PM_PFRAME_BITS		55
#define PM_PFRAME_MASK		((1LL << PM_PFRAME_BITS) - 1)
#define PM_PFRAME(x)		((x) & PM_PFRAME_MASK)
#define PM_SOFT_DIRTY		(1ULL << 55)
#define PM_MMAP_EXCLUSIVE	(1ULL << 56)
#define PM_FILE			(1ULL << 61)
#define PM_SWAP			(1ULL << 62)
#define PM_PRESENT		(1ULL << 63)

#define ADDR_INPUT	0x700000000000UL
#define PS		4096
// 1 回のバッチで pfn チェックする範囲は 2MB 分、512 ページ
#define PM_BATCH	(1UL << 20)
// 512 エントリが入るバッファサイズは 4kB
#define PM_BUF		(PM_ENTRY_BYTES * PM_BATCH / PS)

static unsigned long pagemap_pfn(uint64_t val) {
        return (val & PM_PRESENT) ? PM_PFRAME(val) : 0;
}

int main(int argc, char **argv) {
	char *p;
	char pagemap_path[512];
	int pagemap_fd;
	int pipe_fd;
	int ret;
	uint64_t *buf = (uint64_t *)malloc(PM_BUF);
	int progress = 0;
	int progress_total = 0;
	unsigned long target;
	unsigned long target_base;
	struct sysinfo si;

	signal(SIGUSR1, sig_handle_flag);
	signal(SIGBUS, sig_handle_flag);

	sprintf(pagemap_path, "/proc/%d/pagemap", getpid());
	pagemap_fd = open(pagemap_path, O_RDONLY);
	if (pagemap_fd == -1) {
		perror("open");
		return 1;
	}

	pipe_fd = open("/tmp/ffifo", O_RDWR);
	if (pipe_fd == -1)
		pipe_fd = 1;

	target_base = 0;
	for (int k = 0; k < 100; k++) {
		int total_batches;
		int start_pagemap_check = target_base / PM_BATCH;

		sysinfo(&si);
		target = si.freeram - (1UL << 28);
		target = target - target % PM_BATCH;
		dprintf(pipe_fd, "si.freeram %lx, target %lx\n", si.freeram, target);

		p = mmap((void *)ADDR_INPUT + target_base, target, PROT_READ|PROT_WRITE,
			 MAP_ANONYMOUS|MAP_SHARED, -1, 0);
		if (p == (void *)-1) {
			dprintf(pipe_fd, "target_base %lx, target %lx\n", target_base, target);
			perror("mmap");
			return 1;
		}
		ret = madvise(p, target, MADV_RANDOM);
		if (ret == -1) {
			perror("madvise");
			return 1;
		}
		memset(p, 'a', target);

		target_base += target;
		progress_total = 0;
		total_batches = target_base / PM_BATCH;

		dprintf(pipe_fd, "Turn %d, %lx batches\n", k, total_batches);
		if (argc > 1 && !strcmp(argv[1], "all"))
			start_pagemap_check = 0;
		for (int i = start_pagemap_check; i < total_batches; i++) {
			ret = pread(pagemap_fd, buf, PM_BUF,
				    PM_ENTRY_BYTES * (ADDR_INPUT + i * PM_BATCH) / PS);
			if (ret != PM_BUF) {
				perror("pread");
				return 1;
			}

			progress = 0;
			for (int j = 0; j < PM_BUF / PM_ENTRY_BYTES; j++) {
				unsigned long pfn = pagemap_pfn(buf[j]);

				if (pfn == 0)
					continue;
				if ((pfn % 2) == 1) {
					ret = madvise((void *)ADDR_INPUT + i * PM_BATCH + j * 4096, 4096, MADV_REMOVE);
					if (ret == -1) {
						perror("madvise");
						return 1;
					}
				} else {
					progress++;
				}
			}
			progress_total += progress;
		}
		dprintf(pipe_fd, "Turn %d, allocated %d\n", k, progress_total);
	}
	dprintf(pipe_fd, "keep memory allocated\n");
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
/proc/vmstat
EOF
}

if [ "$1" == monitor ] ; then
	fragmentation_monitor
	exit 0
fi

PROACTIVNESS=20
if [ "$1" ] && [[ "$1" =~ ^[0-9]*$ ]] ; then
	PROACTIVNESS=$1
fi

gcc -o /tmp/fragmentation /tmp/fragmentation.c || exit 1

[ ! -e /tmp/ffifo ] && mkfifo /tmp/ffifo

echo 1 > /proc/sys/vm/compact_memory
echo 3 > /proc/sys/vm/drop_caches

set -x
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag
echo 0 > /proc/sys/vm/compact_unevictable_allowed
echo $PROACTIVNESS > /proc/sys/vm/compaction_proactiveness
set +x

/tmp/fragmentation > /tmp/ffifo &
pid=$?
trap "kill $pid" SIGINT

while true ; do
	if ! kill -0 $pid 2> /dev/null ; then
		echo "fragmentation process was killed."
		exit 1
	elif read -t3 line <> /tmp/ffifo ; then
		echo ">> $line"
		case "$line" in
			"keep memory allocated")
				break
				;;
			*)
				;;
		esac
	fi
done

echo "fragmentation is prepared."
fragmentation_monitor
