#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <linux/mempolicy.h>
#include <numaif.h>

int main(void)
{
        unsigned long nodemask = 4;
        void *addr;

        addr = mmap((void *)0x20000000UL, 2UL << 20, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANONYMOUS | MAP_LOCKED, -1, 0);

        if (fork()) {
                wait(NULL);
                return 0;
        }

        mlock(addr, 4UL << 10);
        mbind(addr, 2UL << 20, MPOL_PREFERRED | MPOL_F_RELATIVE_NODES,
                &nodemask, 4, MPOL_MF_MOVE);

        return 0;
}
