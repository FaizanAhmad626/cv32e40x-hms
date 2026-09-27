/*
 * i2c.c - polled driver for i2c_peripheral on the HMS SoC
 *
 * The hardware does one step per command: START and/or a byte and/or STOP.
 * Everything here is built from two helpers, put() and get(). On any error
 * the driver issues a STOP (or an ABORT if the bus is stuck), so the bus is
 * always left free for the next call.
 */
#include "i2c.h"

/* Poll iterations before giving up on a single command. One byte at
 * 100 kHz is ~90 us, a few hundred iterations; this allows ~20 ms. */
#define I2C_POLL_LIMIT      100000u

static int wait_done(void)
{
    unsigned int n = I2C_POLL_LIMIT;

    while (I2C_STATUS & I2C_ST_BUSY) {
        if (--n == 0u) {
            I2C_CMD = I2C_CMD_ABORT;    /* release both lines */
            return I2C_ERR_TIMEOUT;
        }
    }
    return I2C_OK;
}

static void stop(void)
{
    I2C_CMD = I2C_CMD_STOP;
    (void)wait_done();
}

/* Send one byte. Returns I2C_OK on ACK, 1 on NACK, or a timeout error. */
static int put(unsigned char b, unsigned int flags)
{
    int r;

    I2C_DATA = b;
    I2C_CMD  = I2C_CMD_WRITE | flags;
    r = wait_done();
    if (r != I2C_OK)
        return r;
    return (I2C_STATUS & I2C_ST_RX_NACK) ? 1 : I2C_OK;
}

static int get(unsigned char *b, unsigned int flags)
{
    int r;

    I2C_CMD = I2C_CMD_READ | flags;
    r = wait_done();
    *b = (unsigned char)(I2C_DATA & 0xFFu);
    return r;
}

void i2c_init(unsigned int clkdiv)
{
    if (I2C_STATUS & I2C_ST_BUSY)
        I2C_CMD = I2C_CMD_ABORT;
    I2C_CLKDIV = clkdiv;                /* values below 4 act as 4 */
    I2C_IRQ_EN = 0u;
    if (I2C_STATUS & I2C_ST_HELD)
        stop();                         /* a previous user left the bus held */
}

int i2c_bus_idle_ok(void)
{
    unsigned int st = I2C_STATUS;
    return (st & (I2C_ST_SCL | I2C_ST_SDA)) == (I2C_ST_SCL | I2C_ST_SDA);
}

int i2c_probe(unsigned char addr)
{
    return put((unsigned char)(addr << 1), I2C_CMD_START | I2C_CMD_STOP) == I2C_OK;
}

int i2c_write_read(unsigned char addr,
                   const unsigned char *tx, unsigned int ntx,
                   unsigned char *rx, unsigned int nrx)
{
    int r;

    if (!i2c_bus_idle_ok())
        return I2C_ERR_BUS;
    if (ntx == 0u && nrx == 0u)
        return i2c_probe(addr) ? I2C_OK : I2C_ERR_NACK_ADDR;

    if (ntx != 0u) {
        r = put((unsigned char)(addr << 1), I2C_CMD_START);
        if (r != I2C_OK) {
            if (r > 0) { stop(); return I2C_ERR_NACK_ADDR; }
            return r;
        }
        for (unsigned int i = 0u; i < ntx; i++) {
            unsigned int last = (nrx == 0u) && (i == ntx - 1u);
            r = put(tx[i], last ? I2C_CMD_STOP : 0u);
            if (r != I2C_OK) {
                if (r > 0) {
                    if (!last) stop();
                    return I2C_ERR_NACK_DATA;
                }
                return r;
            }
        }
        if (nrx == 0u)
            return I2C_OK;
    }

    /* START, or repeated START after the write phase */
    r = put((unsigned char)((addr << 1) | 1u), I2C_CMD_START);
    if (r != I2C_OK) {
        if (r > 0) { stop(); return I2C_ERR_NACK_ADDR; }
        return r;
    }
    for (unsigned int i = 0u; i < nrx; i++) {
        unsigned int last = (i == nrx - 1u);
        r = get(&rx[i], last ? (I2C_CMD_NACK | I2C_CMD_STOP) : 0u);
        if (r != I2C_OK)
            return r;
    }
    return I2C_OK;
}

int i2c_write(unsigned char addr, const unsigned char *buf, unsigned int n)
{
    return i2c_write_read(addr, buf, n, 0, 0u);
}

int i2c_read(unsigned char addr, unsigned char *buf, unsigned int n)
{
    return i2c_write_read(addr, 0, 0u, buf, n);
}

int i2c_reg_write(unsigned char addr, unsigned char reg,
                  const unsigned char *buf, unsigned int n)
{
    unsigned char tx[1 + 16];

    if (n > 16u)
        return I2C_ERR_NACK_DATA;       /* keep the stack buffer bounded */
    tx[0] = reg;
    for (unsigned int i = 0u; i < n; i++)
        tx[1 + i] = buf[i];
    return i2c_write_read(addr, tx, 1u + n, 0, 0u);
}

int i2c_reg_read(unsigned char addr, unsigned char reg,
                 unsigned char *buf, unsigned int n)
{
    return i2c_write_read(addr, &reg, 1u, buf, n);
}
