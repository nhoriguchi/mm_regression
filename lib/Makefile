CC=gcc
OPT=-DDEBUG
LIBOPT=-lnuma -lpthread # -lcgroup -lpmem
CFLAGS=-g # -Wall -Wextra

SRC = $(shell find . -maxdepth 1 -type f -name "*.c")
DST = $(patsubst %.c,%,$(SRC))
DST2 = $(patsubst %.c,../build/%,$(SRC))

install: build $(DST2)

../build/%: %
	install $< $@

build: $(DST)

%: %.c
	C_INCLUDE_PATH=.. $(CC) $(CFLAGS) -o $@ $< $(OPT) $(LIBOPT)

clean:
	rm $(DST) $(DST2)
