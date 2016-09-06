obj-m += cap_check.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean

check: all
	sudo insmod ./cap_check.ko
	sudo rmmod cap_check
	dmesg | tail
