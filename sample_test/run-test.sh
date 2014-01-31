#!/bin/bash

TESTCORE=/root/upstream/test_core/run-test.sh
TESTCASE_FILTER="$@"
[ "$TESTCASE_FILTER" ] && TESTCASE_FILTER="-f ${TESTCASE_FILTER}"

bash ${TESTCORE} -v -t sample ${TESTCASE_FILTER} ./sample.rc
