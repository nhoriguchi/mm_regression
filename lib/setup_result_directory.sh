RUNNAME=$1

# need parse_recipefile
. $(dirname $BASH_SOURCE)/recipe.sh

TMPD=$(mktemp)
make allrecipes > $TMPD
for existing in $(find work/$RUNNAME -name '_recipe') ; do
	existing_tc=$(dirname $existing | cut -f3- -d/)
	if ! grep -qx cases/$existing_tc $TMPD ; then
		echo "### obsolete testcase $existing_tc"
	fi
done

for rc in $(make allrecipes | cut -f2- -d/) ; do
	echo "---> $rc"
	if [ ! -d work/$RUNNAME/$rc ] ; then
		mkdir -p work/$RUNNAME/$rc
		parse_recipefile cases/$rc work/$RUNNAME/$rc/_recipe
	fi
done
