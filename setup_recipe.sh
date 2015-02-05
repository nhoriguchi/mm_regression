#!/bin/bash

parse_recipefile() {
    while read line ; do
        if [[ "$line" =~ ^#!EMBED: ]] ; then
            local file=$(echo $line | cut -f2- -d:)
            echo "TEST_TITLE='$(basename $file)'"
            cat $file
            if grep ^TEST_PROGRAM= $file > /dev/null ; then
                echo "do_test_sync"
            else
                echo "do_test_async"
            fi
        else
            echo "$line"
        fi
    done < $1 > $2
}
