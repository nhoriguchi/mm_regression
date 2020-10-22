#!/bin/bash

FILE=$1
[ ! -s "$FILE" ] && exit 1

OPT=
if grep -q "^#include <libpmem.h>" $FILE ; then
   OPT="$OPT -lpmem"
fi
if grep -q "^#include <keyutils.h>" $FILE ; then
   OPT="$OPT -lkeyutils"
fi
if grep -q "^#include <pthread.h>" $FILE ; then
   OPT="$OPT -lpthread"
fi
if grep -q "^#include <numa.h>" $FILE ; then
   OPT="$OPT -lnuma"
fi

echo $OPT
