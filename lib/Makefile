CC=gcc
OPT=-DDEBUG
LIBOPT=-lnuma -lpthread # -lcgroup -lpmem
CFLAGS=-g # -Wall -Wextra

SRC = $(shell find . -maxdepth 1 -type f -name "*.c")
DST = $(patsubst %.c,%,$(SRC))

build: $(DST)

all: $(DST)

%: %.c
	C_INCLUDE_PATH=.. $(CC) $(CFLAGS) -o $@ $< $(OPT) $(LIBOPT)
	install $@ ../build

clean:
	rm $(DST)
