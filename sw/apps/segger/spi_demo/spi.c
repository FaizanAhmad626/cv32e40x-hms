/*
 * spi.c - polled driver for spi_peripheral on the HMS SoC
 *
 * Every byte written to SPI_DATA becomes one 8-clock frame, and the byte
 * clocked in during that frame lands in the RX FIFO. So a read is always a
 * write: to receive, send a dummy byte and keep what comes back.
 */
#include "spi.h"

void spi_wait_idle(void)
{
    while (!(SPI_STATUS & SPI_ST_IDLE)) {
        /* wait for the TX FIFO to drain and the last frame to finish */
    }
}

void spi_init(unsigned int mode, unsigned int clkdiv)
{
    spi_wait_idle();                    /* never change settings mid-frame */
    SPI_CS     = 0u;                    /* release CS before CPOL moves SCLK */
    SPI_CTRL   = mode & 3u;             /* bit 0 CPHA, bit 1 CPOL */
    SPI_CLKDIV = clkdiv;                /* values below 4 act as 4 */
    SPI_IRQ_EN = 0u;

    while (SPI_STATUS & SPI_ST_RX_VALID)
        (void)SPI_DATA;                 /* drop stale bytes from a previous user */
    SPI_STATUS = SPI_ST_OVERRUN;
}

void spi_select(void)
{
    SPI_CS = 1u;                        /* drives spi_cs_no low */
}

void spi_deselect(void)
{
    spi_wait_idle();                    /* CS must stay low until the last bit is out */
    SPI_CS = 0u;
}

unsigned char spi_xfer(unsigned char b)
{
    while (SPI_STATUS & SPI_ST_TX_FULL) {
        /* wait for room */
    }
    SPI_DATA = b;
    while (!(SPI_STATUS & SPI_ST_RX_VALID)) {
        /* wait for the byte clocked in during this frame */
    }
    return (unsigned char)(SPI_DATA & 0xFFu);
}

/*
 * Full-duplex block transfer. Keeps both FIFOs busy, but never has more
 * than SPI_FIFO_DEPTH bytes in flight, so the RX FIFO cannot overrun.
 * tx == 0 sends 0xFF dummies; rx == 0 discards what comes back.
 */
void spi_xfer_buf(const unsigned char *tx, unsigned char *rx, unsigned int n)
{
    unsigned int sent = 0u;
    unsigned int got  = 0u;

    while (got < n) {
        if (sent < n && (sent - got) < SPI_FIFO_DEPTH &&
            !(SPI_STATUS & SPI_ST_TX_FULL)) {
            SPI_DATA = tx ? tx[sent] : 0xFFu;
            sent++;
        }
        if (SPI_STATUS & SPI_ST_RX_VALID) {
            unsigned char b = (unsigned char)(SPI_DATA & 0xFFu);
            if (rx)
                rx[got] = b;
            got++;
        }
    }
}
