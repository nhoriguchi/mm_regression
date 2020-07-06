TMPF=$(mktemp)
cat - > $TMPF

THISDIR=$(dirname $BASH_SOURCE)
. $THISDIR/recipe.sh

for recipe in $(cat $TMPF) ; do
	if check_remove_suffix $recipe > /dev/null ; then
		# priority="$(. $recipe ; echo $PRIORITY)"
		priority="$(grep TEST_PRIORITY= $recipe | cut -f2 -d= | cut -f1 -d' ')"
		[ ! "$priority" ] && priority=10
		printf "$recipe\t$priority\n"
	fi
done
