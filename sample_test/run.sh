export RUNNAME=debug
export AGAIN=true
export RECIPEFILES="$(make allrecipes)"

make update_recipes
make test
ruby test_core/lib/test_summary.rb -v -C work/$RUNNAME
