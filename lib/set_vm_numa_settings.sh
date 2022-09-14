set_vm_numa_setting() {
	local vm=$1
	local vcpus=$2
	local vmem=$3 # in GiB

	# VM restart is needed?
	virsh dumpxml $vm > $TMPD/vm.xml.orig
	local _vcpus=$(grep "<vcpu " $TMPD/vm.xml.orig | cut -f2 -d'>' | cut -f1 -d'<')
	local _vmem=$(grep "<currentMemory " $TMPD/vm.xml.orig | cut -f2 -d'>' | cut -f1 -d'<')
	_vmem=$[_vmem >> 20]

	local need_restart=false
	if [ "$vcpus" ] && [ "$vcpus" -ne "$_vcpus" ] ; then
		need_restart=true
	elif [ "$vmem" ] && [ "$vmem" -ne "$_vmem" ] ; then
		need_restart=true
	elif ! grep -q "<maxMemory " $TMPD/vm.xml.orig ; then
		need_restart=true
	elif ! grep -q "<numa" $TMPD/vm.xml.orig ; then
		need_restart=true
	fi
	if [ "$need_restart" = false ] ; then
		return 0
	fi

	virsh destroy $vm 2> /dev/null
	virsh dumpxml $vm > $TMPD/vm.xml || return 1

	if [ ! "$vcpus" ] ; then
		vcpus=$(virsh dominfo $vm | grep "^CPU(s):" | awk '{print $2}')
	fi
	if [ ! "$vmem" ] ; then
		vmem=$(virsh dominfo $vm | grep "^Used memory:" | awk '{print $3}')
		vmem=$[vmem >> 20]
	fi

	sed -i -e "s|<currentMemory.*>.*|<currentMemory unit='GiB'>$vmem</currentMemory>|" $TMPD/vm.xml
	sed -i -e "s|\(<vcpu .*>\).*</vcpu>|\1$vcpus</vcpu>|" $TMPD/vm.xml

	# reset current <numa> setting
	if grep -q "<numa>" $TMPD/vm.xml ; then
		line1=$(grep -n "<numa>" $TMPD/vm.xml | cut -f1 -d:)
		line2=$(grep -n "</numa>" $TMPD/vm.xml | cut -f1 -d:)
		head -n$[line1 - 1] $TMPD/vm.xml > $TMPD/.vm.xml
		sed -n -e $[line2+1]',$p' $TMPD/vm.xml >> $TMPD/.vm.xml
		mv $TMPD/.vm.xml $TMPD/vm.xml
	fi

	if ! grep -q "<maxMemory " $TMPD/vm.xml ; then
		# insert <maxMemory> tag
		head -n3 $TMPD/vm.xml > $TMPD/.vm1.xml
		echo "<maxMemory slots='16' unit='KiB'>125829120</maxMemory>" >> $TMPD/.vm1.xml
		sed -ne '4,$p' $TMPD/vm.xml > $TMPD/.vm2.xml
		cat $TMPD/.vm1.xml $TMPD/.vm2.xml > $TMPD/vm.xml
	fi

	# update xml
	if grep "<cpu .*/>" $TMPD/vm.xml ; then # simple element
		local line=$(grep -n "<cpu .*/>" $TMPD/vm.xml | cut -f1 -d:)
		head -n$[line - 1] $TMPD/vm.xml > $TMPD/.vm.xml
		grep -n "<cpu .*/>" $TMPD/vm.xml | sed -e 's|/>|>|' >> $TMPD/.vm.xml
		cat <<EOF >> $TMPD/.vm.xml
<numa>
  <cell id='0' cpus='0-$[vcpus/2-1]' memory='$[vmem/2]' unit='GiB'/>
  <cell id='1' cpus='$[vcpus/2]-$[vcpus-1]' memory='$[vmem/2]' unit='GiB'/>
</numa>
EOF
		echo "</cpu>" >> $TMPD/.vm.xml
		sed -n -e $[line+1]',$p' $TMPD/vm.xml >> $TMPD/.vm.xml
	elif grep "<cpu .*>" $TMPD/vm.xml ; then # multiline element
		local line=$(grep -n "<cpu .*>" $TMPD/vm.xml | cut -f1 -d:)
		head -n$[line] $TMPD/vm.xml > $TMPD/.vm.xml
		cat <<EOF >> $TMPD/.vm.xml
<numa>
  <cell id='0' cpus='0-$[vcpus/2-1]' memory='$[vmem/2]' unit='GiB'/>
  <cell id='1' cpus='$[vcpus/2]-$[vcpus-1]' memory='$[vmem/2]' unit='GiB'/>
</numa>
EOF
		sed -n -e $[line+1]',$p' $TMPD/vm.xml >> $TMPD/.vm.xml
	fi
	mv $TMPD/.vm.xml $TMPD/vm.xml
	virsh define $TMPD/vm.xml
}

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
	export TMPD=$(mktemp -d)
	echo "set_vm_numa_setting $1 $2 $3"
	set_vm_numa_setting $1 $2 $3
fi
