cat <<EOF > /tmp/subprojects
huge_zero huge_zero
hotrmeove hotremove
acpi_hotplug acpi_hotplug
1gb_hugetlb 1GB
mce mce/einj mce/uc/sr
kvm /kvm/
pmem cases/pmem
normal
EOF

# run_order="
cat <<EOF > /tmp/run_order
1gb_hugetlb
hotremove reboot
acpi_hotplug
normal
mce
pmem
kvm
huge_zero
EOF

#
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
#
show_help() {
	sed -n 2,$[$BASH_LINENO-4]p $BASH_SOURCE | grep "^#" | sed 's/^#/ /'
	exit 0
}

cd $(dirname $BASH_SOURCE)

projbase=$1
[ ! "$projbase" ] && echo "No project given." && show_help

cmd=$2
[ ! "$cmd" ] && echo "No command given." && show_help

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
	cat /tmp/run_order | while read spj commands ; do
		failretry="$(grep FAILRETRY= work/${projbase}/$spj/config | cut -f2 -d=)"
		finished_before="$([ -e work/${projbase}/$spj/$failretry/__finished ] && echo DONE || echo NOTDONE )"
		./run.sh project run -w ${projbase}/$spj
		if [ "$commands" = reboot ] ; then
			finished_after="$([ -e work/${projbase}/$spj/$failretry/__finished ] && echo DONE || echo NOTDONE )"
			# reboot only when this subproject is finished at this running.
			# If it's already finished (judged by the existence of the file
			# work/<subproj>/<maxretry>/__finished
			if [ "$finished_before" = NOTDONE ] && [ "$finished_after" = DONE ] ; then
				reboot
			fi
		fi
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
