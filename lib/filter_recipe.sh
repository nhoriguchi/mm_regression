TMPF=$(mktemp) 
cat - > $TMPF  

THISDIR=$(dirname $BASH_SOURCE)
. $THISDIR/recipe.sh

for recipe in $(cat $TMPF) ; do
	if check_remove_suffix $recipe > /dev/null ; then
		echo $recipe
	fi
done
