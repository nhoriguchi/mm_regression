CC=gcc
OPT=-DDEBUG
LIBOPT= #-lnuma # -lcgroup
CFLAGS=-g # -Wall -Wextra

src=test_sample.c test_sample_for_both_mode.c
exe=$(src:.c=)

build: $(exe)

%: %.c
	C_INCLUDE_PATH=.. $(CC) $(CFLAGS) -o $@ $^ $(OPT) $(LIBOPT)
