CC=gcc
OPT=-DDEBUG
LIBOPT=-lnuma -lpthread # -lcgroup -lpmem
CFLAGS=-g # -Wall -Wextra

SRC = $(shell find * -type f -name "*.c" -print)
DST1 = $(patsubst %.c,%,$(SRC))
DST2 = $(patsubst %,$(DSTDIR)/%,$(notdir $(DST1)))
DSTDIR = ../build

VPATH = ../cailtest

install: build $(DST2)

build: cailtest $(DST1)

cailtest:
	make -C cailtest

$(DSTDIR)/random: cailtest/random
	install $< $@

$(DSTDIR)/%: %
	install $< $@

%: %.c
	C_INCLUDE_PATH=.. $(CC) $(CFLAGS) -o $@ $< $(OPT) $(LIBOPT)

clean:
	rm $(DST1) $(DST2)
