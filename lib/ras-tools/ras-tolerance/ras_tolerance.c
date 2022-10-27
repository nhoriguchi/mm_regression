/*
 * Copyright (C) 2022 Alibaba Corporation
 * Author: Shuai Xue
 *
 * This software may be redistributed and/or modified under the terms of
 * the GNU General Public License ("GPL") version 2 only as published by the
 * Free Software Foundation.
 */

#define pr_fmt(fmt) "%s: " fmt, __func__
#define GHES_PFX "GHES: "

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/io.h>
#include <linux/cper.h>

#include <acpi/ghes.h>
#include <asm/fixmap.h>

#include <linux/moduleparam.h>
#include <linux/init.h>

#include <linux/io.h>
#include <linux/interrupt.h>
#include <linux/timer.h>
#include <linux/cper.h>
#include <linux/platform_device.h>
#include <linux/mutex.h>
#include <linux/ratelimit.h>
#include <linux/vmalloc.h>
#include <linux/irq_work.h>
#include <linux/llist.h>
#include <linux/genalloc.h>
#include <linux/pci.h>
#include <linux/pfn.h>
#include <linux/aer.h>
#include <linux/nmi.h>
#include <linux/sched/clock.h>
#include <linux/uuid.h>
#include <linux/ras.h>
#include <linux/task_work.h>

#include <acpi/actbl1.h>
#include <acpi/ghes.h>
#include <acpi/apei.h>
#include <asm/fixmap.h>
#include <asm/tlbflush.h>
#include <ras/ras_event.h>
#include <linux/acpi.h>

