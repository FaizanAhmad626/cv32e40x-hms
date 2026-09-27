/*
 * uart.c - polled driver for uart_peripheral on the HMS SoC
 */
#include "uart.h"

void uart_init(unsigned int baud)
{
    uart_flush();                       /* never retime a frame in flight */
    UART_BAUDDIV = (SYS_CLK_HZ + baud / 2u) / baud;
    UART_IRQ_EN  = 0u;
    UART_STATUS  = UART_ST_OVERRUN | UART_ST_FRAME_ERR;
}

void uart_putc(char c)
{
    while (UART_STATUS & UART_ST_TX_FULL) {
        /* wait for room */
    }
    UART_DATA = (unsigned char)c;
}

void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s++);
    }
}

void uart_puthex(unsigned int v)
{
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xFu]);
}

int uart_try_getc(void)
{
    if (!(UART_STATUS & UART_ST_RX_VALID))
        return -1;
    return (int)(UART_DATA & 0xFFu);
}

int uart_getc(void)
{
    int c;
    while ((c = uart_try_getc()) < 0) {
        /* wait for a byte */
    }
    return c;
}

void uart_flush(void)
{
    while (!(UART_STATUS & UART_ST_TX_IDLE)) {
        /* wait */
    }
}