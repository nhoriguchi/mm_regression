#!/bin/bash

if [[ "$0" =~ "$BASH_SOURCE" ]] ; then
    echo "$BASH_SOURCE should be included from another script, not directly called."
    exit 1
fi

vm_running() {
    [ "$(virsh domstate ${VM})" = "running" ] && return 0 || return 1
}

vm_connectable() {
    ping -w1 $VMIP > /dev/null
}

vm_ssh_connectable() {
    ssh $VMIP date > /dev/null 2>&1
}

# Start VM and wait until the VM become connectable.
vm_start_wait() {
    cat <<EOF > ${TMPF}.vm_start_wait.exp
#!/usr/bin/expect

set timeout 1
set timecount 100
log_file -noappend ${TMPF}.vm_start_wait.log

spawn virsh console $VM

expect "Escape character is"
send "\n"
while {\$timecount > 0} {
    send "\n"
    expect "login:" {
        send_user "\nVM start finished\n"
        break
    }
    set timecount [expr \$timecount-1]
    if {[expr \$timecount] == 0} {
        send_user "\nVM start timeout\n"
    }
}
send -- ""
interact
EOF
    echo "starting domain $VM ..."
    virsh start $VM > /dev/null 2>&1
    expect ${TMPF}.vm_start_wait.exp > /dev/null 2>&1
    [ ! -e ${TMPF}.vm_start_wait.log ] && echo "expect failed." && return 1
    grep "VM start finished" ${TMPF}.vm_start_wait.log > /dev/null
    if [ $? -eq 0 ] ; then
        if vm_ssh_connectable ; then return 0 ; fi
        sleep 5
        if vm_ssh_connectable ; then return 0 ; fi
        sleep 5
        if vm_ssh_connectable ; then return 0 ; fi
        sleep 5
        if vm_ssh_connectable ; then return 0 ; fi
    fi
    echo "VM start failed."
    exit 1
}

VMDIRTY=false
get_vmdirty()   { echo $VMDIRTY; }
set_vmdirty()   { VMDIRTY=true;  }
clear_vmdirty() { VMDIRTY=false; }
vmdirty()       { [ $VMDIRTY = true ] && return 0 || return 1 ; }

vm_restart_wait() {
    echo -n "Rebooting $VM ..."
    virsh destroy $VM > /dev/null 2>&1
    vm_start_wait $VM > /dev/null 2>&1 || echo "vm_start failed."
    echo "Rebooting done."
    clear_vmdirty
}
