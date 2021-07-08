CC=gcc
CFLAGS=-g
# TODO: ファイルごとに必要十分なライブラリを与えられないといけない。
OPT=-lpmem -lpmemkv -lpmemobj

SRC = $(shell find ./ -maxdepth 1 -type f -name "*.c" -print | grep -v /tmp_ | sort)
DST1 = $(patsubst %.c,%,$(SRC))

build: $(DST1)

%: %.c
	# C_INCLUDE_PATH=/usr/local/include $(CC) -I /usr/local/include -o $@ $< $(OPT) $(CFLAGS)
	$(CC) $(CFLAGS) -I/usr/local/include -o $@ $< $(OPT)

clean:
	rm $(DST1)

list:
	echo $(SRC)
	echo $(DST1)
