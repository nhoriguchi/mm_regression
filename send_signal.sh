#!/bin/bash

usage() {
    echo "Usage: `basename $BASH_SOURCE` [-shv]"
    echo "  -s: show contents of Systemtap script"
    echo "  -h: show this message"
    echo "  -v: verbose"
    exit 1
}

SHOW=
VERBOSE=""
while getopts shv OPT
do
  case $OPT in
    "s" ) SHOW="on" ;;
    "v" ) VERBOSE="--vp 11111" ;;
    "h" ) usage ;;
  esac
done

shift $[OPTIND - 1]

stap=/usr/local/bin/stap
# stap=/root/src/systemtap/stap

if ! grep "/sys/kernel/debug" /proc/mounts > /dev/null 2>&1 ; then
    mount -t debugfs none /sys/kernel/debug
fi

tmpf=`mktemp`

pb='printf("%28s %12s %5d %2d %d:", probefunc(), execname(), pid(), cpu(), gettimeofday_us())'
pb='printf("%28s %12s %5d %2d:", probefunc(), execname(), pid(), cpu())'

# mapping between function's arguments and registeres
# %rdi, %rsi, %rdx, %rcx, %r8, %r9

MEMBLOCK=$(grep " memblock$" /proc/kallsyms | cut -f1 -d' ')

cat <<EOF > ${tmpf}.stp
#!/usr/bin/stap

%{
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/fs.h>
#include <linux/hugetlb.h>
#include <linux/mmzone.h>
#include <linux/pageblock-flags.h>
#include <linux/memory.h>
#include <linux/path.h>
#include <linux/dcache.h>
#include <linux/blk_types.h>
#include <linux/memblock.h>
#include <linux/sched.h>
#include <linux/types.h>
#include <linux/proc_fs.h>
#include <linux/vmalloc.h>
#include <linux/spinlock.h>
#include <linux/highmem.h>
#include <uapi/asm-generic/siginfo.h>

#ifndef __GFP_NO_KSWAPD
#define __GFP_NO_KSWAPD (0)
#endif

#define GFP_ALLOC_LIKE_HUGETLB (GFP_HIGHUSER_MOVABLE|__GFP_REPEAT)
#define GFP_ALLOC_LIKE_THP     (GFP_HIGHUSER_MOVABLE|__GFP_NOMEMALLOC| \
				__GFP_NORETRY|__GFP_NO_KSWAPD)

#define PARAM_MSDELAY 100
#define PARAM_GFPFLAGS GFP_HIGHUSER_MOVABLE
#define PARAM_ALLOCS 100
#define PARAM_ORDER 5

unsigned long __call_kernel_func1(unsigned long func, unsigned long arg1)
{
        char *(*f)(unsigned long) = (char *(*)(unsigned long))func;
        return (unsigned long)f(arg1);
}
unsigned long __call_kernel_func2(unsigned long func, unsigned long arg1, unsigned long arg2)
{
        char *(*f)(unsigned long, unsigned long) = (char *(*)(unsigned long, unsigned long))func;
        return (unsigned long)f(arg1, arg2);
}
unsigned long __call_kernel_func3(unsigned long func, unsigned long arg1, unsigned long arg2, unsigned long arg3)
{
        char *(*f)(unsigned long, unsigned long, unsigned long) = (char *(*)(unsigned long, unsigned long, unsigned long))func;
        return (unsigned long)f(arg1, arg2, arg3);
}
unsigned long __call_kernel_func4(unsigned long func, unsigned long arg1, unsigned long arg2, unsigned long arg3, unsigned long arg4)
{
        char *(*f)(unsigned long, unsigned long, unsigned long, unsigned long) = (char *(*)(unsigned long, unsigned long, unsigned long, unsigned long))func;
        return (unsigned long)f(arg1, arg2, arg3, arg4);
}
unsigned long __call_kernel_func5(unsigned long func, unsigned long arg1, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5)
{
        char *(*f)(unsigned long, unsigned long, unsigned long, unsigned long, unsigned long) = (char *(*)(unsigned long, unsigned long, unsigned long, unsigned long, unsigned long))func;
        return (unsigned long)f(arg1, arg2, arg3, arg4, arg5);
}
unsigned long __call_kernel_func6(unsigned long func, unsigned long arg1, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5, unsigned long arg6)
{
        char *(*f)(unsigned long, unsigned long, unsigned long, unsigned long, unsigned long, unsigned long) = (char *(*)(unsigned long, unsigned long, unsigned long, unsigned long, unsigned long, unsigned long))func;
        return (unsigned long)f(arg1, arg2, arg3, arg4, arg5, arg6);
}

