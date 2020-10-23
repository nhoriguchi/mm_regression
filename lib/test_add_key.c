#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

#include <sys/types.h>
#include <keyutils.h>

#define err(x) perror(x),exit(EXIT_FAILURE)

int main() {
	int ret;

	printf("calling keyctl(2)\n");
	ret = keyctl(KEYCTL_JOIN_SESSION_KEYRING, NULL);
	if (ret < 0) {
		err("keyctl");
	}

	printf("calling add_key(2)\n");
	char *payload = "update";
	ret = add_key("trusted", "desc", payload, strlen(payload), KEY_SPEC_SESSION_KEYRING);
	if (ret < 0) {
		err("add_key");
	}

	printf("OK\n");
}
