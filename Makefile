install:
	@make --no-print-directory -C lib install

build:
	@make --no-print-directory -C lib build

clean:
	@make --no-print-directory -C lib clean

-include test_core/make.include