struct pagemapread {
        int pos, len;
        void *buffer;
        bool v2;
};

struct pglist_data *first_online_pgdat(void)
{
        return NODE_DATA(first_online_node);
}

struct pglist_data *next_online_pgdat(struct pglist_data *pgdat)
{
        int nid = next_online_node(pgdat->node_id);

        if (nid == MAX_NUMNODES)
                return NULL;
        return NODE_DATA(nid);
}

void __init_memblock __next_mem_pfn_range(int *idx, int nid,
                                unsigned long *out_start_pfn,
                                unsigned long *out_end_pfn, int *out_nid)
{
        struct memblock *memblock = (struct memblock *)0x${MEMBLOCK};
        struct memblock_type *type = &memblock->memory;
        struct memblock_region *r;

        while (++*idx < type->cnt) {
                r = &type->regions[*idx];

                if (PFN_UP(r->base) >= PFN_DOWN(r->base + r->size))
                        continue;
                if (nid == MAX_NUMNODES || nid == r->nid)
                        break;
        }
        if (*idx >= type->cnt) {
                *idx = -1;
                return;
        }

        if (out_start_pfn)
                *out_start_pfn = PFN_UP(r->base);
        if (out_end_pfn)
                *out_end_pfn = PFN_DOWN(r->base + r->size);
        if (out_nid)
                *out_nid = r->nid;
}

bool is_memblock_offlined(struct memory_block *mem)
{                                                  
        return mem->state == MEM_OFFLINE;          
}                                                  

extern struct memory_block *find_memory_block(struct mem_section *section);

%}
function call_kernel_func1:long (func:long, a1:long) %{ STAP_RETVALUE = (long)__call_kernel_func1(STAP_ARG_func, STAP_ARG_a1); %}
function call_kernel_func2:long (func:long, a1:long, a2:long) %{ STAP_RETVALUE = (long)__call_kernel_func2(STAP_ARG_func, STAP_ARG_a1, STAP_ARG_a2); %}
function call_kernel_func3:long (func:long, a1:long, a2:long, a3:long) %{ STAP_RETVALUE = (long)__call_kernel_func3(STAP_ARG_func, STAP_ARG_a1, STAP_ARG_a2, STAP_ARG_a3); %}
function call_kernel_func4:long (func:long, a1:long, a2:long, a3:long, a4:long) %{ STAP_RETVALUE = (long)__call_kernel_func4(STAP_ARG_func, STAP_ARG_a1, STAP_ARG_a2, STAP_ARG_a3, STAP_ARG_a4); %}
function call_kernel_func5:long (func:long, a1:long, a2:long, a3:long, a4:long, a5:long) %{ STAP_RETVALUE = (long)__call_kernel_func5(STAP_ARG_func, STAP_ARG_a1, STAP_ARG_a2, STAP_ARG_a3, STAP_ARG_a4, STAP_ARG_a5); %}
function call_kernel_func6:long (func:long, a1:long, a2:long, a3:long, a4:long, a5:long, a6:long) %{ STAP_RETVALUE = (long)__call_kernel_func6(STAP_ARG_func, STAP_ARG_a1, STAP_ARG_a2, STAP_ARG_a3, STAP_ARG_a4, STAP_ARG_a5, STAP_ARG_a6); %}
function arg1:long () { return register("rdi"); }
function arg2:long () { return register("rsi"); }
function arg3:long () { return register("rdx"); }
function arg4:long () { return register("rcx"); }
function arg5:long () { return register("r8"); }
function arg6:long () { return register("r9"); }

