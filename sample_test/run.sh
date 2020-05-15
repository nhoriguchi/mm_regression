export RUNNAME=debug
export AGAIN=true

make all
make prepare
[ ! "$RECIPEFILES" ] && export RECIPEFILES="$(make allrecipes)"
make test
ruby test_core/lib/test_summary.rb -v -P work/$RUNNAME
