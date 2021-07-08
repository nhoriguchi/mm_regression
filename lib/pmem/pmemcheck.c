#include <valgrind/pmemcheck.h>

int main(int argc, char** argv)
{
	int ip;
	VALGRIND_PMC_REGISTER_PMEM_MAPPING(&ip, sizeof (ip));
	ip = 5;
	VALGRIND_PMC_REMOVE_PMEM_MAPPING(&ip, sizeof (ip));
}
