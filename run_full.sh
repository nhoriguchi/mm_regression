cat <<EOF > /tmp/subprojects
huge_zero huge_zero
hotrmeove hotremove
acpi_hotplug acpi_hotplug
1gb_hugetlb 1GB
mce mce/einj mce/uc/sr
kvm kvm/
pmem pmem
normal
EOF

# run_order="
cat <<EOF > /tmp/run_order
1gb_hugetlb
hotremove,reboot
acpi_hotplug,kvm,reboot
normal
pmem
kvm,kvm
mce,reboot
huge_zero,reboot
EOF

#
# Usage
#   ./run_full.sh <project_basename> [prepare|run|show|summary]
#
# Description
#   - This script is supposed to be called on host server and the testing
#     server is the guest specified by VM=.
#   - Assuming that the remote testing server should have this test tool
#     just under home directory.
#
# TODO:
#   - run subset of subproject only
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

vm_running() {
	local vm=$1

	if [ ! -f "/var/run/libvirt/qemu/$vm.pid" ] ; then
		return 1
	fi

	if ! kill -0 $(cat /var/run/libvirt/qemu/$vm.pid) 2> /dev/null ; then
		return 1
	fi

	return 0
	# [ "$(virsh domstate ${VM})" = "running" ] && return 0 || return 1
}

vm_start_wait_noexpect() {
	local vm=$1
	local _tmpd=$(mktemp -d)

	if vm_running $vm ; then
		echo "[$vm] domain already running."
	else
		echo "[$vm] starting domain ... "
		virsh start $vm > /dev/null 2>&1
	fi

	for i in $(seq 60) ; do
		if ssh -o ConnectTimeout=3 $vm date > /dev/null 2>&1 ; then
			echo "done $$"
			return 0
		fi
		sleep 1
	done

	echo "VM started, but not ssh-connectable."
	return 1
}

if [ "$VM" ] ; then
	vm_start_wait_noexpect $VM
fi

if [ "$cmd" = prepare ] ; then
	bash run.sh recipe list > /tmp/recipe
	cat /tmp/subprojects | while read spj keywords ; do
		filter_file /tmp/recipe ${projbase} $spj $keywords
	done
	if [ "$VM" ] ; then
		rsync -ae ssh ./ $VM:mm_regression || exit 1
		rsync -ae ssh lib/test_alloc_generic $VM:test_alloc_generic || exit 1
		rsync -ae ssh work/$projbase/ $VM:mm_regression/work/$projbase/ || exit 1
	fi
	for spj in $(cat /tmp/subprojects | cut -f1 -d' ') ; do
		wc work/${projbase}/$spj/recipelist
	done
elif [ "$cmd" = run ] ; then
	for line in $(cat /tmp/run_order) ; do
		spj=
		reboot=
		kvm=
		for tmp in $(echo $line | tr ',' ' ') ; do
			if [ "$tmp" = reboot ] ; then
				reboot=true
			elif [ "$tmp" = kvm ] ; then
				kvm=true
			else
				spj=$tmp
			fi
		done
		echo "subproject:$spj, cmds:${reboot:+reboot} ${kvm:+kvm}"
		if [ ! "$VM" ] ; then # running testcases on the current server
			if [ "$kvm" ] ; then
				echo "KVM-related testset $spj is skipped when VM= is not set."
				continue
			fi
			echo "bash run.sh project run $3 ${projbase}/$spj"
			bash run.sh project run $3 ${projbase}/$spj
			continue
		fi
		vm_start_wait_noexpect $VM
		if [ "$kvm" ] ; then
			[ "$spj" = kvm ] && echo "KVM relay testing is not implemented yet." && continue
			echo "bash run.sh project run $3 ${projbase}/$spj"
			bash run.sh project run $3 ${projbase}/$spj
		else
			echo "Running testset $spj on the guest $VM"
			# sync current working on testing server to host server
			rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
			failretry="$(grep FAILRETRY= work/${projbase}/$spj/config | cut -f2 -d=)"
			finished_before="$([ -e work/${projbase}/$spj/$failretry/__finished ] && echo DONE || echo NOTDONE )"
			ssh $VM mm_regression/run.sh project run $3 ${projbase}/$spj
			echo "rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase [$reboot]"
			rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
			if [ "$reboot" ] ; then
				finished_after="$([ -e work/${projbase}/$spj/$failretry/__finished ] && echo DONE || echo NOTDONE )"
				# reboot only when this subproject is finished at this running.
				# If it's already finished (judged by the existence of the file
				# work/<subproj>/<maxretry>/__finished
				if [ "$finished_before" = NOTDONE ] && [ "$finished_after" = DONE ] ; then
					echo "rebooting $VM ..."
					ssh $VM reboot
				fi
			fi
		fi
	done
elif [ "$cmd" = show ] ; then
	if [ "$VM" ] ; then
		rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
	fi
	for spj in $(cat /tmp/subprojects | cut -f1 -d' ') ; do
		./run.sh project show ${projbase}/$spj
	done
elif [ "$cmd" = summary ] ; then
	if [ "$VM" ] ; then
		rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
	fi
	for spj in $(cat /tmp/subprojects | cut -f1 -d' ') ; do
		./run.sh project sum $3 ${projbase}/$spj
	done
fi
