	.file	"sum.c"
	.option nopic
	.attribute arch, "rv32i2p1_m2p0_c2p0_zicsr2p0_zifencei2p0_zmmul1p0_zca1p0"
	.attribute unaligned_access, 0
	.attribute stack_align, 16
	.text
	.section	.text.startup,"ax",@progbits
	.align	1
	.globl	main
	.type	main, @function
main:
	addi	sp,sp,-16
	li	a5,35
	sw	a5,12(sp)
	li	a0,0
	addi	sp,sp,16
	jr	ra
	.size	main, .-main
	.ident	"GCC: (g1b306039a) 15.1.0"
	.section	.note.GNU-stack,"",@progbits
