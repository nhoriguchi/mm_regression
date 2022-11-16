# show_result.sh simply shows raw output from test result directory
# of a given testcase in a given test project.
#
# Usage:
#   show_result.sh [options] testcase [...]
#
# Options:
#   -p project
show_help() {
	sed -n 2,$[$BASH_LINENO-4]p $BASH_SOURCE | grep "^#" | sed 's/^#/ /'
	exit 0
}

PROJECT=
while getopts p:h OPT ; do
	case $OPT in
		p) PROJECT="$OPTARG" ;;
		h)
			show_help
			;;
	esac
done
shift $[OPTIND-1]

get_project() {
	local proj=
	if [ "$1" ] ; then
		proj="$1"
	elif [ -f .current_project ] ; then
		proj="$(cat .current_project)"
	else
		echo 'No test project set, run "run.sh prepare <PROJ>" or "run.sh project set <PROJ>" first.' >&2
		exit 1
	fi
	proj=${proj##work/}
	proj=${proj%%/}
	if [ ! -d "work/$proj" ] ; then
		echo "Working directory work/$proj not found.  Maybe invalid project name?" >&2
		exit 1
	fi
	echo $proj
}

PROJECT="$(get_project $PROJECT)"

echo "project: $PROJECT"
echo "testcases: $@"
for arg in $@ ; do
	resfile="$(find work/$PROJECT -name result | grep $arg | sort | tail -n1)"
	if [ -s "$resfile" ] ; then
		echo "##### $arg $resfile"
		cat $resfile
		echo
	fi
done

