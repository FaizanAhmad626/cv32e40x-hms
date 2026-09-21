/*
 * main.c - UART demo for CV32E40X on SCU35
 *
 * 1. Prints a banner and a few register reads at 115200 8N1.
 * 2. Echoes everything typed, and shows the low 4 bits of the last
 *    character on the LEDs, so RX is visible even without a terminal.
 *
 * Host side: open the SECOND serial interface of the FT4232 (port B),
 * 115200 baud, 8N1, no flow control.
 */
#include "uart.h"

#define LED_REG     (*(volatile unsigned char *)0x10000000u)

int main(void)
{
    uart_init(115200u);

    uart_puts("\nHMS CV32E40X on SCU35: UART alive\n");
    uart_puts("BAUDDIV = 0x");
    uart_puthex(UART_BAUDDIV);
    uart_puts("\nSTATUS  = 0x");
    uart_puthex(UART_STATUS);
    //uart_puts("\nType something, it will be echoed.\n> ");

    for (;;) {
        int c = uart_getc();
        LED_REG = (unsigned char)(c & 0x0F);

        if (c == '\r') {
            uart_puts("\n> ");
        } else {
            uart_putc((char)c);
        }

        if (UART_STATUS & (UART_ST_OVERRUN | UART_ST_FRAME_ERR)) {
            uart_puts("\n[rx error, status 0x");
            uart_puthex(UART_STATUS);
            uart_puts("]\n> ");
            UART_STATUS = UART_ST_OVERRUN | UART_ST_FRAME_ERR;
        }
    }

    return 0;   /* not reached */
}