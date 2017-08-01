obj-m += cap_check.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules || true

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean

check: all
	insmod ./cap_check.ko
	rmmod cap_check
	dmesg | tail
	true