function pfn_to_page:long (val:long) %{ STAP_RETVALUE = (long)pfn_to_page((unsigned long)STAP_ARG_val); %}
function page_to_pfn:long (val:long) %{ STAP_RETVALUE = (long)page_to_pfn((struct page *)STAP_ARG_val); %}
function page_count:long (val:long) %{ STAP_RETVALUE = (long)page_count((struct page *)STAP_ARG_val); %}
function page_mapcount:long (val:long) %{ STAP_RETVALUE = (long)page_mapcount((struct page *)STAP_ARG_val); %}
function ptr_deref:long (val:long) %{ STAP_RETVALUE = (long)*(char *)STAP_ARG_val; %}

function dcount:long (val:long) %{
    struct dentry *de = ((struct dentry *)STAP_ARG_val);
    if (de)
        STAP_RETVALUE = (unsigned long)de->d_lockref.count;
    else
        STAP_RETVALUE = (unsigned long)0;
%}

function path_dentry:long (val:long) %{
    struct path *path = ((struct path *)STAP_ARG_val);
    if (path)
        STAP_RETVALUE = (unsigned long)path->dentry;
    else
        STAP_RETVALUE = (unsigned long)0;
%}

function showstring (val:long, len:long) %{
    char *str = (char *)STAP_ARG_val;
    char dummy[512];
    int ret;
    int i;
    ret = sscanf(str, "%s\n", dummy);
    for (i = 0; i < 40; i++)
        printk("%c", str[i]);
    printk("  ret %x\n", ret);
%}
#    str[(long)STAP_ARG_len+1] = 0;

function showstring2 (val:long) %{
    int i;
    char *str = (char *)STAP_ARG_val;
    for (i = 0; i < 40; i++) {
        if (str[i] == 0)
            printk("[%c]", str[i]);
        else
            printk("%c", str[i]);
    }
    printk("] %x\n", (unsigned int)strlen(str));
%}

function show_pgdats () %{
    struct pglist_data *pgdat;
    int nid = 3;
    int i, n = 0;
    unsigned long start, end;
    unsigned long pfn, sec_begin;
    struct mem_section *memsec;
    struct memory_block *memblk;

    for_each_online_pgdat(pgdat) {
        printk("pgdat:%p\n", pgdat);
        printk("  id:%d\n", pgdat->node_id);
        printk("  start:%lx\n", pgdat->node_start_pfn);
        printk("  present:%lx\n", pgdat->node_present_pages);
        printk("  scanned:%lx\n", pgdat->node_spanned_pages);
        continue;
        pfn = pgdat->node_start_pfn;
        end = pgdat_end_pfn(pgdat);
        for (; pfn < end; pfn += PAGES_PER_SECTION) {
            if (present_section_nr(pfn_to_section_nr(pfn))) {
                memsec = __nr_to_section(pfn_to_section_nr(pfn));
                memblk = find_memory_block(memsec);
                printk(" sec %ld, offline %d\n", pfn_to_section_nr(pfn), is_memblock_offlined(memblk));
            }
        }
    }
%}
EOF

echo_stp() { echo "$@" >> ${tmpf}.stp; }
while read name type deref ; do
    echo_stp "function ${name}:long (val:long) %{"
    echo_stp "    STAP_RETVALUE = (long)((struct ${type} *)STAP_ARG_val)${deref};"
    echo_stp "%}"
done <<EOF
page_flag     page             ->flags
vma_flag      vm_area_struct   ->vm_flags
vma_start     vm_area_struct   ->vm_start
vma_next      vm_area_struct   ->vm_next
vma_prev      vm_area_struct   ->vm_prev
vma_end       vm_area_struct   ->vm_end
walk_vma      mm_walk          ->vma
walk_skip     mm_walk          ->skip
walk_private  mm_walk          ->private
file_pos      file             ->f_pos
file_mapping  file             ->f_mapping
pm_pos        pagemapread      ->pos
vmf_pgoff     vm_fault         ->pgoff
vmf_vaddr     vm_fault         ->virtual_address
vmf_page      vm_fault         ->page
as_flags      address_space    ->flags
page_mapping  page             ->mapping
page_index    page             ->index
kiocb_file    kiocb            ->ki_filp
siginfo_no    siginfo          ->si_signo
siginfo_err   siginfo          ->si_errno
siginfo_code  siginfo          ->si_code
regs_ip       pt_regs          ->ip
regs_cs       pt_regs          ->cs
inode_blkbits inode            ->i_blkbits
iov_base      iovec            ->iov_base
iov_len       iovec            ->iov_len
filename_name filename         ->name
dentry_inode  dentry           ->d_inode
inode_mapping inode            ->i_mapping
bio_bi_end_io bio              ->bi_end_io
pgdat_start   pglist_data      ->node_start_pfn
pgdat_present pglist_data      ->node_present_pages
pgdat_spanned pglist_data      ->node_spanned_pages
pgdat_nodeid  pglist_data      ->node_id
EOF

getsymaddr() {
    grep $1 /proc/kallsyms | awk '{print $1}'
}

KPC_PATH=$(grep kpagecache_path /proc/kallsyms | cut -f1 -d' ')
NODE_DATA=$(grep " node_data$" /proc/kallsyms | cut -f1 -d' ')
PID=$1
FORCE_SIG_INFO=$(grep " force_sig_info$" /proc/kallsyms | cut -f1 -d' ' | head -n1)
SEND_SIG_INFO=$(grep " send_sig_info$" /proc/kallsyms | cut -f1 -d' ' | head -n1)

cat <<EOF >> ${tmpf}.stp

