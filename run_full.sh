cat <<EOF > /tmp/subprojects
huge_zero huge_zero
hotremove hotremove
acpi_hotplug acpi_hotplug
1gb_hugetlb 1GB
mce mce/einj mce/uc/sr
kvm kvm/
pmem pmem
normal
EOF

# TODO: kvm は beaker 環境のみ
cat <<EOF > /tmp/run_order
stress
performance
reboot
1gb_hugetlb
normal
pmem
kvm,needvm
reboot
huge_zero
reboot
hotremove
reboot
acpi_hotplug,needvm
reboot
mce
EOF

if [ "$__DEBUG" ] ; then
	cat <<EOF > /tmp/subprojects2
1gbA 1GB_hwp_entry
1gbB 1GB_hwpoison_race
1gbC 1GB_inj/type-anon
1gbD 1GB_inj/type-file
normal
EOF

	cat <<EOF > /tmp/run_order2
1gbA
reboot
1gbB
1gbC
reboot
1gbD
EOF

	cat <<EOF > /tmp/run_order
normal
EOF
fi

#
# Usage
#   ./run_full.sh <project_basename> [options] [prepare|run|show|summary|check_finished]
#
# Description
#   - This script is supposed to be called on host server and the testing
#     server is the guest specified by VM=.
#   - Assuming that the remote testing server should have this test tool
#     just under home directory.
#
# Options:
#   -r|--run-order <file>    provide run_order file from command line
#   -h|--help
#
# TODO:
#   - run subset of subproject only
#   - change config setting for each subproject
#
# Environment variable
#   - VM
#   - STAP_DIR
#   - PMEMDEV
#   - DAXDEV
#
show_help() {
	sed -n 2,$[$BASH_LINENO-4]p $BASH_SOURCE | grep "^#" | sed 's/^#/ /'
	exit 0
}

cd $(dirname $BASH_SOURCE)

RUN_ORDER=/tmp/run_order
while true ; do
	case $1 in
		-r|--run-order)
			RUN_ORDER="$2"
			shift 2
			;;
		-h|--help)
			show_help
			;;
		*)
			break
			;;
	esac
done

projbase=$1
[ ! "$projbase" ] && echo "No project given." && show_help

cmd=$2
[ ! "$cmd" ] && echo "No command given." && show_help

shift 2

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
}

vm_ssh_connectable_one() {
	local vm=$1

	ssh -o ConnectTimeout=3 $vm date > /dev/null 2>&1
}

vm_start_wait_noexpect() {
	local vm=$1
	local _tmpd=$(mktemp -d)

	if ! vm_running $vm ; then
		echo "[$vm] starting domain ... "
		virsh start $vm > /dev/null 2>&1
	fi

	for i in $(seq 60) ; do
		if vm_ssh_connectable_one $vm ; then
			return 0
		fi
		sleep 1
	done

	echo "VM started, but not ssh-connectable."
	return 1
}

if [ "$VM" ] ; then
	vm_start_wait_noexpect $VM
	export PMEMDEV=$(ssh $VM ndctl list 2> /dev/null | jq -r '.[] | select(.mode=="fsdax") | [.blockdev] | @csv' | head -n1 | tr -d '"')
fi

if [ "$cmd" = prepare ] ; then
	make
	bash run.sh recipe list > /tmp/recipe
	cat /tmp/subprojects | while read spj keywords ; do
		filter_file /tmp/recipe ${projbase} $spj $keywords
	done
	if [ "$VM" ] ; then
		echo $VM > work/$projbase/vm
		rsync -ae ssh ./ $VM:mm_regression || exit 1
		rsync -ae ssh lib/test_alloc_generic $VM:test_alloc_generic || exit 1
		rsync -ae ssh work/$projbase/ $VM:mm_regression/work/$projbase/ || exit 1
		# TODO: page-types might depend on GLIBC version
		TMPD=/tmp bash lib/set_vm_numa_settings.sh $VM 8 8
		vm_start_wait_noexpect $VM
	fi
	for spj in $(cat /tmp/subprojects | cut -f1 -d' ') ; do
		wc work/${projbase}/$spj/recipelist
	done
