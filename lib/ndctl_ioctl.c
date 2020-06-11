/*
 * 使用方法:
 *  - ./ndctl_ioctl 2                    // Start ARS
 *  - ./ndctl_ioctl 3                    // Query ARS status
 *  - ./ndctl_ioctl 4                    // Clear Error
 *  - ./ndctl_ioctl 4 <start> <length>   // Clear Error (on given range)
 *  - ./ndctl_ioctl 5 <arg>              // SPA -> DPA translation
 *  - ./ndctl_ioctl 7 <start> <length>   // ARS Error Inject
 *  - ./ndctl_ioctl 8 <start> <length>   // ARS Error Inject Clear
 *  - ./ndctl_ioctl 9                    // ARS Error Inject Status Query
 *
 *  - ./ndctl_ioctl 18                   // ACPI NVDIMM specific error
 *
 * 注意:
 *    カーネルメッセージに関連ドライバのデバッグメッセージを
 *    出力させるためには、カーネルブートパラメータに
 *    libnvdimm.dyndbg=+fp nfit.dyndbg=+p を追加する。
 */
#include <sys/mman.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>

/* see 9.20.7 NVDIMM Root Device _DSMs in ACPI spec ver 6.2 */
#define ND_CMD_ARS_CAP		0xffff0001
#define ND_CMD_ARS_START	0xffff0002
#define ND_CMD_ARS_STATUS	0xffff0003
#define ND_CMD_CLEAR_ERROR	0xffff0004
#define ND_CMD_CALL		0xffff000a
#define NFIT_CMD_TRANSLATE_SPA		0x5
#define NFIT_CMD_ARS_INJECT_SET		0x7
#define NFIT_CMD_ARS_INJECT_CLEAR	0x8
#define NFIT_CMD_ARS_INJECT_GET		0x9

/*
 * Command numbers that the kernel needs to know about to handle
 * non-default DSM revision ids
 */
enum nvdimm_family_cmds {
        NVDIMM_INTEL_LATCH_SHUTDOWN = 10,
        NVDIMM_INTEL_GET_MODES = 11,
        NVDIMM_INTEL_GET_FWINFO = 12,
        NVDIMM_INTEL_START_FWUPDATE = 13,
        NVDIMM_INTEL_SEND_FWUPDATE = 14,
        NVDIMM_INTEL_FINISH_FWUPDATE = 15,
        NVDIMM_INTEL_QUERY_FWUPDATE = 16,
        NVDIMM_INTEL_SET_THRESHOLD = 17,
        NVDIMM_INTEL_INJECT_ERROR = 18,
        NVDIMM_INTEL_GET_SECURITY_STATE = 19,
        NVDIMM_INTEL_SET_PASSPHRASE = 20,
        NVDIMM_INTEL_DISABLE_PASSPHRASE = 21,
        NVDIMM_INTEL_UNLOCK_UNIT = 22,
        NVDIMM_INTEL_FREEZE_LOCK = 23,
        NVDIMM_INTEL_SECURE_ERASE = 24,
        NVDIMM_INTEL_OVERWRITE = 25,
        NVDIMM_INTEL_QUERY_OVERWRITE = 26,
        NVDIMM_INTEL_SET_MASTER_PASSPHRASE = 27,
        NVDIMM_INTEL_MASTER_SECURE_ERASE = 28,
};

typedef __signed__ char __s8;
typedef unsigned char __u8;
typedef __signed__ short __s16;
typedef unsigned short __u16;
typedef __signed__ int __s32;
typedef unsigned int __u32;
typedef __signed__ long __s64;
typedef unsigned long __u64;

struct nd_cmd_clear_error {
	__u64 address;
	__u64 length;
	__u32 status;
	__u8 reserved[4];
	__u64 cleared;
} __packed;

struct nd_cmd_ars_status {
        __u32 status;
        __u32 out_length;
        __u64 address;
        __u64 length;
        __u64 restart_address;
        __u64 restart_length;
        __u16 type;
        __u16 flags;
        __u32 num_records;
        struct nd_ars_record {
                __u32 handle;
                __u32 reserved;
                __u64 err_address;
                __u64 length;
        } records[1000];
};

