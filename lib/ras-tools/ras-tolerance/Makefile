ifneq  ($(KERNELRELEASE),)
	obj-m:=ras_tolerance.o
else
	KDIR := /lib/modules/$(shell uname -r)/build/  
CFLAGS= -O0
PWD:=$(shell pwd)
all:
	    make -C $(KDIR) M=$(PWD) modules
clean:
	    rm -f *.ko *.o *.symvers *.cmd *.cmd.o
endif
