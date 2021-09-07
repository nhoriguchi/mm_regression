TESTCASE_FILTER=
# TODO: some default values

build:
	@make --no-print-directory -C lib build

all: build

test: all
	@bash test_core/run-test.sh

list: get_test_core
	@bash test_core/display_testcases.sh -a

-include test_core/make.include