struct nd_cmd_ars_start {
        __u64 address;
        __u64 length;
        __u16 type;
        __u8 flags;
        __u8 reserved[5];
        __u32 status;
        __u32 scrub_time;
};

struct nd_cmd_pkg {
        __u64   nd_family;              /* family of commands */
        __u64   nd_command;
        __u32   nd_size_in;             /* INPUT: size of input args */
        __u32   nd_size_out;            /* INPUT: size of payload */
        __u32   nd_reserved2[9];        /* reserved must be zero */
        __u32   nd_fw_size;             /* OUTPUT: size fw wants to return */
        unsigned char nd_payload[32];   /* Contents of call */
};

struct ars_error_inject {
	__u64	base;
	__u64	length;
	unsigned char option;
};

struct ars_error_inject_clear {
	__u64	base;
	__u64	length;
};

struct nd_translate_spa {
	__u64	spa;
};

struct nd_intel_error_inject {
	__u64	flags;
	__u64	field;
};

int main(int argc, char **argv)
{
	int cmd;
	int fd, fd2, ret;
	struct nd_cmd_clear_error clear_error = {};
	struct nd_cmd_ars_status *ars_status = (struct nd_cmd_ars_status *)malloc(2*1024*1024);
	struct nd_cmd_ars_start ars_start = {};
	struct nd_cmd_pkg cmd_pkg = {};

	fd = open("/dev/ndctl0", O_RDWR, 0666);
	printf("fd: %d\n", fd);
	fd2 = open("/dev/nmem0", O_RDWR, 0666);
	printf("fd2: %d\n", fd2);

	cmd = strtoul(argv[1], NULL, 0);

	if (cmd == 2) { /* Start ARS */
		ars_start.address =  0x840000000;
		ars_start.length =  0x3f00000000;
		ars_start.type = 2;
		ars_start.flags = 2;
		printf("ars_start: %p\n", &ars_start);
		ret = ioctl(fd, ND_CMD_ARS_START, &ars_start);
		printf("ret: %d\n", ret);
		printf("ars_start.status: %lx\n", ars_start.status);
		printf("ars_start.scrub_time: %lx\n", ars_start.scrub_time);
	} else if (cmd == 4 && argc == 4) { /* Clear Error (on given range */
		clear_error.address = strtoul(argv[2], NULL, 0);
		clear_error.length = strtoul(argv[3], NULL, 0);
		printf("calling clear_error method for sector [0x%lx, 0x%lx)\n", clear_error.address, clear_error.address + clear_error.length);
		ret = ioctl(fd, ND_CMD_CLEAR_ERROR, &clear_error);
		printf("ret: %d\n", ret);
		printf("clear_error.status: %lx\n", clear_error.status);
		printf("clear_error.cleared: %lx\n", clear_error.cleared);
	} else if (cmd == 3 || cmd == 4) { /* Query ARS Status */
		ars_status->out_length = 72;
		printf("ars_status: %p\n", ars_status);
		ret = ioctl(fd, ND_CMD_ARS_STATUS, ars_status);
		printf("ret: %d\n", ret);
		printf("ars_status->status: %lx\n", ars_status->status);
		printf("ars_status->address: %lx\n", ars_status->address);
		printf("ars_status->num_records: %lx\n", ars_status->num_records);
		printf("ars_status->out_length: %lx\n", ars_status->out_length);
		printf("ars_status->records[0].err_address: %lx\n", ars_status->records[0].err_address);
		printf("ars_status->records[0].length: %lx\n", ars_status->records[0].length);
		if (ars_status->num_records > 0 && cmd == 4) { /* Clear Error */
			puts("calling clear_error method...");
			clear_error.address = ars_status->records[0].err_address;
			clear_error.length = ars_status->records[0].length;

			ret = ioctl(fd, ND_CMD_CLEAR_ERROR, &clear_error);
			printf("ret: %d\n", ret);
			printf("clear_error.status: %lx\n", clear_error.status);
			printf("clear_error.cleared: %lx\n", clear_error.cleared);
		}
	} else if (cmd == 5) { /* Translate SPA */
		struct nd_translate_spa spa = {
			.spa = 0x840000000,
		};
		if (argc > 2)
			spa.spa = strtoul(argv[2], NULL, 0);
		cmd_pkg.nd_family = 0; /* NVDIMM_FAMILY_INTEL */
		cmd_pkg.nd_command = NFIT_CMD_TRANSLATE_SPA;
		cmd_pkg.nd_size_in = 8;
		cmd_pkg.nd_size_out = 36;
		memcpy(cmd_pkg.nd_payload, &spa, 8);
		ret = ioctl(fd, ND_CMD_CALL, &cmd_pkg);
		printf("ret: %d\n", ret);
		return ret;
	} else if (cmd == 7) { /* ARS Error inject */
		struct ars_error_inject inject = {
			.base = 0x840000000,
			.length = 0x3f00000000,
			.option = 1,
		};
		if (argc > 2)
			inject.base = strtoul(argv[2], NULL, 0);
		if (argc > 3)
			inject.length = strtoul(argv[3], NULL, 0);
		cmd_pkg.nd_family = 0; /* NVDIMM_FAMILY_INTEL */
		cmd_pkg.nd_command = NFIT_CMD_ARS_INJECT_SET;
		cmd_pkg.nd_size_in = 17;
		cmd_pkg.nd_size_out = 4;
		memcpy(cmd_pkg.nd_payload, &inject, 17);
		ret = ioctl(fd, ND_CMD_CALL, &cmd_pkg);
		printf("ret: %d\n", ret);
	} else if (cmd == 8) { /* ARS Error Inject Clear */
		struct ars_error_inject_clear inject_clear = {
			.base = 0x840000000,
			.length = 0x3f00000000,
		};
		if (argc > 2)
			inject_clear.base = strtoul(argv[2], NULL, 0);
		if (argc > 3)
			inject_clear.length = strtoul(argv[3], NULL, 0);
		cmd_pkg.nd_family = 0; /* NVDIMM_FAMILY_INTEL */
		cmd_pkg.nd_command = NFIT_CMD_ARS_INJECT_CLEAR;
		cmd_pkg.nd_size_in = 16;
		cmd_pkg.nd_size_out = 4;
		memcpy(cmd_pkg.nd_payload, &inject_clear, 16);
		ret = ioctl(fd, ND_CMD_CALL, &cmd_pkg);
		printf("ret: %d\n", ret);
	} else if (cmd == 9) { /* ARS Error Inject Status Query */
		cmd_pkg.nd_family = 0; /* NVDIMM_FAMILY_INTEL */
		cmd_pkg.nd_command = NFIT_CMD_ARS_INJECT_GET;
		cmd_pkg.nd_size_in = 0;
		cmd_pkg.nd_size_out = 32;
		ret = ioctl(fd, ND_CMD_CALL, &cmd_pkg);
		printf("ret: %d\n", ret);
	} else if (cmd == 18) { /* .. */
		struct nd_intel_error_inject intel_error = {
			.flags = 0x8, /* dirty shutdown error */
		};
		intel_error.field = (1UL << 48); // enable
		/* cmd_pkg.nd_family = 0; /\* NVDIMM_FAMILY_INTEL *\/ */
		/* cmd_pkg.nd_command = NVDIMM_INTEL_INJECT_ERROR; */
		/* cmd_pkg.nd_size_in = 16; */
		/* cmd_pkg.nd_size_out = 4; */
		ret = ioctl(fd2, NVDIMM_INTEL_INJECT_ERROR, &intel_error);
		/* ret = ioctl(fd2, ND_CMD_CALL, &cmd_pkg); */
		printf("ret: %d\n", ret);
	}
	system("dmesg | tail -n 30");
}
