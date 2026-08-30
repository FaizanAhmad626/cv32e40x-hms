/*
 * link.ld - memory layout for CV32E40X on Genesys-2
 *
 * Must agree with the hardware:
 *   ORIGIN(MEM)  = BOOT_ADDR = MEM_BASE          (wrapper parameters)
 *   LENGTH(MEM)  = MEM_DEPTH * 4                 (16384 words = 64 KB)
 *   trap handler = MT_VEC_ADDR = 0x8000_0100
 *
 * The whole image is preloaded into BRAM by the bitstream, so .data arrives
 * already initialized and needs no startup copy.
 */

OUTPUT_ARCH("riscv")                    /* target architecture              */
ENTRY(_start)                           /* entry symbol, also stops         */
                                        /*   --gc-sections removing it      */

/* The memory the hardware actually has. r=read w=write x=execute */
MEMORY
{
    MEM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}

SECTIONS
{
    /* Code. "." is the location counter, the address being filled. */
    .text : {
        KEEP(*(.text.init))             /* _start first, so it lands at     */
                                        /*   0x8000_0000 = BOOT_ADDR.       */
                                        /*   KEEP: nothing calls it, the    */
                                        /*   hardware jumps to it           */
        . = ALIGN(128);                 /* mtvec[6:2] is hardwired 0, so    */
                                        /*   the handler must be 128B       */
                                        /*   aligned -> 0x8000_0100         */
        KEEP(*(.text.trap))             /* trap_handler, also unreferenced  */
        *(.text .text.*)                /* all other code. .text.* catches  */
                                        /*   -ffunction-sections output     */
        . = ALIGN(4);
    } > MEM                             /* place this section in MEM        */

    /* Read-only data: constants and string literals */
    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)          /* "small" rodata, reached via gp   */
        . = ALIGN(4);
    } > MEM

    /* Globals that have a starting value */
    .data : {
        . = ALIGN(4);
        *(.data .data.*)
        . = ALIGN(4);
        PROVIDE(__global_pointer$ = . + 0x800);
                                        /* one instruction reaches +/-2K    */
                                        /*   from gp, so sit 2K before the  */
                                        /*   small data. crt0.S loads this  */
        *(.sdata .sdata.*)              /* "small" data, reached via gp     */
        . = ALIGN(4);
    } > MEM

    /* Globals with no starting value. NOLOAD = reserve the addresses but
       store nothing in the image; crt0.S writes the zeros at boot. */
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;                /* crt0.S zeroing loop reads these  */
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)                       /* old-style tentative definitions  */
        . = ALIGN(4);
        __bss_end = .;
    } > MEM

    /* Stack grows downward from the top of memory. crt0.S loads this. */
    __stack_top = ORIGIN(MEM) + LENGTH(MEM);

    /* Metadata with no use on bare metal; would only waste BRAM */
    /DISCARD/ : { *(.eh_frame .eh_frame.*) *(.comment) }
}

/* Fail the build if the image outgrew the BRAM. Without this the address
   would be truncated by the bit slice in memory_controller and silently
   wrap onto the code. */
ASSERT(__bss_end <= ORIGIN(MEM) + LENGTH(MEM),
       "Image does not fit in MEM: increase blk_mem_gen_0 depth")
