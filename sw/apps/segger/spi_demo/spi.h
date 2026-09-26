/*
 * spi.h - polled driver for spi_peripheral on the HMS SoC
 *
 * Register map must match fpga/scu35/rtl/spi_peripheral.sv and the
 * SPI_BASE parameter in cv32e40x_wrapper.sv.
 */
#ifndef SPI_H
#define SPI_H

#define SPI_BASE            0x10020000u

#define SPI_DATA            (*(volatile unsigned int *)(SPI_BASE + 0x00u))
#define SPI_STATUS          (*(volatile unsigned int *)(SPI_BASE + 0x04u))
#define SPI_CTRL            (*(volatile unsigned int *)(SPI_BASE + 0x08u))
#define SPI_CLKDIV          (*(volatile unsigned int *)(SPI_BASE + 0x0Cu))
#define SPI_CS              (*(volatile unsigned int *)(SPI_BASE + 0x10u))
#define SPI_IRQ_EN          (*(volatile unsigned int *)(SPI_BASE + 0x14u))

#define SPI_ST_TX_FULL      (1u << 0)
#define SPI_ST_IDLE         (1u << 1)   /* TX FIFO empty and no frame on the wire */
#define SPI_ST_RX_VALID     (1u << 2)
#define SPI_ST_RX_FULL      (1u << 3)
#define SPI_ST_OVERRUN      (1u << 4)   /* sticky, write 1 to clear */

#define SPI_CTRL_CPHA       (1u << 0)
#define SPI_CTRL_CPOL       (1u << 1)

#define SPI_FIFO_DEPTH      16u         /* FIFO_DEPTH in the wrapper */
#define SPI_MIN_CLKDIV      4u          /* MIN_DIV in spi_master.sv */

/* mode 0..3 = CPOL * 2 + CPHA; clkdiv = clk cycles per SCLK half period */
void spi_init(unsigned int mode, unsigned int clkdiv);
void spi_select(void);
void spi_deselect(void);                /* waits for the last frame first */
unsigned char spi_xfer(unsigned char b);
void spi_xfer_buf(const unsigned char *tx, unsigned char *rx, unsigned int n);
void spi_wait_idle(void);

#endif
