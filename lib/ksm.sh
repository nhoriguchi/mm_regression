KSMDIR="/sys/kernel/mm/ksm"

[ ! -d "$KSMDIR" ] && echo "Kernel not support ksm." >&2 && exit 1

ksm_on() {
    echo 1    > $KSMDIR/run
    echo 1000 > $KSMDIR/pages_to_scan
    echo 0    > $KSMDIR/sleep_millisecs
}
ksm_off() {
    echo 2    > $KSMDIR/run
    echo 100  > $KSMDIR/pages_to_scan
    echo 20   > $KSMDIR/sleep_millisecs
}
get_pages_run()      { cat $KSMDIR/run;            }
get_pages_shared()   { cat $KSMDIR/pages_shared;   }
get_pages_sharing()  { cat $KSMDIR/pages_sharing;  }
get_pages_unshared() { cat $KSMDIR/pages_unshared; }
get_pages_volatile() { cat $KSMDIR/pages_volatile; }
get_full_scans()     { cat $KSMDIR/full_scans;     }

show_ksm_params() {
    echo "KSM params: run:`get_pages_run`, shared:`get_pages_shared`, sharing:`get_pages_sharing`, unshared:`get_pages_unshared`, volatile:`get_pages_volatile`, scans:`get_full_scans`"
}
