cat <<EOF > /tmp/subprojects
huge_zero huge_zero
1gb_hugetlb 1GB
mce mce/einj mce/uc/sr
kvm /kvm/
pmem cases/pmem
normal
EOF

run_order="
1gb_hugetlb
normal
mce
pmem
kvm
huge_zero
"

# Usage
#   ./run_full.sh <project_basename> [prepare|run|show|summary]
#
# TODO:
#   - change config setting for each subproject
#
# Environment variable
#   - VM
#   - PMEMDEV
#   - DAXDEV

cd $(dirname $BASH_SOURCE)

projbase=$1
[ ! "$projbase" ] && echo "No project given." && exit 1

cmd=$2
[ ! "$cmd" ] && echo "No command given." && exit 1

filter_file() {
	local input=$1
	local projbase=$2
	local flavor=$3
	shift 3
	local keywords="$@"
	local tmp=
	local outfile=work/${projbase}/${flavor}/recipelist

	for k in $keywords ; do
		tmp="$tmp -e $k"
	done
	bash run.sh prepare ${projbase}/${flavor}
	if [ "$tmp" ] ; then
		grep $tmp $input > $outfile
		grep -v $tmp $input > ${input}.bak
		# input file is replaced with remaining list
		mv ${input}.bak ${input}
	else
		mv $input $outfile
	fi
}

if [ "$cmd" = prepare ] ; then
	bash run.sh recipe list > /tmp/recipe
	cat /tmp/subprojects | while read spj keywords ; do
		filter_file /tmp/recipe ${projbase} $spj $keywords
	done
	for spj in $(cat /tmp/subprojects | cut -f1 -d' ') ; do
		wc work/${projbase}/$spj/recipelist
	done
elif [ "$cmd" = run ] ; then
	for spj in $run_order ; do
		./run.sh project run -w ${projbase}/$spj
	done
elif [ "$cmd" = show ] ; then
	for spj in $(cat /tmp/subprojects | cut -f1 -d' ') ; do
		./run.sh project show ${projbase}/$spj
	done
elif [ "$cmd" = summary ] ; then
	for spj in $(cat /tmp/subprojects | cut -f1 -d' ') ; do
		./run.sh project sum $3 ${projbase}/$spj
	done
fi
