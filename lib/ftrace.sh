#!/bin/bash

DEBUGFSDIR=$(mount | grep debugfs | head -n1 | cut -f3 -d' ')
[ ! "${DEBUGFSDIR}" ] && echo "no debugfs" && exit 1
FTRACEDIR=${DEBUGFSDIR}/tracing
[ ! "${FTRACEDIR}" ] && echo "no debugfs:tracing" && exit 1

on() {
    echo "tracing on"

    # clear buffer
    echo 0 > tracing_on
    echo nop > current_tracer
    echo function_graph > current_tracer

    echo "" > set_ftrace_filter
    echo "printk" > set_ftrace_notrace
    echo "" > set_graph_function
    echo "printk" > set_graph_notrace

    echo 0 > options/funcgraph-irqs

    # echo "SyS_sync_file_range" > set_graph_function
    echo "serial8250_console_write printk print_context_stack vprintk_emit" > set_graph_notrace

    echo 1 > tracing_on
}

off() {
    echo 0 > tracing_on
    echo "tracing off"
}

show() {
    cat trace
}

pushd "${FTRACEDIR}" > /dev/null

SUBCMD="$1"
shift 1

if [ "$SUBCMD" = on ] ; then
    on
elif [ "$SUBCMD" = off ] ; then
    off
elif [ "$SUBCMD" = show ] ; then
    show
else
    # wrapper mode
    on
    $SUBCMD $@
    off
fi

popd > /dev/null
