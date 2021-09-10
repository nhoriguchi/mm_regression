CC=gcc
OPT=-DDEBUG
CFLAGS=-g # -Wall -Wextra

SRC = $(shell find ./ -maxdepth 1 -type f -name "*.c" -print | grep -v /tmp_)
DST1 = $(patsubst %.c,%,$(SRC))
DST2 = $(patsubst %,$(DSTDIR)/%,$(notdir $(DST1)))
DSTDIR = ../build

install: build $(DST2)

build: $(DST1)
	make -C pmem

$(DSTDIR)/random: cailtest/random
	install $< $@ || true

$(DSTDIR)/%: %
	install $< $@ || true

%: %.c
	C_INCLUDE_PATH=.. $(CC) $(CFLAGS) -o $@ $< $(OPT) $(shell bash get_link_options.sh $<) || true

list:
	@echo "SRC: $(SRC)"
	@echo "SRC2: $(SRC2)"
	@echo "DST1: $(DST1)"
	@echo "DST2: $(DST2)"

clean:
	rm $(DST1) $(DST2)
