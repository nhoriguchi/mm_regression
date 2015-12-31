	.globl do_memcpy
	.type   do_memcpy, @function
do_memcpy:
	.cfi_startproc
	rep movsq %ds:(%rsi),%es:(%rdi)
	mov    $0x0,%eax
	retq
	.cfi_endproc
	.size   do_memcpy, .-do_memcpy
