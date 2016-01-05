#!/bin/bash

vm_running() {
    [ "$(virsh domstate ${VM})" = "running" ] && return 0 || return 1
}

vm_connectable() {
    ping -w1 $VMIP > /dev/null
}

vm_ssh_connectable() {
    ssh ${SSH_OPT} $VMIP date > /dev/null 2>&1
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

vm_restart_if_unconnectable() {
    if ! vm_ssh_connectable ; then
        echo "$VM reboot at first"
        virsh destroy $VM > /dev/null 2>&1
        vm_start_wait > /dev/null 2>&1
    fi
}

vm_serial_monitor() {
    cat <<EOF > ${TMPF}.vm_serial_monitor.exp
#!/usr/bin/expect

set timeout 5
set target $VM
log_file -noappend ${TMPF}.vm_serial_monitor.log

spawn virsh console $VM
expect "Escape character is"
send "\n"
send "\n"
sleep 10
send -- ""
interact
EOF
    expect ${TMPF}.vm_serial_monitor.exp > /dev/null 2>&1
}

run_vm_serial_monitor() {
    vm_serial_monitor $VM > /dev/null 2>&1 &
    GUESTSERIALMONITORPID=$!
    sleep 1
}

stop_vm_serial_monitor() {
    disown $GUESTSERIALMONITORPID
    kill -SIGKILL $GUESTSERIALMONITORPID > /dev/null 2>&1
}

get_guest_kernel_message() {
    echo "####### GUEST CONSOLE #######"
    if [ -e "${TMPF}.dmesg_guest_after" ] ; then
        diff ${TMPF}.dmesg_guest_before ${TMPF}.dmesg_guest_after | \
            grep -v '^< ' | tee ${TMPF}.dmesg_guest_diff
    else
        layout_guest_dmesg ${TMPF}.vm_serial_monitor.log | \
            tee ${TMPF}.dmesg_guest_diff
    fi
    echo "####### GUEST CONSOLE END #######"
}

get_guest_kernel_message_before() {
    ssh ${SSH_OPT} $VMIP dmesg > ${TMPF}.dmesg_guest_before
    rm ${TMPF}.dmesg_guest_after 2> /dev/null
}

get_guest_kernel_message_after() {
    ssh ${SSH_OPT} $VMIP dmesg > ${TMPF}.dmesg_guest_after
}

layout_guest_dmesg() {
    tac $1 | gawk '
  BEGIN { flag = 0; }
  {
    if (flag == 0 && $0 ~ /.*login: .*/) {
      flag = 1;
      print gensub(/.*login: (.*)/, "\\1", "g", $0);
    }
    if (flag == 0) { print $0; }
  }
' | tac
}

check_guest_kernel_message() {
    [ "$1" = -v ] && local inverse=true && shift
    local word="$1"
    if [ "$word" ] ; then
        count_testcount
        grep "$word" ${TMPF}.dmesg_guest_diff > /dev/null 2>&1
        if [ $? -eq 0 ] ; then
            if [ "$inverse" ] ; then
                count_failure "guest kernel message shows unexpected word '$word'."
            else
                count_success "guest kernel message shows expected word '$word'."
            fi
        else
            if [ "$inverse" ] ; then
                count_success "guest kernel message does not show unexpected word '$word'."
            else
                count_failure "guest kernel message does not show expected word '$word'."
            fi
        fi
    fi
}
