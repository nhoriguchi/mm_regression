#!/bin/bash
#
# Usage
#   run.sh [global options] <subcommand> [options]
#
# Subcommands
#   build, clean, recipe, prepare, project, version
#
# Global Options
#
#   -s <kernel_source_path>
#   -v                       show version info of this test tool
#   -h                       show this message
#
# Subcommand
#   build:                            build test programs
#   clean:                            remove test programs
#   recipe:                           manage recipe files
#     recipe split                    generate testcases from recipeset (.set3 file)'
#     recipe list                     list all testcases'
#     recipe list -p                  list all testcases (sorted by priority)'
#     recipe clean                    cleanup all generated testcases (.auto3 files)'
#   prepare [opts] <PROJ>             setup new project or update existing project
#   project:                          manage test project
#     project list                    list all projects
#     project set <PROJ>              set current project
#     project show [<PROJ>]           show info about current|given project
#     project run [opts] [<PROJ>]     run current|given project
#     project summary [opts] [<PROJ>] show summary of current|given project
#     project delete [<PROJ>]         delete current|given project
#   version                           show tool version
#   test:                             (deprecated) run test
#
# Environment variables:
#
#   - RUNNAME
#   - RUN_MODE
#   - PRIORITY
#   - SOFT_RETRY
#   - HARD_RETRY
#   - BACKWARD_KEYWORD
#   - FORWARD_KEYWORD
#   - LOGLEVEL
#
# Subcommand options (prepare):
#   -f filter          Filter testcases with keywords.
#
# Subcommand options (run):
#   -a|--again         Rerun all testcase when restarting existing test project.
#   -p|--skip-pass     Skip rerunning passed testcases.
#   -f|--skip-fail     Skip rerunning failed testcases.
#   -w|--skip-warn     Skip rerunning warned testcases.
#   --log-level
#
# Subcommand options (summary):
#   -f|--show-failure  Show all failed checks
#   -p|--progress      Show full list of test status
#   -t|--timesummary   Show spent time of each test case
#
# Runtime config
#   - AGAIN
#   - SKIP_PASS
#   - SKIP_FAIL
#   - SKIP_WARN
#   - ROUND
#
show_help() {
    sed -n 2,$[$BASH_LINENO-4]p $BASH_SOURCE | grep "^#" | sed 's/^#/ /'
	exit 0
}

cd $(dirname $BASH_SOURCE)

while getopts s:vh OPT ; do
	case $OPT in
		s) KERNEL_SRC="$OPTARG" ;;
		v)
			make version
			exit 0
			;;
		h)
			show_help
			;;
	esac
done
shift $[OPTIND-1]

run_test() {
	# export AGAIN=true
	# export BACKGROUND=true
	export TEST_DESCRIPTION=${TEST_DESCRIPTION:="MM regression test"}
	export RUNNAME=${RUNNAME:=debug}
	export SOFT_RETRY=${SOFT_RETRY:=1}
	export HARD_RETRY=${HARD_RETRY:=1}
	export RUN_MODE=${RUN_MODE:=normal}

	export PATH=$PWD/build:$PATH

	make -s build

	if [ "$FAILRETRY" ] && [ "$FAILRETRY" -gt 1 ] ; then
		# TODO: rename ROUND?
		[ ! "$ROUND" ] && export ROUND=1
		BASERUNNAME=$RUNNAME
		export RUNNAME=$BASERUNNAME/$ROUND
		make --no-print-directory prepare
		if [ ! -f  work/$RUNNAME/recipelist ] ; then
			if [ "$ROUND" -gt 1 ] ; then
				ruby test_core/lib/test_summary.rb -C work/$BASERUNNAME/$[ROUND-1] | grep -e ^FAIL -e ^WARN | cut -f4 -d' ' > work/$RUNNAME/recipelist
			else
				if [ -f work/$BASERUNNAME/recipelist ] ; then
					cp work/$BASERUNNAME/recipelist work/$RUNNAME/recipelist
				fi
			fi
			make --no-print-directory prepare
		fi
	fi

	if [ "$1" ] ; then
		export FILTER="$1"
	fi

	bash test_core/run-test.sh
}

prepare_test_project() {
	local proj=$1

	if [ -d "work/$proj" ] ; then
		echo "TODO: gracefully update existing project $proj"
	else
		mkdir -p work/$proj
	fi
	cat <<EOF > work/$proj/config
export RUNNAME=$proj
export RUN_MODE=${RUN_MODE:=normal}
export SOFT_RETRY=${SOFT_RETRY:=1}
export HARD_RETRY=${HARD_RETRY:=1}
export TEST_DESCRIPTION="${TEST_DESCRIPTION:=MM regression test}"
export UNPOISON=${UNPOISON}
export FAILRETRY=${FAILRETRY}
export PRIORITY=${PRIORITY:=0-10}
export BACKWARD_KEYWORD=${BACKWARD_KEYWORD}
export FORWARD_KEYWORD=${FORWARD_KEYWORD}
export LOGLEVEL=${LOGLEVEL:=1}
EOF
	echo "Generated work/$proj/config"
	echo "You can manually edit/update the file to adjust test project."
	. work/$proj/config
	make --no-print-directory prepare
}

run_test_new() {
	local proj=$1
	if [ ! -f "work/$proj/config" ] ; then
		echo "Project config file work/$proj/config not found." >&2
		exit 1
	fi
	. work/$proj/config
	echo "run_test $2 ([$@] ss $SOFT_RETRY $HARD_RETRY)"
	env | grep RUNNAME
	export RUNNAME=$proj
	run_test $2
}

