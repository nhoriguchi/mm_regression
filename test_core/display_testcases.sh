#!/bin/bash

# input recipe
# output summarized testcase

WIDTH=30
MODE=html
ALLRECIPES=
OUTFILE=
while getopts w:htao: OPT
do
    case $OPT in
        w) WIDTH=$OPTARG ;;
        h) MODE=html ;;
        t) MODE=text ;;
        a) ALLRECIPES=true ;;
        o) OUTFILE=$OPTARG ;;
        *) echo "invalid option" && exit 1 ;;
    esac
done
shift $[OPTIND - 1]

SDIR=$(readlink -f $(dirname $BASH_SOURCE))

tbasedir=/tmp/$(basename $BASH_SOURCE)
 [ ! -d $tbasedir ] && mkdir -p $tbasedir
TMPF=$(mktemp --tmpdir=$tbasedir -d XXXXXX)

. $SDIR/setup_test_core.sh
. $SDIR/lib/recipe.sh

reset_per_testcase_counters() { true ; } # dummy

show_header() {
    echo "<table border=1>"
    echo "<tr>"
    echo "<td>TEST_TITLE</td>"
    echo "<td>TEST_PROGRAM</td>"
    echo "<td>TEST_TYPE</td>"
    echo "<td>TEST_RETRYABLE</td>"
    echo "<td>EXPECTED_RETURN_CODE</td>"
    echo "<td>TEST_PREPARE</td>"
    echo "<td>TEST_CLEANUP</td>"
    echo "<td>TEST_CONTROLLER</td>"
    echo "<td>TEST_CHECKER</td>"
    echo "<td>FIXEDBY_SUBJECT</td>"
    echo "<td>FIXEDBY_COMMITID</td>"
    echo "<td>FIXEDBY_AUTHOR</td>"
    echo "<td>FIXEDBY_PATCH_SEARCH_DATE</td>"
    echo "<td>FALSENEGATIVE</td>"
    echo "</tr>"
}

show_footer() {
    echo "</table>"
}

show_recipe_header() {
    echo "<tr><td>$@</td></tr>"
}

show_row() {
    echo "<tr>"
    echo "<td>$TEST_TITLE</td>"
    echo "<td>$TEST_PROGRAM</td>"
    echo "<td>$TEST_TYPE</td>"
    echo "<td>$TEST_RETRYABLE</td>"
    echo "<td>$EXPECTED_RETURN_CODE</td>"
    echo "<td>${TEST_PREPARE:=$TEST_PREPARE DEFAULT}</td>"
    echo "<td>${TEST_CLEANUP:=$TEST_CLEANUP DEFAULT}</td>"
    echo "<td>${TEST_CONTROLLER:=$TEST_CONTROLLER DEFAULT}</td>"
    echo "<td>${TEST_CHECKER:=$TEST_CHECKER DEFAULT}</td>"
    echo "<td>$(echo $FIXEDBY_SUBJECT | tr '|' '\n')</td>"
    echo "<td>$FIXEDBY_COMMITID</td>"
    echo "<td>$FIXEDBY_AUTHOR</td>"
    echo "<td>$FIXEDBY_PATCH_SEARCH_DATE</td>"
    echo "<td>$FALSENEGATIVE</td>"
    echo "</tr>"
}

RECIPES="$@"

if [ "$ALLRECIPES" = true ] ; then
    RECIPES="$(ls -1 | grep \.rc$ )"
fi

[ ! "$RECIPES" ] && echo "No recipe given" >&2 && exit 1

[ ! "$OUTFILE" ] && OUTFILE=$TMPF/index.html

show_header > $OUTFILE
for recipe in $RECIPES ; do
    recipefile=$(readlink -f $recipe)
    [ ! -e "$recipefile" ] && echo "$recipefile not found, skipped." >&2 && continue

    pushd $(dirname $recipefile) > /dev/null
    parse_recipefile $recipefile $TMPF/recipe
    # less $TMPF/recipe
    show_recipe_header "$(basename $recipefile)" >> $OUTFILE
    while read line ; do
        [ ! "$line" ] && continue
        [[ $line =~ ^# ]] && continue

        if [ "$line" = do_test_sync ] || [ "$line" = do_test_async ] ; then
            show_row >> $OUTFILE
            clear_testcase
        else
            if [[ "$line" =~ '=' ]] ; then
                if [[ "$line" =~ TEST_PROGRAM ]] ; then
                    # need to print reference like $var as it is
                    eval $(echo $"$line" | sed -e 's/\$/\\$/')
                else
                    eval $line
                fi
            fi
        fi
    done < $TMPF/recipe
    popd > /dev/null
done
show_footer >> $OUTFILE

firefox $OUTFILE

if [ "$MODE" = text ] ; then
    printf "%-${WIDTH}s %-${WIDTH}s %-${WIDTH}s %-${WIDTH}s %-${WIDTH}s\n" Title Prepare Cleanup Control Check
    paste $TMPF/TEST_TITLE $TMPF/TEST_PREPARE $TMPF/TEST_CLEANUP $TMPF/TEST_CONTROLLER $TMPF/TEST_CHECKER | while read title prepare cleanup controller checker ; do
        printf "%-${WIDTH}s %-${WIDTH}s %-${WIDTH}s %-${WIDTH}s %-${WIDTH}s\n" $title ${prepare#prepare_} ${cleanup#cleanup_} ${controller#control_} ${checker#check_}
    done
fi
