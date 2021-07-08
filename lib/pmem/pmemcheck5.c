#include <valgrind/pmemcheck.h>
#include <libpmem.h>

int main(int argc, char** argv)
{
	int ip;
	VALGRIND_PMC_REGISTER_PMEM_MAPPING(&ip, sizeof (ip));
	ip = 5;
	/* double flush */
	pmem_flush(&ip, sizeof (ip));
	pmem_flush(&ip, sizeof (ip));
	/* nothing to flush */
	pmem_flush((&ip + 1), sizeof (ip));
	VALGRIND_PMC_REMOVE_PMEM_MAPPING(&ip, sizeof (ip));
}