get_project() {
	local proj=
	if [ "$1" ] ; then
		proj="$1"
	elif [ -f .current_project ] ; then
		proj="$(cat .current_project)"
	else
		echo 'No test project set, run "run.sh prepare <PROJ>" or "run.sh project set <PROJ>" first.'
		exit 1
	fi
	echo $proj
}

set_project() {
	if [ "$1" ] ; then
		echo "$1" > .current_project
	fi
}

show_summary() {
	case $1 in
		-f|--show-failure)
			SHOW_FAILURE=-f
			shift 1
			;;
		-p|--progress)
			SHOW_PROGRESS=-p
			shift 1
			;;
		-t|--timesummary)
			SHOW_TIMESUMMARY=-t
			shift 1
			;;
		-h|--help)
			show_help
			;;
		*)
			;;
	esac
	proj="$(get_project $1)"
	if [ ! -d "work/$proj" ] ; then
		echo "No work/$proj found."
		exit 1
	fi
	echo "# [$@, $proj]"
	# TODO: more detail
	echo "ruby test_core/lib/test_summary.rb $SHOW_FAILURE $SHOW_PROGRESS $SHOW_TIMESUMMARY work/$proj"
	ruby test_core/lib/test_summary.rb $SHOW_FAILURE $SHOW_PROGRESS $SHOW_TIMESUMMARY work/$proj
}

case $1 in
	b|bu|bui|buil|build)
		make install
		;;
	c|cl|cle|clea|clean)
		make clean
		;;
	re|rec|reci|recip|recipe)
		shift 1
		case $1 in
			s|sp|spl|spli|split|g|ge|gen|gene|gener|genera|generat|generate)
				make update_recipes
				;;
			c|cl|cle|clea|clean|cleanu|cleanup)
				make cleanup_recipes
				;;
			l|li|lis|list)
				if [ "$2" == "-p" ] ; then
					make recipe_priority
				else
					make allrecipes
				fi
				;;
			*)
				show_help
				;;
		esac
		;;
	pre|prep|prepa|prepar|prepare)
		# Generate work/$RUNNAME/config for control variables.
		# You can update the config by rerunning prepare command.
		case $2 in
			-f|--filter)
				export FILTER="$3"
				shift 2
				;;
			-h|--help)
				show_help
				;;
			*)
				;;
		esac
		proj=$2
		if [ ! "$proj" ] ; then
			echo "No project name given."
			show_help
		fi
		prepare_test_project $proj
		if [ "$proj" ] ; then
			set_project $proj
		fi
		if [ "$FILTER" ] ; then
			echo "Filter testcases with keyword '$FILTER'."
			grep $FILTER work/$proj/full_recipe_list > work/$proj/recipelist
			echo "$(cat work/$proj/recipelist | wc -l) in $(cat work/$proj/full_recipe_list | wc -l) testcases are the target."
			echo "See work/$proj/recipelist."
		fi
		echo "############ NEED IMPROVEMENT ############"
		echo "config files is forcibly overwritten, not expected"
		;;
	pro|proj|proje|projec|project|ru|run|runn|runna|runnam|runname)
		case $2 in
			l|li|lis|list)
				proj=$(get_project)
				if [ -d work ] ; then
					# TODO: better sorting?
					# TODO: mark on current/unfinished project
					ls -1 work
				else
					echo 'No work/ directory. Run "run.sh prepare" first.'
				fi
				;;
			se|'set')
				if [ "$3" ] ; then
					proj=$(get_project $3)
					if [ ! -d "work/$proj" ] ; then
						echo "No work/$proj found."
						exit 1
					fi
					set_project $3
				else
					echo "Need to give project name." >&2
					exit 1
				fi
				;;
			sh|sho|show)
				proj="$(get_project $3)"
				if [ ! -d "work/$proj" ] ; then
					echo "No work/$proj found."
					exit 1
				fi
				totaltc=$(cat work/$proj/full_recipe_list | wc -l)
				if [ -f "work/$proj/recipelist" ] ; then
					targettc=$(cat work/$proj/recipelist | wc -l)
				else
					targettc=$(cat work/$proj/full_recipe_list | wc -l)
				fi
				echo "Project Name: $proj"
				echo "Total testcases: $totaltc"
				echo "Target testcases: $targettc"
				# TODO: list testcase by option?
				;;
			su|sum|summ|summa|summar|summary)
				shift 2
				show_summary $@
				;;
			r|ru|run)
				shift 2
				while true ; do
					case $1 in
						-a|--again)
							export AGAIN=true
							shift 1
							;;
						-p|--skip-pass)
							export SKIP_PASS=true
							shift 1
							;;
						-f|--skip-fail)
							export SKIP_FAIL=true
							shift 1
							;;
						-w|--skip-warn)
							export SKIP_WARN=true
							shift 1
							;;
						-h|--help)
							show_help
							;;
						*)
							break
							;;
					esac
				done

				proj="$(get_project $3)"
				if [ ! -d "work/$proj" ] ; then
					echo "No work/$proj found."
					exit 1
				fi

				echo "run_test_new $proj $4"
				run_test_new $proj $4
				;;
			d|de|del|dele|delet|delete)
				proj="$(get_project $3)"
				if [ ! -d "work/$proj" ] ; then
					echo "No work/$proj found."
					exit 1
				fi
				echo ""
				;;
			*)
				show_help
				;;
		esac
		;;
	test)
		shift
		run_test $@
		;;
	summary)
		shift 1
		show_summary $@
		;;
	v|ve|ver|vers|versi|versio|version)
		make version
		;;
	*)
		echo "no command given"
		show_help
		exit 0
	;;
esac
