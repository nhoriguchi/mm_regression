#!/bin/bash

parse_recipefile() {
    local file=
    while read line ; do
        if [[ "$line" =~ ^#!EMBED: ]] ; then
            file=$(echo $line | cut -f2- -d:)
            echo "TEST_TITLE='$(basename $file)'"
            cat $file
            if grep ^TEST_PROGRAM= $file > /dev/null ; then
                echo "do_test_sync"
            else
                echo "do_test_async"
            fi
        elif [[ "$line" =~ ^#!TABLE: ]] ; then
            file=$(echo $line | cut -f2- -d:)
            cat $file | while read entry ; do
                local title="$(echo "$entry"   | cut -f1 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local prepare="$(echo "$entry" | cut -f2 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local cleanup="$(echo "$entry" | cut -f3 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local control="$(echo "$entry" | cut -f4 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local check="$(echo "$entry"   | cut -f5 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local flags="$(echo "$entry"   | cut -f6 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local retry="$(echo "$entry"   | cut -f7 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local program="$(echo "$entry" | cut -f8 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local retcode="$(echo "$entry" | cut -f9 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                local others="$(echo "$entry" | cut -f10 -d'|' | sed -e 's/^ *//' -e 's/ *$//')"
                echo "TEST_TITLE=\"$title\""
                echo "TEST_PREPARE=\"$prepare\""
                echo "TEST_CLEANUP=\"$cleanup\""
                echo "TEST_CONTROLLER=\"$control\""
                echo "TEST_CHECKER=\"$check\""
                echo "TEST_FLAGS=\"$flags\""
                echo "TEST_RETRYABLE=\"$retry\""
                echo "EXPECTED_RETURN_CODE=\"$retcode\""
                echo "TEST_PROGRAM=\"$program\""
                echo "TEST_RETRYABLE=\"$retry\""
                if [ "$program" ] ; then
                    echo "do_test_sync"
                else
                    echo "do_test_async"
                fi
             done
        else
            echo "$line"
        fi
    done < $1 > $2
}
