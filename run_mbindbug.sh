#!/bin/bash

make
pkill -9 -f mbind_bug_reproducer
while true ; do
    dd if=/dev/urandom of=testfile bs=4096 count=1000
    for i in $(seq 10) ; do
        ./mbind_bug_reproducer testfile > /dev/null &
    done
    sleep 3
    pkill -9 -f mbind_bug_reproducer
done
