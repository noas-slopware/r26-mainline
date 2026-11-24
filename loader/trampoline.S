/*
 * r26kexec trampoline. Entered from the stock kernel's cpu_v7_reset()
 * with the MMU off and the caches cleaned and disabled
 * (__soft_restart -> flush_cache_all, cpu_proc_fin). ARM state, SVC,
 * IRQs/FIQs masked. Position independent: runs from any physical page.
 *
 * params (right after the code):
 *   +0  entry  physical address of the zImage entry (ARM state)
 *   +4  dtb    physical address of the DTB
 *   +8  list   physical address of the first list page, 0 = none
 *   +12 crumb  physical address of a 16-bit breadcrumb register, 0 = none
 *
 * list page:
 *   +0  next   physical address of the next list page, 0 = last
 *   +4  count  number of entries in this page
 *   +8  count x { dst, src }: copy 4096 bytes from src to dst
 */
	.syntax unified
	.arm
	.text
	.globl	tramp_start
tramp_start:
	adr	r4, .Lparams
	/* breadcrumb (if an address is given): 0x5202 = trampoline entered */
	ldr	r0, [r4, #12]
	cmp	r0, #0
	movwne	r1, #0x5202
	strhne	r1, [r0]
	ldr	r6, [r4, #8]		@ first list page

page_loop:
	cmp	r6, #0
	beq	done
	ldr	r11, [r6, #0]		@ next page
	ldr	r5, [r6, #4]		@ entries here
	add	r12, r6, #8

entry_loop:
	cmp	r5, #0
	beq	next_page
	ldmia	r12!, {r7, r8}		@ dst, src
	mov	r9, #256		@ 256 x 16 bytes = one page
1:	ldmia	r8!, {r0-r3}
	stmia	r7!, {r0-r3}
	subs	r9, r9, #1
	bne	1b
	sub	r5, r5, #1
	b	entry_loop

next_page:
	mov	r6, r11
	b	page_loop

done:
	mov	r10, #0
	mcr	p15, 0, r10, c7, c5, 0	@ ICIALLU
	mcr	p15, 0, r10, c7, c5, 6	@ BPIALL
	dsb
	isb
	ldr	r0, [r4, #12]
	cmp	r0, #0
	movwne	r1, #0x5203		@ breadcrumb: about to enter the kernel
	strhne	r1, [r0]
	ldr	r3, [r4, #0]		@ entry
	ldr	r2, [r4, #4]		@ dtb
	mov	r0, #0
	mvn	r1, #0			@ machine type ~0: DT boot
	bx	r3

	.align	2

.Lparams:
	.word	0, 0, 0, 0
	.globl	tramp_end
tramp_end:
