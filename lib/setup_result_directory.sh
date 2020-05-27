RUNNAME=$1

if [ ! "$RUNNAME" ] ; then
	echo "No RUNNAME is given, abort." >&2
	exit 1
fi

# need parse_recipefile
. $(dirname $BASH_SOURCE)/recipe.sh

full_recipe=work/$RUNNAME/full_recipe_list

mkdir -p work/$RUNNAME
make --no-print-directory allrecipes | grep ^cases > work/$RUNNAME/full_recipe_list

# disable recipe modification for a while
exit

for existing in $(find work/$RUNNAME -name '_recipe') ; do
	existing_tc=$(dirname $existing | cut -f3- -d/)
	if ! grep -qx cases/$existing_tc $full_recipe ; then
		echo "### obsolete testcase $existing_tc"
		if [ "$REMOVE_OBSOLETE_TEST_RESULTS" ] ; then
			rm -rf $(dirname $existing)
		else
			echo "### set environment variable REMOVE_OBSOLETE_TEST_RESULTS if you want to remove result direcotries of obsolete testcases"
		fi
	fi
done

for rc in $(cat $full_recipe | cut -f2- -d/) ; do
	if [ ! -d work/$RUNNAME/$rc ] ; then
		mkdir -p work/$RUNNAME/$rc
		parse_recipefile cases/$rc work/$RUNNAME/$rc/_recipe
	fi
done
