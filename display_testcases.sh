#!/bin/bash

# input recipe
# output summarized testcase

SDIR=$(readlink -f $(dirname $BASH_SOURCE))
RECIPEFILE=$(readlink -f $1)

[ ! -e "$RECIPEFILE" ] && echo "No recipefile specified/exists." && exit 1

tbasedir=/tmp/$(basename $BASH_SOURCE)
 [ ! -d $tbasedir ] && mkdir -p $tbasedir
TMPF=$(mktemp --tmpdir=$tbasedir -d XXXXXX)

. $SDIR/setup_test_core.sh
. $SDIR/setup_recipe.sh

show_item() {
    local sym=$1
    local default=$2
    local target=$sym
    if [ ! "$(eval echo "\$"$sym)" ] ; then
        # echo $sym is empty
        if [ "$default" ] ; then
            target=$default
        else
            echo "" >> $TMPF/$sym
            return
        fi
    fi
    eval echo "\$"$target >> $TMPF/$sym
}

pushd $(dirname $RECIPEFILE) > /dev/null
parse_recipefile $RECIPEFILE $TMPF/recipe
while read line ; do
    [ ! "$line" ] && continue
    [[ $line =~ ^# ]] && continue

    if [ "$line" = do_test_sync ] || [ "$line" = do_test_async ] ; then
        show_item TEST_TITLE
        show_item TEST_PROGRAM
        show_item EXPECTED_RETURN_CODE
        show_item TEST_PREPARE DEFAULT_TEST_PREPARE
        show_item TEST_CLEANUP DEFAULT_TEST_CLEANUP
        show_item TEST_CONTROLLER DEFAULT_TEST_CONTROLLER
        show_item TEST_CHECKER DEFAULT_TEST_CHECKER
        show_item TEST_FLAGS
        show_item TEST_RETRYABLE
    else
        if [[ "$line" =~ '=' ]] ; then
            eval $line
        fi
    fi
done < $TMPF/recipe
popd > /dev/null

printf "%-30s %-30s %-30s %-30s %-30s\n" Title Prepare Cleanup Control Check
paste $TMPF/TEST_TITLE $TMPF/TEST_PREPARE $TMPF/TEST_CLEANUP $TMPF/TEST_CONTROLLER $TMPF/TEST_CHECKER | while read title prepare cleanup controller checker ; do
    printf "%-30s %-30s %-30s %-30s %-30s\n" $title ${prepare#prepare_} ${cleanup#cleanup_} ${controller#control_} ${checker#check_}
done
