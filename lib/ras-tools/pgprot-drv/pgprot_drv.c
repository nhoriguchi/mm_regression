/*
 * Copyright (C) 2022 Alibaba Corporation
 * Author: Shuai Xue
 *
 * This software may be redistributed and/or modified under the terms of
 * the GNU General Public License ("GPL") version 2 only as published by the
 * Free Software Foundation.
 */

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/miscdevice.h>
#include <linux/pagewalk.h>
#include <asm/memory.h>

typedef struct
{
	int num;
	/*
	 * Any unaligned access to memory region with any Device memory type
	 * attribute generates an Alignment fault. Thus, add a safe padding.
	 */
	char pad[3];
	long long int paddr;
} mpgprot_drv_ctx;

#define DEV_NAME "pgprot_drv"
static mpgprot_drv_ctx *sh_mem = NULL;
#define SHARE_MEM_SIZE (PAGE_SIZE * 2)

static int pgprot = 0;
module_param(pgprot, int, 0644);
MODULE_PARM_DESC(pgprot, "Get an value from user...\n");

void dump_pte(const struct mm_struct *const mm,
	      const unsigned long addr)
{
	pgd_t *pgdp, pgd;
	p4d_t *p4dp, p4d;
	pud_t *pudp, pud;
	pmd_t *pmdp, pmd;
	pte_t *ptep, pte;

	pgdp = pgd_offset(mm, addr);
	pgd = READ_ONCE(*pgdp);
	printk("[%016lx] pgd=%016llx", addr, pgd_val(pgd));

	if (pgd_none(pgd) || pgd_bad(pgd))
		return;

	p4dp = p4d_offset(pgdp, addr);
	p4d = READ_ONCE(*p4dp);
	printk(", p4d=%016llx", p4d_val(p4d));
	if (p4d_none(p4d) || p4d_bad(p4d))
		return;

	pudp = pud_offset(p4dp, addr);
	pud = READ_ONCE(*pudp);
	printk(", pud=%016llx", pud_val(pud));
	if (pud_none(pud) || pud_bad(pud))
		return;

	pmdp = pmd_offset(pudp, addr);
	pmd = READ_ONCE(*pmdp);
	printk(", pmd=%016llx", pmd_val(pmd));
	if (pmd_none(pmd) || pmd_bad(pmd))
		return;

	ptep = pte_offset_map(pmdp, addr);
	pte = READ_ONCE(*ptep);
	printk(", pte=%016llx\n", pte_val(pte));
	if (pte_present(*ptep))
		printk(", pte present\n");
	pte_unmap(ptep);
}

static int pgprot_drv_mmap(struct file *filp, struct vm_area_struct *vma)
{
	int ret;
	uint64_t pfn;
	struct page *page = NULL;
	unsigned long size = (unsigned long)(vma->vm_end - vma->vm_start);

	if (size > SHARE_MEM_SIZE)
	{
		ret = -EINVAL;
		goto err;
	}

	sh_mem = (void *)__get_free_pages(GFP_KERNEL, 1);
	if (!sh_mem)
	{
		printk("kmalloc error\n");
		goto err;
	}
	
	pfn = virt_to_pfn(sh_mem);
	printk("kmalloc pfn: %llx\n", pfn);

	sh_mem->num = 56;
	sh_mem->paddr = pfn << PAGE_SHIFT;
	
	printk("vma->vm_start = %lx", vma->vm_start);
	switch (pgprot)
	{
	case MT_NORMAL:
		/* pgprot is MT_NORMAL by default */
		printk("Memory Atrr: MT_NORMAL\n");
		break;
	case MT_NORMAL_TAGGED:
		vma->vm_page_prot = pgprot_tagged(vma->vm_page_prot);
		printk("Memory Atrr: MT_NORMAL_TAGGED\n");
		break;
	case MT_NORMAL_NC:
		vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
		printk("Memory Atrr: MT_NORMAL_NC\n");
		break;
	case MT_DEVICE_nGnRnE:
		vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
		printk("Memory Atrr: MT_DEVICE_nGnRnE\n");
		break;
	case MT_DEVICE_nGnRE:
		vma->vm_page_prot = pgprot_device(vma->vm_page_prot);
		printk("Memory Atrr: MT_DEVICE_nGnRE\n");
		break;
	default:
		/* MT_NORMAL */
		printk("Memory Atrr: MT_NORMAL\n");
		break;
	}
	page = virt_to_page((unsigned long)sh_mem);
	ret = remap_pfn_range(vma, vma->vm_start, page_to_pfn(page), size, vma->vm_page_prot);
	if (ret)
	{
		goto err;
	}

	dump_pte(current->mm, vma->vm_start);

	return 0;

err:
	return ret;
}

static struct file_operations pgprot_drv_fops =
    {
	.owner = THIS_MODULE,
	.mmap = pgprot_drv_mmap,
};

static struct miscdevice pgprot_drv_dev =
    {
	.minor = MISC_DYNAMIC_MINOR,
	.name = DEV_NAME,
	.fops = &pgprot_drv_fops,
};

static int pgprot_drv_init(void)
{
	int ret;

	ret = misc_register(&pgprot_drv_dev);
	if (ret)
	{
		printk("register misc device error\n");
		return ret;
	}

	printk("register misc ok\n");

	return 0;
}

static void pgprot_drv_exit(void)
{
	misc_deregister(&pgprot_drv_dev);
	free_pages((unsigned long)sh_mem, 1);
}

module_init(pgprot_drv_init);
module_exit(pgprot_drv_exit);

MODULE_LICENSE("GPL v2");
