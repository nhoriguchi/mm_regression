# bash lib/build/build_test.sh -c /root/config.trial.220911f 220920c

# TODO: -Werror 警告をオフにしていると、linux-next 等で大量に出てくるコンパイルエラーと自身の開発パッチが引き起こしたコンパイルエラーを区別できず、自動検出したことにならない気がする。

config_base=/virt/kernel_source/build2/.config
patches=1
while true ; do
	case $1 in
		-c|--config)
			config_base=$2
			shift 2
			;;
		-n|--patches)
			patches=$2
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

KERNEL=$1
[ ! "$KERNEL" ] && echo "need to give tag to build" && exit 1

src=/virt/kernel_source/dev1
build=/virt/kernel_source/build1
export KBUILD_OUTPUT=$build
KTOOLDIR=/root/src/kernel-tool
pushd $src
git checkout -f $KERNEL || exit 1
popd

targets="mm fs drivers/base"
hugetlb_settings="y n"
memory_failure_settings="y n"
memory_hotplug_settings="y n"

set -x
# targets="mm"
# targets="drivers/base/memory.o"
# hugetlb_settings="y"
# memory_failure_settings="y"
# memory_hotplug_settings="n"

result=build_test_result_$KERNEL.txt
rm $result

for num in $(seq 0 $[patches-1]) ; do
	# ops="${huge:+$huge HUGETLB_PAGE $huge HUGETLBFS} ${mf:+$mf MEMORY_FAILURE} ${hp:+$hp MEMORY_HOTPLUG $hp MEMORY_HOTREMOVE}"
	kernel_cid=$(git --git-dir=/virt/kernel_source/core log -n1 --pretty=format:%h refs/tags/${KERNEL}~${num})
	git --git-dir=$src/.git checkout --quiet --detach $kernel_cid || exit 1
	git --git-dir=$src/.git reset --hard || exit 1
for huge in $hugetlb_settings ; do
for mf in $memory_failure_settings ; do
for hp in $memory_hotplug_settings ; do
	cp $config_base /tmp/config
	ops=""
	if [ "$huge" == n ] ; then
		ops="$ops -d HUGETLB_PAGE -d HUGETLBFS"
	fi
	if [ "$mf" == n ] ; then
		ops="$ops -d MEMORY_FAILURE"
	fi
	if [ "$hp" == n ] ; then
		ops="$ops -d MEMORY_HOTPLUG -d MEMORY_HOTREMOVE"
	fi
	# don't use option -U
	echo "=== scripts/config --file /tmp/config $ops"
	if [ "$ops" ] ; then
		$src/scripts/config --file /tmp/config $ops
	else
		echo "no update, simply use $config_base"
	fi
	echo "## git checkout --detach $kernel_cid"
	pwd
	cp /tmp/config $KBUILD_OUTPUT/.config
	make -s -C $src olddefconfig > /dev/null
	diff -U0 $config_base /tmp/config

for target in $targets ; do
	echo "### huge:${huge}, mf:${mf}, hp:${hp}, target:${target}, commit ID:${kernel_cid}"
	echo "## rm -rf $KBUILD_OUTPUT/$target"
	rm -rf $KBUILD_OUTPUT/$target

	echo "## make -j $(nproc)"
	make -s -C $src -j $(nproc) $target 2> /tmp/error
	# echo "## bash $KTOOLDIR/charlotte_build.sh -c /tmp/config -T $target 1 $kernel_cid"
	# bash $KTOOLDIR/charlotte_build.sh -c /tmp/config -T $target 1 $kernel_cid 2> /tmp/error
	if [ "$?" -eq 0 ] ; then
		echo "huge:${huge}, mf:${mf}, hp:${hp}, target:${target}, commit ID:${kernel_cid}: OK" >> $result
	else
		echo "huge:${huge}, mf:${mf}, hp:${hp}, target:${target}, commit ID:${kernel_cid}: NG" >> $result
		cat /tmp/error | sed 's/^/# /' >> $result
	fi
done
done
done
done
done

exit 0

# TODO: MEMORY_FAILURE と MEMORY_HOTPLUG だけ操作しても依存する config 次第で
# 設定を変更できないことがある。まともな方法が必要。
# 有効にするのは順序がきまっているが、無効にするのは一つ設定で可能と思われる。
# いったん、config の更新だけ想定通りかをチェックするテストを書いてみると良い。
for huge in -d -e ; do
for mf in -d -e ; do
for hp in -d -e ; do
for target in $targets ; do
	cp $config_base /tmp/config
	ops="${huge:+$huge HUGETLB_PAGE $huge HUGETLBFS} ${mf:+$mf MEMORY_FAILURE} ${hp:+$hp MEMORY_HOTPLUG $hp MEMORY_HOTREMOVE}"
	echo "========== $ops"
	$src/scripts/config --file /tmp/config $ops
	diff -U0 $config_base /tmp/config
	cp /tmp/config $KBUILD_OUTPUT/.config
	make -C $src olddefconfig > /dev/null
	rm -rf $KBUILD_OUTPUT/mm
	# don't use option -U
	bash $KTOOLDIR/charlotte_build.sh -c /tmp/config -T $target 1 $KERNEL || exit 1
done
done
done
done
