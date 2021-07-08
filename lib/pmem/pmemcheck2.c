#include <valgrind/pmemcheck.h>

int main(int argc, char** argv)
{
	int ip;
	VALGRIND_PMC_REGISTER_PMEM_MAPPING(&ip, sizeof (ip));
	ip = 5;
	/* tell valgrind these flushing steps occurred */
	VALGRIND_PMC_DO_FLUSH(&ip, sizeof (ip));
	VALGRIND_PMC_DO_FENCE;
	/* VALGRIND_PMC_DO_COMMIT; */
	/* VALGRIND_PMC_DO_FENCE; */
	VALGRIND_PMC_REMOVE_PMEM_MAPPING(&ip, sizeof (ip));
}
