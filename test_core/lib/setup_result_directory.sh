RUNNAME=$1

if [ ! "$RUNNAME" ] ; then
	echo "No RUNNAME is given, abort." >&2
	exit 1
fi

# need parse_recipefile
. $(dirname $BASH_SOURCE)/recipe.sh

mkdir -p work/$RUNNAME
make --no-print-directory allrecipes > work/$RUNNAME/full_recipe_list
