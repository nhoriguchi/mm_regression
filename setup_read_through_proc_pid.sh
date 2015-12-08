control_read_through_proc_pid() {
    ls -1 /proc | grep ^[0-9] > $TMPF.pids
    echo "Walk through all processes and check pagemap/maps/smaps/numa_maps" | tee -a $OFILE
    while read pid ; do
        $PAGETYPES -p $pid -N    > /dev/null 2>&1
        cat /proc/$pid/maps      > /dev/null 2>&1
        cat /proc/$pid/smaps     > /dev/null 2>&1
        cat /proc/$pid/numa_maps > /dev/null 2>&1
    done < $TMPF.pids
    echo "done" | tee -a $OFILE
    set_return_code EXIT
}
