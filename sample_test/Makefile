TESTCASE_FILTER=
# TODO: some default values

build:
	make --no-print-directory -C lib build

all: get_test_core build

get_test_core:
	@test ! -d "test_core" && test -f install.sh && bash install.sh || true
	@test -d "test_core" || git clone https://github.com/Naoya-Horiguchi/test_core
	@true

test: all
	@bash test_core/run-test.sh $(addprefix -f ,$(TESTCASE_FILTER)) $(addprefix -r ,$(shell readlink -f $(RECIPES) 2> /dev/null)) $(addprefix -t ,$(RUNNAME)) $(addprefix -d ,$(RECIPEDIR))

list: get_test_core
	@bash test_core/display_testcases.sh -a

-include test_core/make.include