elif [ "$cmd" = run ] ; then
	export VM=$(cat work/$projbase/vm)

	# checking run option
	again=
	for opt in $@ ; do
		if [ "$opt" = "-a" ] ; then
			again=true
		fi
	done

	for line in $(cat $RUN_ORDER) ; do
		spj=
		kvm=
		for tmp in $(echo $line | tr ',' ' ') ; do
			if [ "$tmp" = reboot ] ; then
				if [ "$FINISHED" = true ] && [ "$VM" ] ; then
					virsh destroy $VM
					sleep 5
					FINISHED=
				fi
			elif [ "$tmp" = needvm ] ; then
				kvm=true
			else
				spj=$tmp
				if [ ! -d "work/$projbase/$spj" ] ; then
					echo "Undefined subproject '$spj', skipped"
					spj=
				fi
			fi
		done
		[ ! "$spj" ] && continue
		echo "subproject:$spj, cmds:${kvm:+kvm}"
		if [ ! "$VM" ] ; then # running testcases on the current server
			if [ "$kvm" ] ; then
				echo "KVM-related testset $spj is skipped when VM= is not set."
				continue
			fi
			echo "bash run.sh project run $@ ${projbase}/$spj"
			bash run.sh project run $@ ${projbase}/$spj
			continue
		fi
		vm_start_wait_noexpect $VM
		if [ "$kvm" ] ; then
			[ "$spj" = kvm ] && echo "KVM relay testing is not implemented yet." && continue
			echo "Running testset \"$spj\" on the host server."
			echo "bash run.sh project run $@ ${projbase}/$spj"
			bash run.sh project run $@ ${projbase}/$spj
		else
			finished_before="$(bash run.sh proj check_finished ${projbase}/$spj)"
			count=3
			while [ "$count" -gt 0 ] ; do
				count=$[count - 1]
				vm_start_wait_noexpect $VM
				sleep 5
				echo "Running testset $spj on the guest $VM"
				# sync current working on testing server to host server
				rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
				if [ ! "$again" ] ; then
					finished="$(bash run.sh proj check_finished ${projbase}/$spj)"
					echo "Finished: $finished"
					if [ "$finished" = DONE ] ; then
						break
					fi
				else
					again=
				fi
				ssh -t $VM "STAP_DIR=$STAP_DIR PMEMDEV=$PMEMDEV bash mm_regression/run.sh project run $@ ${projbase}/$spj"
				# Sometimes ssh connection is disconnected with error, so
				# we need check that VM can continue to test or need rebooting.
				if ! vm_ssh_connectable_one $VM ; then
					echo "[$VM] VM stopped forcibly"
					virsh destroy $VM
					sleep 5
				fi
			done

			finished_after="$(bash run.sh proj check_finished ${projbase}/$spj)"
			# reboot only when this subproject is finished at this running.
			# If it's already finished (judged by the existence of the file
			# work/<subproj>/<maxretry>/__finished
			if [ "$finished_before" = NOTDONE ] && [ "$finished_after" = DONE ] ; then
				echo "Subproject $spj finished."
				FINISHED=true
			fi
		fi
	done
elif [ "$cmd" = show ] ; then
	export VM=$(cat work/$projbase/vm)
	if [ "$VM" ] ; then
		rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
	fi
	for spj in $(cat $RUN_ORDER | cut -f1 -d,) ; do
		./run.sh project show ${projbase}/$spj
	done
elif [ "$cmd" = summary ] ; then
	export VM=$(cat work/$projbase/vm)
	if [ "$VM" ] ; then
		rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
	fi
	for spj in $(cat $RUN_ORDER | cut -f1 -d,) ; do
		./run.sh project sum $@ ${projbase}/$spj
	done
elif [ "$cmd" = summary2 ] ; then
	export VM=$(cat work/$projbase/vm)
	if [ "$VM" ] ; then
		rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
	fi
	echo > /tmp/.summary2
	for spj in $(cat $RUN_ORDER | cut -f1 -d,) ; do
		./run.sh project sum -P ${projbase}/$spj >> /tmp/.summary2
	done
	echo "Summary Table:"
	ruby test_core/lib/summary_table.rb /tmp/.summary2
elif [ "$cmd" = check_finished ] ; then
	export VM=$(cat work/$projbase/vm)
	if [ "$VM" ] ; then
		rsync -ae ssh $VM:mm_regression/work/$projbase/ work/$projbase/
	fi
	for spj in $(cat $RUN_ORDER | cut -f1 -d,) ; do
		./run.sh project check_finished ${projbase}/$spj
		if [ $? -eq 7 ] ; then
			# some subprojects are not done yet.
			echo "subproject:$spj NOTDONE"
			exit 7
		fi
		echo "subproject:$spj DONE"
	done
	# all subprojects are done.
	exit 0
fi
