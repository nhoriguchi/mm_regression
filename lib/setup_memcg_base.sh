if [ ! -d /sys/fs/cgroup/memory ] ; then                            
    echo "memory cgroup is not supported on this kernel $(uname -r)"
    exit 1
fi                                                                  

MEMCGDIR=/sys/fs/cgroup/memory

yum install -y libcgroup-tools > /dev/null 2>&1
