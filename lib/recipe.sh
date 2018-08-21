#!/bin/bash

# parse_recipefile <before> <after>
# replace some lines in <before> recipefile, and write into <after> recipefile.
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
                if [ ! "$entry" ] || [[ "$entry" =~ ^# ]] ; then
                    continue
                fi
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
                echo "$others"
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

check_remove_suffix() {
	local recipe=$1

	# Directory is not a recipe.
	if [ -d "$recipe" ] ; then
		return 1
	fi

	if [[ "$recipe" =~ \.auto$ ]] ; then
		if [ -f "${recipe%%.auto}" ] ; then
			echo "Manually made recipe with same recipe ID exists (${recipe%%.auto},) so skip this .auto recipe"
			return 1
		fi
	fi

	if [[ "$recipe" =~ \.devel$ ]] ; then
		echo "$recipe: developing recipe. If you really want to run this testcase, please give environment variable DEVEL=true from calling make. If this recipe is ready to regular running, please remove the suffix."
		[ "$DEVEL_MODE" != true ] && return 1
	fi

	if [[ "$recipe" =~ \.set$ ]] ; then
		echo "$recipe: recipeset recipe. This recipe is not intended to be run directly, so let's skip this. To run split recipe, call make split_recipes first."
		return 1
	fi

	if [[ "$recipe" =~ \.tmp$ ]] ; then
		echo "$recipe: temporary recipe. This recipe is either just in PoC phase, or not completed yet. So let's skip this for now."
		return 1
	fi

	if [[ "$recipe" =~ \.old$ ]] ; then
		echo "$recipe: old (obsolete) recipe. It might not run as intended, so just skip it."
		return 1
	fi

	if [[ "$recipe" =~ \.sh$ ]] ; then
		echo "$recipe: .sh file maybe is an helper/routine file, not a recipe file. So just skip it."
		return 1
	fi

	return 0
}
