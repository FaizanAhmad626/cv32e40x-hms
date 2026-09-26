/*
 * main.c - SPI loopback demo for CV32E40X on SCU35
 *
 * Needs one jumper on PMOD1 (J13) between silkscreen pins 3 (MOSI) and
 * 5 (MISO): upper row, 2nd and 3rd sockets from the pin-1 end. These are
 * Pmod pins 2 and 3; the board silkscreen numbers the header odd/even
 * across the two rows, so its "pin 2" is on the lower row and is unused.
 *
 * For each SPI mode 0..3, at 1 MHz and at the 6.25 MHz maximum, sends a
 * 16-byte pattern with CS held low and compares what came back on MISO.
 * Results go to the UART (FT4232 port B, 115200 8N1) and to the LEDs:
 * LED[m] lights when mode m passed at both clock rates, LED4 is the
 * heartbeat. Press any key on the terminal to run the test again, for
 * example after fitting or removing the jumper.
 */
#include "uart.h"
#include "spi.h"

#define LED_REG     (*(volatile unsigned char *)0x10000000u)

#define N_BYTES     16u

/* Edge values plus alternating and walking patterns, so a stuck, swapped
 * or shifted bit shows up as a mismatch. */
static const unsigned char pattern[N_BYTES] = {
    0x00, 0xFF, 0xA5, 0x5A, 0x01, 0x80, 0x7E, 0x81,
    0x3C, 0xC3, 0x0F, 0xF0, 0x55, 0xAA, 0x12, 0xED
};

static const unsigned int clkdivs[2] = { 25u, SPI_MIN_CLKDIV };  /* 1 MHz, 6.25 MHz */

static void puthex8(unsigned int v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_putc(hex[(v >> 4) & 0xFu]);
    uart_putc(hex[v & 0xFu]);
}

static void putdec(unsigned int v)
{
    char buf[10];
    int  i = 0;
    do {
        buf[i++] = (char)('0' + v % 10u);
        v /= 10u;
    } while (v != 0u);
    while (i > 0)
        uart_putc(buf[--i]);
}

/* Returns the index of the first mismatching byte, or -1 if all match. */
static int loopback(unsigned int mode, unsigned int clkdiv, unsigned char *rx)
{
    spi_init(mode, clkdiv);
    spi_select();
    spi_xfer_buf(pattern, rx, N_BYTES);
    spi_deselect();

    for (unsigned int i = 0u; i < N_BYTES; i++) {
        if (rx[i] != pattern[i])
            return (int)i;
    }
    return -1;
}

static int all_equal(const unsigned char *rx, unsigned char v)
{
    for (unsigned int i = 0u; i < N_BYTES; i++) {
        if (rx[i] != v)
            return 0;
    }
    return 1;
}

int main(void)
{
    unsigned char rx[N_BYTES];

    uart_init(115200u);
    uart_puts("\nHMS CV32E40X on SCU35: SPI loopback test\n");
    uart_puts("Jumper J13 (PMOD1) silkscreen pin 3 (MOSI) to pin 5 (MISO)\n");

    for (;;) {
        unsigned int leds   = 0u;
        unsigned int passed = 0u;
        unsigned int ff     = 0u;   /* runs where every byte read 0xFF */
        unsigned int zero   = 0u;   /* runs where every byte read 0x00 */

        uart_puts("\n");
        for (unsigned int mode = 0u; mode < 4u; mode++) {
            unsigned int mode_ok = 1u;

            for (unsigned int k = 0u; k < 2u; k++) {
                unsigned int div = clkdivs[k];
                int bad = loopback(mode, div, rx);

                uart_puts("mode ");
                putdec(mode);
                uart_puts("  CLKDIV ");
                putdec(div);
                uart_puts(div < 10u ? "   SCLK " : "  SCLK ");
                putdec(SYS_CLK_HZ / (2u * div) / 1000u);
                uart_puts(" kHz  ");

                if (bad < 0) {
                    uart_puts("PASS\n");
                    passed++;
                } else {
                    uart_puts("FAIL at byte ");
                    putdec((unsigned int)bad);
                    uart_puts(": sent 0x");
                    puthex8(pattern[bad]);
                    uart_puts(", got 0x");
                    puthex8(rx[bad]);
                    uart_puts("\n");
                    mode_ok = 0u;
                    ff   += (unsigned int)all_equal(rx, 0xFFu);
                    zero += (unsigned int)all_equal(rx, 0x00u);
                }
            }
            if (mode_ok)
                leds |= 1u << mode;
        }

        LED_REG = (unsigned char)leds;

        uart_puts("result: ");
        putdec(passed);
        uart_puts(" of 8 passed\n");
        if (ff != 0u)
            uart_puts("every byte read 0xFF: is the jumper on J13 silkscreen pins 3 and 5?\n");
        if (zero != 0u)
            uart_puts("every byte read 0x00: MISO looks shorted to ground\n");

        uart_puts("press any key to run again\n");
        (void)uart_getc();
    }

    return 0;   /* not reached */
}
