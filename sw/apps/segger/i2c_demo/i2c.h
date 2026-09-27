/*
 * i2c.h - polled driver for i2c_peripheral on the HMS SoC
 *
 * Register map must match fpga/scu35/rtl/i2c_peripheral.sv and the
 * I2C_BASE parameter in cv32e40x_wrapper.sv.
 *
 * Addresses are 7-bit (0x50, not 0xA0); the driver adds the R/W bit.
 */
#ifndef I2C_H
#define I2C_H

#define I2C_BASE            0x10030000u

#define I2C_DATA            (*(volatile unsigned int *)(I2C_BASE + 0x00u))
#define I2C_CMD             (*(volatile unsigned int *)(I2C_BASE + 0x04u))
#define I2C_STATUS          (*(volatile unsigned int *)(I2C_BASE + 0x08u))
#define I2C_CLKDIV          (*(volatile unsigned int *)(I2C_BASE + 0x0Cu))
#define I2C_IRQ_EN          (*(volatile unsigned int *)(I2C_BASE + 0x10u))

#define I2C_CMD_START       (1u << 0)   /* repeated START if the bus is held */
#define I2C_CMD_STOP        (1u << 1)
#define I2C_CMD_WRITE       (1u << 2)   /* send I2C_DATA, read back the ACK bit */
#define I2C_CMD_READ        (1u << 3)   /* receive a byte into I2C_DATA */
#define I2C_CMD_NACK        (1u << 4)   /* with READ: NACK it (last byte) */
#define I2C_CMD_ABORT       (1u << 7)

#define I2C_ST_BUSY         (1u << 0)
#define I2C_ST_RX_NACK      (1u << 1)
#define I2C_ST_HELD         (1u << 2)
#define I2C_ST_SCL          (1u << 3)   /* live pin levels */
#define I2C_ST_SDA          (1u << 4)

/* SCL = 50 MHz / (4 * CLKDIV) */
#define I2C_CLKDIV_100K     125u
#define I2C_CLKDIV_400K     33u         /* 379 kHz, keeps tLOW >= 1.3 us */

/* Return codes */
#define I2C_OK              0
#define I2C_ERR_NACK_ADDR   (-1)        /* nobody answered the address */
#define I2C_ERR_NACK_DATA   (-2)        /* the slave refused a data byte */
#define I2C_ERR_TIMEOUT     (-3)        /* SCL held low too long, transfer aborted */
#define I2C_ERR_BUS         (-4)        /* SCL or SDA low with the bus idle */

void i2c_init(unsigned int clkdiv);
int  i2c_bus_idle_ok(void);             /* 1 if SCL and SDA both read high */
int  i2c_probe(unsigned char addr);     /* 1 if a device ACKs its address */
int  i2c_write(unsigned char addr, const unsigned char *buf, unsigned int n);
int  i2c_read(unsigned char addr, unsigned char *buf, unsigned int n);
/* START, write ntx bytes, repeated START, read nrx bytes, STOP. */
int  i2c_write_read(unsigned char addr,
                    const unsigned char *tx, unsigned int ntx,
                    unsigned char *rx, unsigned int nrx);

/* Register-style devices with a one-byte sub-address (e.g. the LIS2DE12).
 * The sub-address is sent as given; set bit 7 yourself if the device needs
 * it for auto-increment. */
int  i2c_reg_write(unsigned char addr, unsigned char reg,
                   const unsigned char *buf, unsigned int n);
int  i2c_reg_read(unsigned char addr, unsigned char reg,
                  unsigned char *buf, unsigned int n);

#endif
