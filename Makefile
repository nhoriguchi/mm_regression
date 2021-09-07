TESTCASE_FILTER=

all: update_test_core install

update_test_core:
	@git submodule update --init test_core

install:
	@make --no-print-directory -C lib install

build:
	@make --no-print-directory -C lib build

clean:
	@make --no-print-directory -C lib clean

get_test_core:
	@test ! -d "test_core" && test -f install.sh && bash install.sh || true
	@test -d "test_core" || git clone https://github.com/Naoya-Horiguchi/test_core
	@true

test:
	@bash test_core/run-test.sh

list: get_test_core
	@bash test_core/display_testcases.sh -a

-include test_core/make.include
