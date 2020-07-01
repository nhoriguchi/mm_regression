#!/bin/bash

. $TRDIR/lib/mm.sh

prepare_mmgeneric() {
	prepare_mm_generic || return 1
}

cleanup_mmgeneric() {
	[[ "$(jobs -p)" ]] && kill -9 $(jobs -p) 2> /dev/null
	cleanup_mm_generic
}

check_mmgeneric() {
	true
}

control_mmgeneric() {
    local pid="$1"
    local line="$2"

	if [ "$pid" ] ; then # sync mode
		echo_log "=> $line"
		case "$line" in
			*)
				;;
		esac
		return 1
	fi
}

#
# Default definition. You can overwrite in each recipe
#
_control() {
	control_mmgeneric "$1" "$2"
}

_prepare() {
	prepare_mmgeneric || return 1
}

_cleanup() {
	cleanup_mmgeneric
}

_check() {
	check_mmgeneric
}
