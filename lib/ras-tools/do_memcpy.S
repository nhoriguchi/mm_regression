// SPDX-License-Identifier: GPL-2.0

#ifdef __x86_64__
	.globl do_memcpy
	.type   do_memcpy, @function
do_memcpy:
	.cfi_startproc
	mov %edx, %ecx
	rep movsb %ds:(%rsi),%es:(%rdi)
	mov    $0x0,%eax
	retq
	.cfi_endproc
	.size   do_memcpy, .-do_memcpy

#elif __aarch64__
dst	.req	x0
src	.req	x1
count	.req	x2
tmp	.req	w3


	.globl do_memcpy
do_memcpy:
	cbz	count, .Lexit
	ldrb	tmp, [src], #0x1
	strb	tmp, [dst], #0x1
	sub	count, count, #0x1
	b.ge	do_memcpy
.Lexit:
	ret
#endif

