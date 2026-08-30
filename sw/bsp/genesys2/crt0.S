/*
 * crt0.S - startup code for CV32E40X on Genesys-2
 *
 * Runs before main(). Turns "the core just came out of reset" into
 * "C code is safe to run".
 *
 * Memory map (must match the wrapper parameters and link.ld):
 *   0x8000_0000  boot address, _start goes here
 *   0x8000_0100  trap handler, 128-byte aligned (mtvec[6:2] is hardwired 0)
 *   0x8001_0000  top of memory, stack grows down from here
 *   0x1000_0000  LED register
 */

    .equ LED_ADDR,  0x10000000      /* LED register address                 */
    .equ LED_EXIT,  0x55            /* shown if main() returns              */
    .equ LED_TRAP,  0xAA            /* shown if a trap fires                */


/* ------------------------------------------------------------------------
 * Entry point. link.ld places .text.init first, so _start lands at
 * 0x8000_0000, which is what BOOT_ADDR points the reset PC at.
 * "ax" = allocatable, executable.
 * ------------------------------------------------------------------------ */
    .section .text.init, "ax"
    .global _start
    .type _start, @function

_start:
    csrw    mie, zero               /* disable all interrupts               */
    csrw    mstatus, zero           /* clear global interrupt enable        */

    la      sp, __stack_top         /* stack pointer = top of memory        */

.option push                        /* save current assembler options       */
.option norelax                     /* stop the linker rewriting this to be */
                                    /*   gp-relative, which would be        */
                                    /*   circular since we are setting gp   */
    la      gp, __global_pointer$   /* global pointer for short accesses    */
.option pop                         /* restore assembler options            */

    /* Zero .bss, because C guarantees uninitialized globals start at 0 */
    la      a0, __bss_start         /* a0 = start of .bss                   */
    la      a1, __bss_end           /* a1 = end of .bss                     */
1:  bgeu    a0, a1, 2f              /* if a0 >= a1, done: jump forward to 2 */
    sw      zero, 0(a0)             /* write 0 at a0                        */
    addi    a0, a0, 4               /* advance 4 bytes                      */
    j       1b                      /* jump back to 1                       */
2:

    la      t0, trap_handler        /* t0 = handler address (128B aligned)  */
    csrw    mtvec, t0               /* low bits are 0, so MODE = direct     */

    li      a0, 0                   /* argc = 0, no command line here       */
    li      a1, 0                   /* argv = NULL                          */
    call    main                    /* run the program                      */

    /* main() returned. There is nothing to return to, so show 0x55 and stop. */
    li      t0, LED_ADDR
    li      t1, LED_EXIT
    sb      t1, 0(t0)
3:  j       3b                      /* spin forever                         */

    .size _start, . - _start


/* ------------------------------------------------------------------------
 * Trap handler. Reached on illegal instruction, bus error, misaligned
 * access, or ecall. Shows 0xAA and stops.
 *
 * Its own section so link.ld can pin it to 0x8000_0100. The .align 7
 * (2^7 = 128 bytes) is mandatory: CV32E40X hardwires mtvec[6:2] to zero,
 * so a csrw of a less-aligned address silently rounds down.
 * ------------------------------------------------------------------------ */
    .section .text.trap, "ax"
    .align 7
    .global trap_handler
    .type trap_handler, @function

trap_handler:
    li      t0, LED_ADDR
    li      t1, LED_TRAP
    sb      t1, 0(t0)
1:  j       1b                      /* spin forever                         */

    .size trap_handler, . - trap_handler
