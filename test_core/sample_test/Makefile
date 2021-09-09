build:
	@make --no-print-directory -C lib build

clean:
	@make --no-print-directory -C lib clean

test: build
	@bash test_core/run-test.sh

list:
	@bash test_core/display_testcases.sh -a

-include test_core/make.include
