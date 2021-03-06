/*
 * Copyright (c) 2013-2014, ARM Limited and Contributors. All rights reserved.
 * Copyright (c) 2015-2018, Renesas Electronics Corporation. All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include <arch.h>
#include <asm_macros.S>
#include <bl_common.h>
#include <cortex_a57.h>
#include <platform_def.h>
#include <runtime_svc.h>
#include "rcar_def.h"


	.globl	platform_get_entrypoint
	.globl	plat_secondary_cold_boot_setup
	.globl	platform_mem_init
	.globl	plat_report_exception
	.globl	platform_is_primary_cpu
	.globl	plat_crash_console_init
	.globl	plat_crash_console_putc
	.globl	plat_reset_handler
	.globl	iciallu
	.globl	bl31_secondly_reset

	.extern	platform_set_stack
	.extern	rcar_log_init
	.extern	tf_printf
#if IMAGE_BL2
	.extern bl2_swdt_exec
	.extern gicv2_acknowledge_interrupt
	.extern bl2_interrupt_error_type
	.extern bl2_interrupt_error_id

#define	INT_ID_MASK	(0x3ff)
#endif

	.extern	rcar_boot_kind_flag[data]

.section	.rodata.errorlog,	"aS"
error_log_data:
	.asciz	"[Error log is in plat_secondary_cold_setup]",""

	/* -----------------------------------------------------
	 * void plat_secondary_cold_boot_setup (void);
	 *
	 * This function performs log output from the address of
	 * error_log_data and go to cb_panic.
	 * -----------------------------------------------------
	 */
func plat_secondary_cold_boot_setup
	/*
	 * If timer is enabled, do not clear the freq register
	 */
	mrs	x0, CNTP_CTL_EL0
	mov	x1, #1
	and	x2, x0, x1
	cbnz	x2, log_output		/* timer is enabled			*/
	/*
	 * Timer is disabled, then clear the freq register
	 */
	mov	x0, #0
	msr	CNTFRQ_EL0, x0
log_output:
	bl	platform_set_stack	/* set stack pointer			*/
	bl	rcar_log_init		/* log area initialize			*/
	ldr	x0, =error_log_data	/* argument of tf_printf function	*/
	bl	tf_printf		/* log output				*/
cb_panic:
	b	cb_panic
endfunc plat_secondary_cold_boot_setup


	/* -----------------------------------------------------
	 * void platform_get_entrypoint (unsigned int mpid);
	 *
	 * Main job of this routine is to distinguish between
	 * a cold and warm boot.
	 * On a cold boot the secondaries first wait for the
	 * platform to be initialized after which they are
	 * hotplugged in. The primary proceeds to perform the
	 * platform initialization.
	 * On a warm boot, each cpu jumps to the address in its
	 * mailbox.
	 *
	 * TODO: Not a good idea to save lr in a temp reg
	 * -----------------------------------------------------
	 */
func platform_get_entrypoint
	mov	x9, x30 /* lr */

	/*
	 * format of x21
	 *	4	3	2	1	0
	 *	---------------------------------
	 *	|	|	|	|	|
	 *	|   reset info	|   boot kind	|
	 *	|	|	|	|	|
	 *	---------------------------------
	 *	00 : Usual	| 00 : Cold boot
	 *	01 : Unusual	| 01 : Warm boot
	 *	10 : Reserved	| 10 : Reserved
	 *	11 : Reserved	| 11 : Reserved
	 *
	 */

	/*
	 * Check the reset info
	 */
	and	x1, x21, #0x000c	/* Get the reset info				*/
	cmp	x1, #0x0008		/* Is reset info "10:Reserved" ?		*/
	beq	el3_panic
	cmp	x1, #0x000c		/* Is reset info "11:Reserved" ?		*/
	beq	el3_panic
	/*										*/
	/* Check the boot kind								*/
	/*										*/
	and	x1, x21, #0x0003	/* Get the boot kind				*/
	cmp	x1, #0x0002		/* Is boot kind "10:Reserved" ?			*/
	beq	el3_panic
	cmp	x1, #0x0003		/* Is boot kind "11:Reserved" ?			*/
	beq	el3_panic
	/*										*/
	/* warm boot or cold boot							*/
	/*										*/
	and	x1, x21, #1		/* warm boot ?					*/
	cmp	x1, #0			/* If x1 is 0 then cold boot			*/
	bne	warm_reset		/* bit0 of x1 is 1 then warm boot		*/
	/*										*/
	/* Cold boot									*/
	/*										*/
	mov	x0, #0
	b	exit

