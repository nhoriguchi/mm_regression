CC=gcc
OPT=-DDEBUG
CFLAGS=-g # -Wall -Wextra

SRC1 = $(shell find ./ -maxdepth 1 -type f -name "*.c" -print | grep -v /tmp_ | grep -v dax)
SRC_PMEM = $(shell find ./ -maxdepth 1 -type f -name "*.c" -print | grep -v /tmp_ | grep dax)
DST1 = $(patsubst %.c,%,$(SRC1))
DST2 = $(patsubst %,$(DSTDIR)/%,$(notdir $(DST1)))
DSTDIR = ../build

install: build $(DST2)

build: $(DST1)
ifneq ($(PMEMDEV),)
	make -C pmem
endif


$(DSTDIR)/random: cailtest/random
	install $< $@ || true

$(DSTDIR)/%: %
	install $< $@ || true

%: %.c
	C_INCLUDE_PATH=.. $(CC) $(CFLAGS) -o $@ $(OPT) $(shell bash get_link_options.sh $<) $< || true

list:
	@echo "SRC1: $(SRC1)"
	@echo "SRC_PMEM: $(SRC_PMEM)"
	@echo "DST1: $(DST1)"
	@echo "DST2: $(DST2)"

clean:
	rm $(DST1) $(DST2)