#define LOOKUP_SYMS_EX(name, sym)                                    \
	do                                                           \
	{                                                            \
		orig_##name = (void *)kallsyms_lookup_name(sym);     \
		if (!orig_##name)                                    \
		{                                                    \
			pr_err("kallsyms_lookup_name: %s\n", #name); \
			return -EINVAL;                              \
		}                                                    \
	} while (0)

#define LOOKUP_SYMS(name) LOOKUP_SYMS_EX(name, #name)

#define MAX_SYMBOL_LEN 64
static char symbol[MAX_SYMBOL_LEN] = "ghes_in_nmi_queue_one_entry";
module_param_string(symbol, symbol, sizeof(symbol), 0644);

extern int apei_read(u64 *val, struct acpi_generic_address *reg);
extern void cper_estatus_print(const char *pfx,
			       const struct acpi_hest_generic_status *estatus);
extern int cper_estatus_check_header(const struct acpi_hest_generic_status *estatus);
extern int cper_estatus_check(const struct acpi_hest_generic_status *estatus);

static void (*orig_ghes_copy_tofrom_phys)(void *buffer, u64 paddr, u32 len,
					  int from_phys,
					  enum fixed_addresses fixmap_idx);

/* Read the CPER block, returning its address, and header in estatus. */
static int __ghes_peek_estatus(struct ghes *ghes,
			       struct acpi_hest_generic_status *estatus,
			       u64 *buf_paddr, enum fixed_addresses fixmap_idx)
{
	struct acpi_hest_generic *g = ghes->generic;
	int rc;

	rc = apei_read(buf_paddr, &g->error_status_address);
	if (rc)
	{
		*buf_paddr = 0;
		pr_warn_ratelimited(FW_WARN GHES_PFX
				    "Failed to read error status block address for hardware error source: %d.\n",
				    g->header.source_id);
		return -EIO;
	}
	if (!*buf_paddr)
		return -ENOENT;

	orig_ghes_copy_tofrom_phys(estatus, *buf_paddr, sizeof(*estatus), 1,
				   fixmap_idx);
	if (!estatus->block_status)
	{
		*buf_paddr = 0;
		return -ENOENT;
	}

	return 0;
}

static int __ghes_read_estatus(struct acpi_hest_generic_status *estatus,
			       u64 buf_paddr, enum fixed_addresses fixmap_idx,
			       size_t buf_len)
{
	orig_ghes_copy_tofrom_phys(estatus, buf_paddr, buf_len, 1, fixmap_idx);
	if (cper_estatus_check(estatus))
	{
		pr_warn_ratelimited(FW_WARN GHES_PFX
				    "Failed to read error status block!\n");
		return -EIO;
	}

	return 0;
}

static inline u32 cper_estatus_len(struct acpi_hest_generic_status *estatus)
{
	if (estatus->raw_data_length)
		return estatus->raw_data_offset +
		       estatus->raw_data_length;
	else
		return sizeof(*estatus) + estatus->data_length;
}

/* Check the top-level record header has an appropriate size. */
static int __ghes_check_estatus(struct ghes *ghes,
				struct acpi_hest_generic_status *estatus)
{
	u32 len = cper_estatus_len(estatus);

	if (len < sizeof(*estatus))
	{
		pr_warn_ratelimited(FW_WARN GHES_PFX "Truncated error status block!\n");
		return -EIO;
	}

	if (len > ghes->generic->error_block_length)
	{
		pr_warn_ratelimited(FW_WARN GHES_PFX "Invalid error status block length!\n");
		return -EIO;
	}

	if (cper_estatus_check_header(estatus))
	{
		pr_warn_ratelimited(FW_WARN GHES_PFX "Invalid CPER header!\n");
		return -EIO;
	}

	return 0;
}

static int ghes_read_estatus(struct ghes *ghes,
			     struct acpi_hest_generic_status *estatus,
			     u64 *buf_paddr, enum fixed_addresses fixmap_idx)
{
	int rc;

	rc = __ghes_peek_estatus(ghes, estatus, buf_paddr, fixmap_idx);
	if (rc)
		return rc;

	rc = __ghes_check_estatus(ghes, estatus);
	if (rc)
		return rc;

	return __ghes_read_estatus(estatus, *buf_paddr, fixmap_idx,
				   cper_estatus_len(estatus));
}

/* For each probe you need to allocate a kprobe structure */
static struct kprobe kp = {
    .symbol_name = symbol,
};

/* kprobe pre_handler: called just before the probed instruction is executed */
static int __kprobes handler_pre(struct kprobe *p, struct pt_regs *regs)
{
	struct acpi_hest_generic_status *estatus;
	struct ghes *ghes;
	u64 buf_paddr;
	int rc;
	__u16 new_severity = CPER_SEV_RECOVERABLE;
	__u16 old_severity;

	ghes = (struct ghes *)regs_get_register(regs, 0);
	estatus = ghes->estatus;

	rc = ghes_read_estatus(ghes, estatus, &buf_paddr, FIX_APEI_GHES_IRQ);

	old_severity = estatus->error_severity;
	estatus->error_severity = CPER_SEV_RECOVERABLE;
	pr_info("<%s> Overwrite %s => %s\n", p->symbol_name,
		cper_severity_str(old_severity),
		cper_severity_str(new_severity));

	orig_ghes_copy_tofrom_phys(estatus, buf_paddr, sizeof(*estatus), 0,
				   FIX_APEI_GHES_IRQ);

	/* A dump_stack() here will give a stack backtrace */
	return 0;
}

/* kprobe post_handler: called after the probed instruction is executed */
static void __kprobes handler_post(struct kprobe *p, struct pt_regs *regs,
				   unsigned long flags)
{
	pr_info("<%s> p->addr = 0x%p, pstate = 0x%lx\n",
		p->symbol_name, p->addr, (long)regs->pstate);
}

static int __init kprobe_init(void)
{
	int ret;
	kp.pre_handler = handler_pre;
	kp.post_handler = handler_post;

	ret = register_kprobe(&kp);
	if (ret < 0)
	{
		pr_err("register_kprobe failed, returned %d\n", ret);
		return ret;
	}
	pr_info("Planted kprobe at %s (%p)\n", kp.symbol_name, kp.addr);
	LOOKUP_SYMS(ghes_copy_tofrom_phys);
	return 0;
}

static void __exit kprobe_exit(void)
{
	unregister_kprobe(&kp);
	pr_info("kprobe at %s (%p) unregistered\n", kp.symbol_name, kp.addr);
}

module_init(kprobe_init)
    module_exit(kprobe_exit)
	MODULE_LICENSE("GPL");