warm_reset:
	/* ---------------------------------------------
	 * A per-cpu mailbox is maintained in the tru-
	 * sted SDRAM. Its flushed out of the caches
	 * after every update using normal memory so
	 * its safe to read it here with SO attributes
	 * ---------------------------------------------
	 */
	ldr	x10, =MBOX_BASE		/* top of mailbox address -> x10		*/
	bl	platform_get_core_pos	/* restore cpu no to x0 as CA53=0-3, CA57=4-7	*/
	lsl	x0, x0, #CACHE_WRITEBACK_SHIFT	/* 6bit left shift			*/
					/* because mailbox size is 0x40 byte per cpu	*/
	ldr	x0, [x10, x0]		/* top address of mailbox is entrypoint		*/
	cbz	x0, _panic		/* If warm boot and entrypoint is 0 then panic	*/
exit:
	ret	x9
_panic:	b	_panic
endfunc platform_get_entrypoint


	/* -----------------------------------------------------
	 * void platform_mem_init (void);
	 *
	 * Zero out the mailbox registers in the shared memory
	 * and set the rcar_boot_kind_flag.
	 * The mmu is turned off right now and only the primary can
	 * ever execute this code. Secondaries will read the
	 * mailboxes using SO accesses.
	 * -----------------------------------------------------
	 */
func platform_mem_init
	ldr	x0, =MBOX_BASE
	mov	w1, #PLATFORM_CORE_COUNT
loop:
	str	xzr, [x0], #CACHE_WRITEBACK_GRANULE
	subs	w1, w1, #1
	b.gt	loop
	/* for R-Car Gen3		*/
	ldr	x0, =rcar_boot_kind_flag
	str	w21, [x0]
	ret
endfunc platform_mem_init

	/* ---------------------------------------------
	 * void plat_report_exception(unsigned int type)
	 * Function to report an unhandled exception
	 * with platform-specific means.
	 * ---------------------------------------------
	 */
func plat_report_exception
	mrs	x1, CurrentEl

	str	w0, [x1]
#if IMAGE_BL2
	mov	w1, #FIQ_SP_ELX
	cmp	w0, w1
	beq	rep_exec_fiq_elx
/*
 * Please imprement checking the other type of interrupt
*/
	b	rep_exec_panic_type
rep_exec_fiq_elx:
	bl	gicv2_acknowledge_interrupt
	mov	x2, #INT_ID_MASK
	and	x0, x0, x2
	mov	x1, #ARM_IRQ_SEC_WDT
	cmp	x0, x1
	bne	rep_exec_panic_id
	mrs	x0, ELR_EL1
	b	bl2_swdt_exec
rep_exec_panic_type:	/* interrupt type error	*/
	/* x0 is interrupt TYPE */
	b	bl2_interrupt_error_type
rep_exec_panic_id:	/* interrupt id error	*/
	/* x0 is interrupt ID */
	b	bl2_interrupt_error_id
rep_exec_end:
#endif
	ret
endfunc plat_report_exception


func platform_is_primary_cpu
	and	x0, x0, # MPIDR_CPU_MASK	/* Get the bit7-0 of MPIDR_EL1 -> x0	*/
	cmp	x0, #RCAR_PRIMARY_CPU		/* x0 = 0 (primary CPU)?		*/
	cset	x0, eq				/* If x0 is 0 carry bit set		*/
	ret
endfunc platform_is_primary_cpu


	/* ---------------------------------------------
	 * int plat_crash_console_init(void)
	 * Function to initialize log area
	 * ---------------------------------------------
	 */
func plat_crash_console_init
#if IMAGE_BL2
	mov	x0, #0
#else
	mov	x1, sp
	mov_imm	x2, RCAR_CRASH_STACK
	mov	sp, x2
	str	x1, [sp, #-16]!
	str	x30, [sp, #-16]!
	bl	console_core_init
	ldr	x30, [sp], #16
	ldr	x1, [sp], #16
	mov	sp, x1
#endif
	ret
endfunc plat_crash_console_init

	/* ---------------------------------------------
	 * int plat_crash_console_putc(int c)
	 * Function to store a character to log area
	 * ---------------------------------------------
	 */
func plat_crash_console_putc
	mov	x1, sp
	mov_imm	x2, RCAR_CRASH_STACK
	mov	sp, x2
	str	x1, [sp, #-16]!
	str	x30, [sp, #-16]!
	str	x3, [sp, #-16]!
	str	x4, [sp, #-16]!
	str	x5, [sp, #-16]!
	bl	console_core_putc
	ldr	x5, [sp], #16
	ldr	x4, [sp], #16
	ldr	x3, [sp], #16
	ldr	x30, [sp], #16
	ldr	x1, [sp], #16
	mov	sp, x1
	ret
endfunc plat_crash_console_putc


	/* --------------------------------------------------------------------
	 * void plat_reset_handler(void);
	 *
	 * Before adding code in this function, refer to the guidelines in
	 * docs/firmware-design.md to determine whether the code should reside
	 * within the FIRST_RESET_HANDLER_CALL block or not.
	 *
	 * For R-Car H3:
	 * - Set the L2 Tag RAM latency to 2 (i.e. 3 cycles) for Cortex-A57
	 * - Set the L2 Data setup latency to 1 (i.e. 1 cycles) for Cortex-A57
	 * - Set the L2 Data RAM latency to 3 (i.e. 4 cycles) for Cortex-A57
	 * For R-Car M3/M3N:
	 * - Set the L2 Tag RAM latency to 2 (i.e. 3 cycles) for Cortex-A57
	 * - Set the L2 Data setup latency to 0 (i.e. 0 cycles) for Cortex-A57
	 * - Set the L2 Data RAM latency to 3 (i.e. 4 cycles) for Cortex-A57
	 *
	 * --------------------------------------------------------------------
	 */
func plat_reset_handler
	/* --------------------------------------------------------------------
	 * Determine whether this code is running on R-Car H3 or R-Car M3/M3N.
	 * Keep this information in x2.
	 * --------------------------------------------------------------------
	 */
	/*
	 * On R-Car H3    :  x2 := 0
	 * On R-Car M3/M3N:  x2 := 1
	 */
	ldr	x0, =0xFFF00044	/* read PRR */
	ldr	w0, [x0]
	ubfx	w0, w0, 8, 8
	cmp	w0, #0x4F	/* H3? */
	b.eq	H3
	mov	x2, #1		/* set R-Car M3/M3N */
	b	CHK_A5x
H3:
	mov	x2, #0		/* set R-Car H3 */
	/* --------------------------------------------------------------------
	 * Determine whether this code is executed on a Cortex-A53 or on a
	 * Cortex-A57 core.
	 * --------------------------------------------------------------------
	 */
CHK_A5x:
	mrs	x0, midr_el1
	ubfx	x1, x0, MIDR_PN_SHIFT, #12
	cmp     w1, #((CORTEX_A57_MIDR >> MIDR_PN_SHIFT) & MIDR_PN_MASK)
	b.eq	A57

	ret

A57:
	/* --------------------------------------------------------------------
	 * Cortex-A57 specific settings
	 * --------------------------------------------------------------------
	 */
	mrs	x0, CORTEX_A57_L2CTLR_EL1		/* Get data from CORTEX_A57_L2CTLR_EL1		*/
	/*
	 * On R-Car H3/M3/M3N
	 *
	 * L2 Tag RAM latency is bit8-6 of CORTEX_A57_L2CTLR_EL1
	 * L2 Data RAM setup is bit5 of CORTEX_A57_L2CTLR_EL1
	 * L2 Data RAM latency is bit2-0 of CORTEX_A57_L2CTLR_EL1
	 */
	mov	x1, #0x1e7		/* for clear bit of L2 RAM			*/
	neg	x1, x1			/* ~(0x1e7) -> x1				*/
	and	x0, x0, x1		/* clear bit of L2 RAM -> x0			*/
	orr	x0, x0, #0x2 << 6  	/* L2 Tag RAM latency (3 cycles)		*/
	cbnz	x2, M3_L2		/* If M3/M3N then L2 Data RAM setup is 0	*/
	orr	x0, x0, #0x1 << 5  	/* L2 Data RAM setup (1 cycle)			*/
M3_L2:
	orr	x0, x0, #0x3       		/* L2 Data RAM latency (4 cycles)	*/
	msr	CORTEX_A57_L2CTLR_EL1, x0	/* Store data to L2CTLR_EL1		*/

apply_l2_ram_latencies:

	ret
endfunc plat_reset_handler


	/* ---------------------------------------------
	 * void iciallu(void)
	 * Instruction Cache Invalidate All to PoU
	 * ---------------------------------------------
	 */
func iciallu
	ic	iallu

	ret
endfunc iciallu

func bl31_secondly_reset
	mrs	x0, sctlr_el3
	bic	x0, x0, #SCTLR_EE_BIT
	msr	sctlr_el3, x0
	isb

	mrs	x0, cptr_el3
	bic	w0, w0, #TCPAC_BIT
	bic	w0, w0, #TTA_BIT
	bic	w0, w0, #TFP_BIT
	msr	cptr_el3, x0

	mov_imm	x0, PARAMS_BASE			/* pointer to bl31_ep_info */
	mov_imm	x2, BL31_BASE
	mov x1, #0x00000001			/* warm boot */
	br	x2				/* jump to BL31 */
	nop
	nop
	nop
endfunc bl31_secondly_reset
