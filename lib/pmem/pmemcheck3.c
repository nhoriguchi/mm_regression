#include <valgrind/pmemcheck.h>
#include <libpmem.h>

int main(int argc, char** argv)
{
	int ip;
	VALGRIND_PMC_REGISTER_PMEM_MAPPING(&ip, sizeof (ip));
	ip = 5;
	pmem_persist(&ip, sizeof (ip));
	VALGRIND_PMC_REMOVE_PMEM_MAPPING(&ip, sizeof (ip));
}
