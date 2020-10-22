CC=gcc
OPT=-DDEBUG
CFLAGS=-g # -Wall -Wextra

SRC = $(shell find * -type f -name "*.c" -print | grep -v ^tmp_)
DST1 = $(patsubst %.c,%,$(SRC))
DST2 = $(patsubst %,$(DSTDIR)/%,$(notdir $(DST1)))
DSTDIR = ../build

VPATH = ../cailtest

install: build $(DST2)

build: cailtest $(DST1)

cailtest:
	make -C cailtest

$(DSTDIR)/random: cailtest/random
	install $< $@ || true

$(DSTDIR)/%: %
	install $< $@ || true

%: %.c
	C_INCLUDE_PATH=.. $(CC) $(CFLAGS) -o $@ $< $(OPT) $(shell bash get_link_options.sh $<) || true

clean:
	rm $(DST1) $(DST2)
