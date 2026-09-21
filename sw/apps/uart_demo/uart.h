/*
 * uart.h - polled driver for uart_peripheral on the HMS SoC
 *
 * Register map must match fpga/scu35/rtl/uart_peripheral.sv and the
 * UART_BASE parameter in cv32e40x_wrapper.sv.
 */
#ifndef UART_H
#define UART_H

#define UART_BASE           0x10010000u

#define UART_DATA           (*(volatile unsigned int *)(UART_BASE + 0x00u))
#define UART_STATUS         (*(volatile unsigned int *)(UART_BASE + 0x04u))
#define UART_BAUDDIV        (*(volatile unsigned int *)(UART_BASE + 0x08u))
#define UART_IRQ_EN         (*(volatile unsigned int *)(UART_BASE + 0x0Cu))

#define UART_ST_TX_FULL     (1u << 0)
#define UART_ST_TX_IDLE     (1u << 1)
#define UART_ST_RX_VALID    (1u << 2)
#define UART_ST_RX_FULL     (1u << 3)
#define UART_ST_OVERRUN     (1u << 4)   /* sticky, write 1 to clear */
#define UART_ST_FRAME_ERR   (1u << 5)   /* sticky, write 1 to clear */

#define SYS_CLK_HZ          50000000u   /* clk_50M_s in the wrapper */

void uart_init(unsigned int baud);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_puthex(unsigned int v);
int  uart_getc(void);               /* blocks */
int  uart_try_getc(void);           /* -1 if nothing waiting */
void uart_flush(void);              /* wait until the last bit is sent */

#endif
