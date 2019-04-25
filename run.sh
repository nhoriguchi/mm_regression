# $run_class can be set from environment variable
# $LOGLEVEL can be set from environment variable
# $RECIPEFILES can be set from environment variable
while getopts r:l: OPT ; do
    case $OPT in
		r) RECIPEFILES="$RECIPEFILES $OPTARG" ;;
		l) LOWEST_PRIORITY=$OPTARG ;;
    esac
done
shift $[OPTIND-1]

[ ! "$run_class" ] && run_class=$1

rm test_alloc_generic 2> /dev/null
export RUNNAME=$(uname -r)

make all
make prepare
make update_recipes

[ ! "$UNPOISON" ] && UNPOISON=true

if [ "$run_class" == mce-srao ] ; then
	export RECIPEFILES="$(make allrecipes | grep mce-srao)"
elif [ "$run_class" == kvm ] ; then
	export RECIPEFILES="$(make allrecipes | grep kvm)"
elif [ "$run_class" == race ] ; then
	export UNPOISON=false
	export RECIPEFILES="$(make allrecipes | grep race)"
elif [ "$run_class" == simple ] ; then
	export RECIPEFILES="$(make allrecipes | grep -v -e mce-srao -e kvm -e race)"
elif [ "$run_class" == failed ] ; then
	export AGAIN=true
	export RECIPEFILES="$(ruby test_core/lib/test_summary.rb -C work/$RUNNAME | grep -e FAIL -e WARN | cut -f4 -d' ')"
elif [ ! "$RECIPEFILES" ] ; then
	export RECIPEFILES="$(make allrecipes | grep -v mce-srao)"
fi

[ ! "$AGAIN" ] && export AGAIN=true
[ ! "$SOFT_RETRY" ] && export SOFT_RETRY=3
[ ! "$HARD_RETRY" ] && export HARD_RETRY=1
export LOGLEVEL=2
[ ! "$HIGHEST_PRIORITY" ] && export HIGHEST_PRIORITY=10
[ ! "$LOWEST_PRIORITY" ] && export LOWEST_PRIORITY=15
make test
ruby test_core/lib/test_summary.rb -v -C work/$RUNNAME | grep -v -e PASS -e NONE -e SKIP
