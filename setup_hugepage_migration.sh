# common part for hugetlb/thp migration

check_migration_pagemap() {
	local before=$1
	local after=$2

	diff -u1000000 $before $after > $TMPD/.mig.diff
	local before=$(grep "^-" $TMPD/.mig.diff | wc -l)
	local after=$(grep "^+" $TMPD/.mig.diff | wc -l)
	local unchange=$(grep "^ " $TMPD/.mig.diff | wc -l)

	echo_log "check pagemap"
	if [ "$before" -gt 0 ] && [ "$after" -gt 0 ] ; then
		if [ "$unchange" -ne 0 ] ; then
			echo_log "some pages migrated ($unchange pages failed)"
		else
			echo_log "all pages migrated"
		fi
		return 0
	else
		echo_log "no page migrated"
		return 1
	fi
}

check_migration_hugeness() {
	local before=$1
	local after=$2

	grep -e H_ -e _T $before | cut -f1,2 > $TMPD/.pagetypes.huge.1
	grep -e H_ -e _T $after  | cut -f1,2 > $TMPD/.pagetypes.huge.2
	diff -u1000000 $TMPD/.pagetypes.huge.1 $TMPD/.pagetypes.huge.2 > $TMPD/.pagetypes.huge.diff
	local before=$(grep "^-" $TMPD/.pagetypes.huge.diff | wc -l)
	local after=$(grep "^+" $TMPD/.pagetypes.huge.diff | wc -l)
	local unchange=$(grep "^ " $TMPD/.pagetypes.huge.diff | wc -l)

	echo_log "check hugepage migration"
	if [ ! -s $TMPD/.pagetypes.huge.1 ] ; then
		echo_log "no hugepage"
		return 3
	elif [ ! -s $TMPD/.pagetypes.huge.2 ] ; then
		echo_log "hugepage disappeared (maybe split?)"
		return 2
	elif [ "$before" -gt 0 ] && [ "$after" -gt 0 ] ; then
		if [ "$unchange" -ne 0 ] ; then
			echo_log "some hugepages migrated ($unchange hugepages failed)"
		else
			echo_log "all hugepages migrated"
		fi
		return 0
	else
		echo_log "no hugepage migrated"
		return 1
	fi
}

check_migration_done() {
	local before=$1
	local after=$2

	if check_migration_pagemap $before $after ; then
		set_return_code MIGRATION_PASSED
	else
		set_return_code MIGRATION_FAILED
	fi
	check_migration_hugeness $before $after
	local ret=$?
	if [ "$ret" == 0 ] ; then
		set_return_code HUGEPAGE_MIGRATED
	elif [ "$ret" == 1 ] ; then
		set_return_code HUGEPAGE_NOT_MIGRATED
	elif [ "$ret" == 2 ] ; then
		set_return_code HUGEPAGE_DISAPPEARED
	elif [ "$ret" == 3 ] ; then
		set_return_code HUGEPAGE_NOT_EXIST
	fi
}