function send_signal() %{
	unsigned long order;		/* Order of pages */
	unsigned long numpages;		/* Number of pages to allocate */
	struct page **pages = NULL;	/* Pages that were allocated */
	unsigned long attempts=0, printed=0;
	unsigned long alloced=0;
	unsigned long nextjiffies = jiffies;
	unsigned long lastjiffies = jiffies;
	unsigned long success=0;
	unsigned long fail=0;
	unsigned long resched_count=0;
	unsigned long aborted=0;
	unsigned long page_dma=0, page_dma32=0, page_normal=0, page_highmem=0, page_easyrclm=0;
	int ret;
	struct zone *zone;
	char finishString[60];
	int timing_pages, pages_required;
	bool enabled_preempt = false;
	ktime_t start_ktime;
	ktime_t * alloc_latencies = NULL;
	bool * alloc_outcomes = NULL;

	struct task_struct *t = NULL;
	struct task_struct *tsk;
	pid_t t_pid  = (pid_t)(long)${PID};
	struct pid *p_pid = find_get_pid(t_pid);
	struct siginfo si;
	int (*force_sig_info)(int, struct siginfo *, struct task_struct *) = (int (*)(int, struct siginfo *, struct task_struct *))0x${FORCE_SIG_INFO};
	int (*send_sig_info)(int, struct siginfo *, struct task_struct *) = (int (*)(int, struct siginfo *, struct task_struct *))0x${SEND_SIG_INFO};

	rcu_read_lock();
	t = pid_task(p_pid, PIDTYPE_PID);
	put_pid(p_pid);
	rcu_read_unlock();

	if (!t)
		return;

	for_each_process(tsk) {
		_stp_printf("%d\t%s\n", tsk->pid, tsk->comm);
	}

	_stp_printf("Task struct of pid %d (%s) is %lx\n", ${PID}, t->comm, t);
	_stp_printf("MM struct of pid %d is %lx\n", ${PID}, t->mm);

	si.si_signo = SIGBUS;
	si.si_errno = 0;
	si.si_addr = 0x0;
	si.si_addr_lsb = PAGE_SHIFT;

/*
	si.si_code = BUS_MCEERR_AR;
	ret = force_sig_info(SIGBUS, &si, t);
*/
	si.si_code = BUS_MCEERR_AO;
	ret = send_sig_info(SIGBUS, &si, t);

	_stp_printf("SIGBUS sent (ret %d)\n", ret);
	
	return;

	/* Get the parameters */
	order = PARAM_ORDER;
	numpages = PARAM_ALLOCS;


	/* Check parameters */
	if (order < 0 || order >= MAX_ORDER) {
		_stp_printf("Order request of %lu makes no sense\n", order);
		goto out_preempt;
	}

	if (numpages < 0) {
		_stp_printf("Number of pages %lu makes no sense\n", numpages);
		goto out_preempt;
	}

	if (in_atomic()) {
		_stp_printf("WARNING: Enabling preempt behind systemtaps back\n");
		preempt_enable();
		enabled_preempt = true;
	}

	/* 
	 * Allocate memory to store pointers to pages.
	 */
	pages = __vmalloc((numpages+1) * sizeof(struct page **),
			GFP_KERNEL|__GFP_HIGHMEM,
			PAGE_KERNEL);
	if (pages == NULL) {
		_stp_printf("Failed to allocate space to store page pointers\n");
		goto out_preempt;
	}
	/*
	 * Allocate arrays for storing allocation outcomes and latencies
	 */
	alloc_latencies = __vmalloc((numpages+1) * sizeof(ktime_t),
			GFP_KERNEL|__GFP_HIGHMEM,
			PAGE_KERNEL);
	if (alloc_latencies == NULL) {
		_stp_printf("Failed to allocate space to store allocation latencies\n");
		goto out_preempt;
	}
	alloc_outcomes = __vmalloc((numpages+1) * sizeof(bool),
			GFP_KERNEL|__GFP_HIGHMEM,
			PAGE_KERNEL);
	if (alloc_outcomes == NULL) {
		_stp_printf("Failed to allocate space to store allocation outcomes\n");
		goto out_preempt;
	}

#if defined(OOM_DISABLE)
	/* Disable OOM Killer */
	_stp_printf("Disabling OOM killer for running process\n");
	oomkilladj = current->oomkilladj;
	current->oomkilladj = OOM_DISABLE;
#endif /* OOM_DISABLE */

	/*
	 * Attempt to allocate the requested number of pages
	 */
	while (attempts != numpages) {
		struct page *page;
		if (lastjiffies > jiffies)
			nextjiffies = jiffies;

		/* What the hell is this, should be a waitqueue */
		while (jiffies < nextjiffies) {
			__set_current_state(TASK_RUNNING);
			schedule();
		}
		nextjiffies = jiffies + ( (HZ * PARAM_MSDELAY)/1000);

		/* Print message if this is taking a long time */
		if (jiffies - lastjiffies > HZ) {
			printk("High order alloc test attempts: %lu (%lu)\n",
					attempts, alloced);
		}

		/* Print out a message every so often anyway */
		if (attempts > 0 && attempts % 10 == 0) {
			printk("High order alloc test attempts: %lu (%lu)\n",
					attempts, alloced);
		}

		lastjiffies = jiffies;

		start_ktime = ktime_get_real();
		page = alloc_pages(PARAM_GFPFLAGS | __GFP_NOWARN, order);
		alloc_latencies[attempts] = ktime_sub (ktime_get_real(), start_ktime);

		if (page) {
			alloc_outcomes[attempts] = true;
			//_stp_printf(testinfo, HIGHALLOC_BUDDYINFO, attempts, 1);
			success++;
			pages[alloced++] = page;

			/* Count what zone this is */
			zone = page_zone(page);
			if (zone->name != NULL && !strcmp(zone->name, "Movable")) page_easyrclm++;
			if (zone->name != NULL && !strcmp(zone->name, "HighMem")) page_highmem++;
			if (zone->name != NULL && !strcmp(zone->name, "Normal")) page_normal++;
			if (zone->name != NULL && !strcmp(zone->name, "DMA32")) page_dma32++;
			if (zone->name != NULL && !strcmp(zone->name, "DMA")) page_dma++;


			/* Give up if it takes more than 60 seconds to allocate */
			if (jiffies - lastjiffies > HZ * 600) {
				printk("Took more than 600 seconds to allocate a block, giving up");
				aborted = attempts + 1;
				attempts = numpages;
				break;
			}

		} else {
			alloc_outcomes[attempts] = false;
			//printp_buddyinfo(testinfo, HIGHALLOC_BUDDYINFO, attempts, 0);
			fail++;

			/* Give up if it takes more than 30 seconds to fail */
			if (jiffies - lastjiffies > HZ * 1200) {
				printk("Took more than 1200 seconds and still failed to allocate, giving up");
				aborted = attempts + 1;
				attempts = numpages;
				break;
			}
		}
		attempts++;
	}

	/* Disable preempt now to make sure everthing is actually printed */
	if (enabled_preempt) {
		preempt_disable();
		enabled_preempt = false;
	}

	for (printed = 0; printed < attempts; printed++) 
		_stp_printf("%d %s %lu\n",
			printed,
			alloc_outcomes[printed] ? "success" : "failure",
			ktime_to_ns(alloc_latencies[printed]));

	/* Re-enable OOM Killer state */
#ifdef OOM_DISABLED
	_stp_printf("Re-enabling OOM Killer status\n");
	current->oomkilladj = oomkilladj;
#endif

	_stp_printf("Test completed with %lu allocs, printing results\n", alloced);

	/* Print header */
	_stp_printf("Order:                 %lu\n", order);
	_stp_printf("GFP flags:             0x%lX\n", PARAM_GFPFLAGS);
	_stp_printf("Allocation type:       %s\n", (PARAM_GFPFLAGS & __GFP_HIGHMEM) ? "HighMem" : "Normal");
	_stp_printf("Attempted allocations: %lu\n", numpages);
	_stp_printf("Success allocs:        %lu\n", success);
	_stp_printf("Failed allocs:         %lu\n", fail);
	_stp_printf("DMA32 zone allocs:       %lu\n", page_dma32);
	_stp_printf("DMA zone allocs:       %lu\n", page_dma);
	_stp_printf("Normal zone allocs:    %lu\n", page_normal);
	_stp_printf("HighMem zone allocs:   %lu\n", page_highmem);
	_stp_printf("EasyRclm zone allocs:  %lu\n", page_easyrclm);
	_stp_printf("%% Success:            %lu\n", (success * 100) / (unsigned long)numpages);

	/*
	 * Free up the pages
	 */
	_stp_printf("Test complete, freeing %lu pages\n", alloced);
	if (alloced > 0) {
		do {
			alloced--;
			if (pages[alloced] != NULL)
				__free_pages(pages[alloced], order);
		} while (alloced != 0);
	}
	
	if (aborted == 0)
		strcpy(finishString, "Test completed successfully\n");
	else
		sprintf(finishString, "Test aborted after %lu allocations due to delays\n", aborted);
	
	_stp_printf("%s", finishString);

out_preempt:
	if (enabled_preempt)
		preempt_disable();

	if (alloc_latencies)
		vfree(alloc_latencies);
	if (alloc_outcomes)
		vfree(alloc_outcomes);
	if (pages)
		vfree(pages);
	
	return;
%}


probe begin {
    send_signal();
    exit();
}
EOF

[ "$SHOW" ] && less ${tmpf}.stp
$stap ${tmpf}.stp -g ${VERBOSE} -t -w --suppress-time-limits #-D MAXSKIPPED=

rm -f ${tmpf}*
