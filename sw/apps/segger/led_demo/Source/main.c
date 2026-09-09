/*
 * main.c - LED MMIO demo for CV32E40X on Genesys-2
 *
 * Writes a walking-1 pattern to the LED register at 0x1000_0000.
 * This address must match LED_BASE in the wrapper parameters.
 *
 * led_o[7] is the hardware heartbeat, so the pattern walks bits 6:0 only.
 *
 * No initialized globals and no constants, so .data and .rodata stay empty.
 */

#define LED_ADDR    0x10000000u

/* volatile is required. Without it -O2 deletes stores that nothing reads
   back, and the program compiles to almost nothing. */
#define LED_REG     (*(volatile unsigned char *)LED_ADDR)

/* ~0.25 s at 50 MHz. Tune after the first run. */
#define DELAY_ITERS 2000000u

static void delay(void)
{
    /* volatile stops -O2 deleting the empty loop */
    for (volatile unsigned int i = 0u; i < DELAY_ITERS; i++) {
        /* nothing */
    }
}

int main(void)
{
    unsigned char pattern = 0x01u;

    for (;;) {
        LED_REG = pattern;
        delay();
        pattern = (pattern == 0x40u) ? 0x01u
                                     : (unsigned char)(pattern << 1);
    }

    return 0;   /* not reached */
}