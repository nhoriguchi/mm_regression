SHELL=/bin/bash
CC=gcc
CFLAGS=-g # -Wall -Wextra
TESTCASE_FILTER=
TC=

src=test_sample.c
exe=$(src:.c=)
srcdir=.
dstdir=/usr/local/bin
dstexe=$(addprefix $(dstdir)/,$(exe))

OPT=-DDEBUG
LIBOPT= #-lnuma # -lcgroup

all: get_test_core $(exe)
%: %.c
	$(CC) $(CFLAGS) -o $@ $^ $(OPT) $(LIBOPT)

get_test_core:
	@test ! -d "test_core" && test -f install.sh && bash install.sh || true
	@test -d "test_core" || git clone https://github.com/Naoya-Horiguchi/test_core
	@true

install: $(exe)
	for file in $? ; do \
	  mv $$file $(dstdir) ; \
	done

clean:
	@for file in $(exe) ; do \
	  rm $(dstdir)/$$file 2> /dev/null ; \
	  rm $(srcdir)/$$file 2> /dev/null ; \
	  true ; \
	done

test: all
	TESTCASE_FILTER="$(TC)"
	@bash run-test.sh -v -r sample.rc $(TESTCASE_FILTER)

list: get_test_core
	@bash test_core/display_testcases.sh -a
