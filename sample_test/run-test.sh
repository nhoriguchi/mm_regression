#!/bin/bash

THISDIR=$(dirname $(readlink -f $BASH_SOURCE))
[ ! -d ${THISDIR}/test_core ] && git clone https://github.com/Naoya-Horiguchi/test_core
TESTCORE=${THISDIR}/test_core/run-test.sh

[ ! -f ${TESTCORE} ] && echo "No test_core on ${THISDIR}/test_core." && exit 1

TESTCASE_FILTER="$@"
[ "$TESTCASE_FILTER" ] && TESTCASE_FILTER="-f \"${TESTCASE_FILTER}\""

eval bash ${TESTCORE} -v -t sample ${TESTCASE_FILTER} ./sample.rc
