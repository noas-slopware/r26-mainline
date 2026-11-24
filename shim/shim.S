/*
 * r26 boot shim. U-Boot `bootz`s this file as /GustardCore; it carries the
 * stock zImage and a mainline zImage + DTB and picks one per boot from the
 * SoC's reset-cause registers, so every failure path lands on stock:
 *
 *   PM POR reg1 bit0 (0x1F000C04): set by the stock kernel on every soft
 *       reboot (msys_set_rebootType), cleared only by power-on/HW reset.
 *   WDT reg2 bit0 (0x1F006008):    set after a watchdog reset, W1C.
 *
 * Both flags are consumed (cleared) on every boot.
 *
 * mode 0: always stock (installation check)
 * mode 1: mainline only right after a stock soft reboot without a
 *         watchdog reset; anything else (power on, watchdog, mainline's own
 *         reboot) boots stock
 * mode 2: mainline unless the last reset was the watchdog
 *
 * Before mainline the watchdog is armed, so a hang ends in a watchdog reset
 * and therefore in stock. A healthy mainline takes the watchdog over.
 *
 * Entered from U-Boot (or r26kexec) with the MMU and D-cache off,
 * r0 = 0, r1 = machine id, r2 = FDT. ARM state, position independent.
 */
	.syntax unified
	.arm
	.text
	.globl	_start
_start:
.Lbase:
	.rept	8
	mov	r0, r0
	.endr
	b	entry
	.word	0x016f2818		@ 0x24: zImage magic
	.word	0			@ 0x28: start (relative)
	.word	0			@ 0x2c: end = total size, filled by mkshim

	/* 0x30: parameters, filled by mkshim */
p_mode:		.word	0		@ 0x30
p_stock_off:	.word	0		@ 0x34 offset of the stock zImage
p_main_off:	.word	0		@ 0x38 offset of the mainline zImage
p_dtb_off:	.word	0		@ 0x3c offset of the mainline DTB
p_dtb_size:	.word	0		@ 0x40 bytes, multiple of 4
p_dtb_dest:	.word	0		@ 0x44 physical address to copy the DTB to
p_wdt_ticks:	.word	0		@ 0x48 watchdog period in 12 MHz ticks
p_wdt_base:	.word	0		@ 0x4c 0x1F006000, 0 = no SoC registers (sim)
p_pmpor:	.word	0		@ 0x50 0x1F000C04
p_sim_choice:	.word	0		@ 0x54 sim only: 0 stock, 1 mainline

entry:
	mov	r10, r2			@ U-Boot's FDT, for stock
	mov	r9, r1			@ machine id
	adr	r12, .Lbase		@ base of this image

	ldr	r4, p_wdt_base
	cmp	r4, #0
	ldreq	r8, p_sim_choice	@ simulation: decision comes from the header
	beq	decided

	/* read both reset-cause flags */
	ldrh	r5, [r4, #0x08]		@ WDT reg2
	and	r6, r5, #1		@ r6 = watchdog reset
	ldr	r3, p_pmpor
	ldrh	r7, [r3]
	and	r11, r7, #1		@ r11 = stock soft reboot

	/* consume them */
	orr	r5, r5, #1		@ W1C: write bit0 back to clear it
	strh	r5, [r4, #0x08]
	bic	r7, r7, #1
	strh	r7, [r3]

	ldr	r0, p_mode
	mov	r8, #0			@ default: stock
	cmp	r0, #1
	bne	1f
	cmp	r11, #1			@ mode 1: soft reboot and no watchdog
	cmpeq	r6, #0
	moveq	r8, #1
	b	decided
1:	cmp	r0, #2
	bne	decided
	cmp	r6, #0			@ mode 2: anything but a watchdog reset
	moveq	r8, #1

decided:
	cmp	r8, #1
	beq	boot_main

boot_stock:
	ldr	r3, p_stock_off
	add	r3, r12, r3
	mov	r0, #0
	mov	r1, r9
	mov	r2, r10
	bx	r3

boot_main:
	cmp	r4, #0
	beq	2f
	/* arm the watchdog: clear, period high, period low, clear */
	ldr	r0, p_wdt_ticks
	mov	r1, #1
	strh	r1, [r4, #0x00]
	lsr	r2, r0, #16
	strh	r2, [r4, #0x14]
	strh	r0, [r4, #0x10]
	strh	r1, [r4, #0x00]
2:
	/*
	 * Copy the DTB high, out of the way of the kernel's decompression.
	 * The copy runs with the caches off, so another core that still has
	 * its caches on (CPU1 parked by r26kexec) may hold stale lines for
	 * the destination; the decompressor reads it with caches on and would
	 * get those. Invalidate the range by MVA (broadcast to the inner
	 * shareable domain) before and after the copy.
	 */
	ldr	r0, p_dtb_dest
	ldr	r1, p_dtb_size
	bl	.Linval_range
	ldr	r0, p_dtb_off
	add	r0, r12, r0
	ldr	r1, p_dtb_dest
	ldr	r2, p_dtb_size
3:	ldr	r3, [r0], #4
	str	r3, [r1], #4
	subs	r2, r2, #4
	bgt	3b
	ldr	r0, p_dtb_dest
	ldr	r1, p_dtb_size
	bl	.Linval_range

	ldr	r3, p_main_off
	add	r3, r12, r3
	mov	r0, #0
	mvn	r1, #0
	ldr	r2, p_dtb_dest
	bx	r3

/* .Linval_range(r0 = start, r1 = length): DCIMVAC over the range. Clobbers r0-r3. */
.Linval_range:
	mrc	p15, 0, r3, c0, c0, 1	@ CTR
	ubfx	r3, r3, #16, #4		@ DminLine: log2(words per line)
	mov	r2, #4
	lsl	r3, r2, r3		@ line size in bytes
	add	r1, r0, r1		@ end
	sub	r2, r3, #1
	bic	r0, r0, r2
4:	mcr	p15, 0, r0, c7, c6, 1	@ DCIMVAC
	add	r0, r0, r3
	cmp	r0, r1
	blo	4b
	dsb
	bx	lr

	.align	12			@ payloads start on a 4 KiB boundary
	.globl	shim_end
shim_end:
