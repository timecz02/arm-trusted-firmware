/*
 * Copyright (c) 2015-2018, Renesas Electronics Corporation. All rights reserved.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include <arch.h>
#include <asm_macros.S>
#include "scif.h"

/* Product Register */
#define	PRR			(0xFFF00044)
#define PRR_PRODUCT_MASK	(0x00007F00)
#define PRR_CUT_MASK		(0x000000FF)
#define	PRR_PRODUCT_H3_ES_1_0	(0x00004F00)	/* R-Car H3 ES1.0 */
#define	PRR_PRODUCT_E3		(0x00005700)	/* R-Car E3 */

/* module stop */
#define	CPG_BASE		(0xE6150000)
#define	CPG_SMSTPCR3		(0x013C)
#define CPG_MSTPSR3		(0x0048)
#define	MSTP310			(1 << 10)
#define	CPG_CPGWPR		(0x0900)

/* SCIF2 */
#define	SCIF2_BASE		(0xE6E88000)	/* SCIF-2 base address */

#define	SCIF_SCSMR		(0x00)		/* Serial mode register */
#define	SCIF_SCBRR		(0x04)		/* Bit rate register */
#define	SCIF_SCSCR		(0x08)		/* Serial control register */
#define	SCIF_SCFTDR		(0x0C)		/* Transmit FIFO data register */
#define	SCIF_SCFSR		(0x10)		/* Serial status register */
#define SCIF_SCFRDR		(0x14)		/* Receive FIFO data register */
#define	SCIF_SCFCR		(0x18)		/* FIFO control register */
#define	SCIF_SCFDR		(0x1C)		/* FIFO data count register */
#define SCIF_SCSPTR		(0x20)		/* Serial port register */
#define	SCIF_SCLSR		(0x24)		/* Line status register */
#define	SCIF_DL			(0x30)		/* Frequency division register */
#define	SCIF_CKS		(0x34)		/* Clock Select register */

/* mode pin */
#define	RST_MODEMR		(0xE6160060)
#define	MODEMR_MD12		(0x00001000)	/* MD12 bit mask */

#define	SCSMR_CA_MASK		(1 << 7)
#define	SCSMR_CA_ASYNC		(0x0000)
#define	SCSMR_CHR_MASK		(1 << 6)
#define	SCSMR_CHR_8		(0x0000)
#define	SCSMR_PE_MASK		(1 << 5)
#define	SCSMR_PE_DIS		(0x0000)
#define	SCSMR_STOP_MASK		(1 << 3)
#define	SCSMR_STOP_1		(0x0000)
#define	SCSMR_CKS_MASK		(3 << 0)
#define	SCSMR_CKS_DIV1		(0x0000)
#define	SCSMR_INIT_DATA		(SCSMR_CA_ASYNC + SCSMR_CHR_8 + \
				SCSMR_PE_DIS + SCSMR_STOP_1 + \
				SCSMR_CKS_DIV1)

#define	SCBRR_115200BPS		(17)		/* 115200bps@66MHz */
#define	SCBRR_115200BPS_E3_SSCG	(15)		/* 115200bps@60MHz SSCG */
#define	SCBRR_230400BPS		(8)		/* 230400bps@66MHz */

#define	SCSCR_TE_MASK		(1 << 5)
#define	SCSCR_TE_DIS		(0x0000)
#define	SCSCR_TE_EN		(0x0020)
#define	SCSCR_RE_MASK		(1 << 4)
#define	SCSCR_RE_DIS		(0x0000)
#define	SCSCR_RE_EN		(0x0010)
#define	SCSCR_CKE_MASK		(3 << 0)
#define SCSCR_CKE_INT		(0x0000)
#define SCSCR_CKE_BRG		(0x0002)
#if SCIF_CLK == SCIF_EXTARNAL_CLK
#define	SCSCR_CKE_INT_CLK	(SCSCR_CKE_BRG)
#else
#define	SCSCR_CKE_INT_CLK	(SCSCR_CKE_INT)
#endif

#define	SCFSR_INIT_DATA		(0x0000)

#define	SCFCR_TTRG_MASK		(3 << 4)
#define	SCFCR_TTRG_8		(0x0000)
#define	SCFCR_TTRG_0		(0x0030)
#define	SCFCR_TFRST_MASK	(1 << 2)
#define	SCFCR_TFRST_DIS		(0x0000)
#define	SCFCR_TFRST_EN		(0x0004)
#define	SCFCR_RFRS_MASK		(1 << 1)
#define	SCFCR_RFRS_DIS		(0x0000)
#define	SCFCR_RFRS_EN		(0x0002)
#define	SCFCR_INIT_DATA		(SCFCR_TTRG_8)

#define SCFDR_T_MASK		(0x1f << 8)

#define	DL_INIT_DATA		(8)		/* 14.7456MHz/(115200bps*16)*/
			
#define	CKS_CKS_DIV_MASK		(1 << 15)
#define	CKS_CKS_DIV_CLK		(0x0000)
#define	CKS_XIN_MASK		(1 << 14)
#define	CKS_XIN_SCIF_CLK		(0x0000)
#define	CKS_INIT_DATA		(CKS_CKS_DIV_CLK + CKS_XIN_SCIF_CLK)

	.globl	console_init
	.globl	console_putc
	.globl	console_core_init
	.globl	console_core_putc
	.globl	console_getc
	.globl	console_flush

	/*
	 *  The console base is in the data section and not in .bss
	 *  even though it is zero-init. In particular, this allows
	 *  the console functions to start using this variable before
	 *  the runtime memory is initialized for images which do not
	 *  need to copy the .data section from ROM to RAM.
	 */
	/* -----------------------------------------------
	 * int console_init(unsigned long base_addr,
	 * unsigned int uart_clk, unsigned int baud_rate)
	 * Function to initialize the console without a
	 * C Runtime to print debug information. It saves
	 * the console base to the data section.
	 * In: x0 - console base address
	 *     w1 - Uart clock in Hz
	 *     w2 - Baud rate
	 * out: return 1 on success.
	 * Clobber list : x1 - x3
	 * -----------------------------------------------
	 */
func console_init
	b	console_core_init
endfunc console_init

	/* -----------------------------------------------
	 * int console_core_init(unsigned long base_addr,
	 * unsigned int uart_clk, unsigned int baud_rate)
	 * Function to initialize the console without a
	 * C Runtime to print debug information. This
	 * function will be accessed by console_init and
	 * crash reporting.
	 * In: x0 - console base address
	 *     w1 - Uart clock in Hz
	 *     w2 - Baud rate
	 * Out: return 1 on success
	 * Clobber list : x1, x2
	 * -----------------------------------------------
	 */
func console_core_init
	ldr	x0, =CPG_BASE
	ldr	w1, [x0, #CPG_SMSTPCR3]
	and	w1, w1, #~MSTP310		/* MSTP310=0 */
	mvn	w2, w1
	str	w2, [x0, #CPG_CPGWPR]
	str	w1, [x0, #CPG_SMSTPCR3]
5:
	ldr w1, [x0, #CPG_MSTPSR3]
	and w1, w1, #MSTP310
	cbnz w1, 5b

	ldr	x0, =SCIF2_BASE
	/* Clear bits TE and RE in SCSCR to 0 */
	mov	w1, #(SCSCR_TE_DIS + SCSCR_RE_DIS)	/* TE=0,RE=0 */
	strh	w1, [x0, #SCIF_SCSCR]
	/* Set bits TFRST and RFRST in SCFCR to 1 */
	ldrh	w1, [x0, #SCIF_SCFCR]
	orr	w1, w1, #(SCFCR_TFRST_EN + SCFCR_RFRS_EN)	/* TFRESET=1,RFRESET=1 */
	strh	w1, [x0, #SCIF_SCFCR]
	/* Read flags of ER, DR, BRK, and RDF in SCFSR and those of TO and ORER in SCLSR, then clear them to 0 */
	mov	w1, #SCFSR_INIT_DATA
	strh	w1, [x0, #SCIF_SCFSR]
	mov	w1, #0
	strh	w1, [x0, #SCIF_SCLSR]
	/* Set bits CKE[1:0] in SCSCR */
	ldrh	w1, [x0, #SCIF_SCSCR]
	and	w1, w1, #~SCSCR_CKE_MASK
	mov	w2, #SCSCR_CKE_INT_CLK		/* CKE=00 */
	orr	w1, w1, w2
	strh	w1, [x0, #SCIF_SCSCR]
	/* Set data transfer format in SCSMR */
	mov	w1, #SCSMR_INIT_DATA
	strh	w1, [x0, #SCIF_SCSMR]		/* CA=0,CHR=0,PE=0,STOP=0,CKS=P */
	/* Set value in SCBRR */
#if SCIF_CLK == SCIF_INTERNAL_CLK
	ldr	x1, =PRR
	ldr	w1, [x1]
	and	w1, w1, #(PRR_PRODUCT_MASK | PRR_CUT_MASK)
	mov	w2, #PRR_PRODUCT_H3_ES_1_0
	cmp	w1, w2
	beq	3f
	and	w1, w1, #PRR_PRODUCT_MASK
	mov	w2, #PRR_PRODUCT_E3
	cmp	w1, w2
	bne	4f

	ldr	x1, =RST_MODEMR
	ldr	w1, [x1]
	and	w1, w1, #MODEMR_MD12
	mov	w2, #MODEMR_MD12
	cmp	w1, w2
	bne	4f

	mov	w1, #SCBRR_115200BPS_E3_SSCG	/* 115200bps@60MHz SSCG */
	b	2f
4:
	mov	w1, #SCBRR_115200BPS	/* 115200bps */
	b	2f
3:
	mov	w1, #SCBRR_230400BPS	/* H3 ES1.0 sets clock to doubling */
2:
	strb	w1, [x0, SCIF_SCBRR]
#else
	mov	w1, #DL_INIT_DATA
	strh	w1, [x0, #SCIF_DL]
	mov	w1, #CKS_INIT_DATA		/* CKS=0,XIN=0 */
	strh	w1, [x0, #SCIF_CKS]
#endif
	/* 1-bit interval elapsed */
	mov	w1, #100			/* 100 times */
1:
	subs	w1, w1, #1
	cbnz	w1, 1b
	/* Set bits RTRG[1:0], TTRG[1:0], and MCE in SCFCR, and clear bits FRST and RFRST to 0 */
	mov	w1, #SCFCR_INIT_DATA
	strh	w1, [x0, #SCIF_SCFCR]
	/* Set bits TE and RE in SCSCR to 1 */
	ldrh	w1, [x0, #SCIF_SCSCR]
	orr	w1, w1, #(SCSCR_TE_EN + SCSCR_RE_EN)	/* TE=1,RE=1 */
	strh	w1, [x0, #SCIF_SCSCR]
	mov	x0, #1

	ret
endfunc console_core_init

	/* ---------------------------------------------
	 * int console_putc(int c)
	 * Function to output a character over the
	 * console. It returns the character printed on
	 * success or -1 on error.
	 * In : x0 - character to be printed
	 * Out : return -1 on error else return character.
	 * Clobber list : x1, x2
	 * ---------------------------------------------
	 */
func console_putc
	b	console_core_putc
endfunc console_putc

	/* --------------------------------------------------------
	 * int console_core_putc(int c, unsigned int base_addr)
	 * Function to output a character over the console. It
	 * returns the character printed on success or -1 on error.
	 * In : w0 - character to be printed
	 *      x1 - console base address
	 * Out : return -1 on error else return character.
	 * Clobber list : x2
	 * --------------------------------------------------------
	 */
func console_core_putc
	ldr	x1, =SCIF2_BASE
	cmp	w0, #0xA
	/* Prepend '\r' to '\n' */
	bne	2f
1:
	/* Check if the transmit FIFO is full */
	ldrh	w2, [x1, #SCIF_SCFDR]
	ubfx	w2, w2, #8, #5
	cmp	w2, #16
	bcs	1b
	mov	w2, #0x0D
	strb	w2, [x1, #SCIF_SCFTDR]
2:
	/* Check if the transmit FIFO is full */
	ldrh	w2, [x1, #SCIF_SCFDR]
	ubfx	w2, w2, #8, #5
	cmp	w2, #16
	bcs	2b
	strb	w0, [x1, #SCIF_SCFTDR]

	ret
endfunc console_core_putc

	/* ---------------------------------------------
	 * int console_getc(void)
	 * Function to get a character from the console.
	 * It returns the character grabbed on success
	 * or -1 on error.
	 * Clobber list : x0, x1
	 * ---------------------------------------------
	 */
func console_getc
	mov	w0, #-1			/* no support */
	ret
endfunc console_getc

	/* ---------------------------------------------
	 * int console_flush(void)
	 * Function to force a write of all buffered
	 * data that hasn't been output. It returns 0
	 * upon successful completion, otherwise it
	 * returns -1.
	 * Clobber list : x0, x1
	 * ---------------------------------------------
	 */
func console_flush
	ldr	x0, =SCIF2_BASE
1:
	ldrh	w1, [x0, #SCIF_SCFDR]
	ubfx	w1, w1, #8, #5
	cmp	w1, #0
	bne	1b

	mov x0, #100
	mov x3, x30
	bl micro_wait
	mov x30, x3

	ldr	x0, =SCIF2_BASE
	ldrh	w1, [x0, #SCIF_SCSCR]
	and	w1, w1, #~(SCSCR_TE_EN + SCSCR_RE_EN)	/* TE=0,RE=0 */
	strh	w1, [x0, #SCIF_SCSCR]

	mov	w0, #0
	ret
endfunc console_flush

