#include <linux/module.h>
#include <linux/kernel.h>

int init_module(void)
{
	u64 cap;

	rdmsrl(MSR_IA32_MCG_CAP, cap);

	printk(KERN_INFO "cr0=0x%16.16lx\n", read_cr0());
	printk(KERN_INFO "cr2=0x%16.16lx\n", read_cr2());
	printk(KERN_INFO "cr3=0x%16.16lx\n", read_cr3());
	printk(KERN_INFO "mcgcap=0x%16.16lx\n", cap);
	return 0;
}

void cleanup_module(void)
{
}
