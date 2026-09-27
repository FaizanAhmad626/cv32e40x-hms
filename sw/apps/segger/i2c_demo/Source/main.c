/*
 * main.c - I2C test for CV32E40X on SCU35
 *
 * The I2C master is wired to PMOD2 (header J10) in the Digilent Pmod I2C order: Pmod
 * pin 3 = SCL (U2), pin 4 = SDA (AA1), pin 5 = GND, pin 6 = 3.3 V. On the
 * board silkscreen (odd numbers on the upper row) those are pins 5, 7, 9
 * and 11. The module must provide pull-ups (or add 4.7 kOhm to 3.3 V).
 *
 * The accelerometer tests below were verified on the board's own LIS2DE12
 * (I2C3) before the pins moved to PMOD2. On PMOD2 they run when a LIS2DE12
 * answers at 0x18 or 0x19; with any other module the demo still checks the
 * bus and lists every address that answers.
 *
 * Each run, at 100 kHz and then at ~400 kHz:
 *   1. bus check: SCL and SDA must both read high while idle
 *   2. scan 0x08..0x77 and list who ACKs
 *   3. WHO_AM_I (0x0F) must read 0x33: a fixed value, so a known-answer read
 *   4. write/readback: four patterns into INT1_THS (0x32), then a two-byte
 *      auto-increment write to INT1_THS + INT1_DURATION read back in one
 *      burst. Both registers only matter once INT1_CFG enables an interrupt,
 *      which it never does here, and both are restored afterwards
 *   5. measure: 100 Hz mode, wait for new data, burst-read X/Y/Z. At rest
 *      the vector must be about 1 g long (gravity), whichever way up the
 *      board is lying
 *
 * Afterwards X/Y/Z are shown live in mg: tilt the board and watch them move.
 *
 * Results go to the UART (FT4232 port B, 115200 8N1) and to the LEDs:
 *   LED0  bus idle levels OK        LED1  WHO_AM_I = 0x33
 *   LED2  register write/readback   LED3  gravity reads about 1 g
 *   (each at both speeds)           LED4  heartbeat
 * Press any key on the terminal to run the test again.
 */
#include "uart.h"
#include "i2c.h"

#define LED_REG         (*(volatile unsigned char *)0x10000000u)

/* LIS2DE12 */
#define ACL_ADDR_A      0x18u       /* SA0 low, as on the SCU35 */
#define ACL_ADDR_B      0x19u       /* SA0 high, tried as a fallback */
#define REG_WHO_AM_I    0x0Fu
#define WHO_AM_I_VAL    0x33u
#define REG_CTRL1       0x20u
#define REG_STATUS      0x27u
#define REG_OUT_X_L     0x28u
#define REG_INT1_THS    0x32u
#define REG_INT1_DUR    0x33u
#define AUTO_INC        0x80u       /* sub-address bit 7: auto-increment */
#define CTRL1_100HZ     0x57u       /* ODR = 100 Hz, normal mode, X/Y/Z on */
#define ST_ZYXDA        0x08u

/* 1 g is about 64 LSB at +-2 g (15.6 mg/digit). Accept 0.7 g to 1.3 g. */
#define G2_MIN          (45 * 45)
#define G2_MAX          (83 * 83)

static unsigned char acl;           /* address the LIS2DE12 answered at, 0 if none */
static unsigned int  n_found;       /* devices that ACKed in the last scan */

/* ------------------------------------------------------------------------ */
/* Output helpers                                                           */
/* ------------------------------------------------------------------------ */
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

/* Signed, padded to a fixed width so the live line does not jitter. */
static void putsdec(int v, unsigned int width)
{
    char buf[12];
    int  i = 0;
    unsigned int u = (unsigned int)(v < 0 ? -v : v);
    do {
        buf[i++] = (char)('0' + u % 10u);
        u /= 10u;
    } while (u != 0u);
    buf[i++] = (v < 0) ? '-' : '+';
    while ((unsigned int)i < width)
        buf[i++] = ' ';
    while (i > 0)
        uart_putc(buf[--i]);
}

static void puterr(int r)
{
    switch (r) {
    case I2C_ERR_NACK_ADDR: uart_puts("no ACK to address");          break;
    case I2C_ERR_NACK_DATA: uart_puts("data byte NACKed");           break;
    case I2C_ERR_TIMEOUT:   uart_puts("timeout, SCL held low");      break;
    case I2C_ERR_BUS:       uart_puts("bus not idle (SCL/SDA low)"); break;
    default:                uart_puts("error");                      break;
    }
}

/* ------------------------------------------------------------------------ */
/* Time: mcycle counts clk_i cycles (50 MHz). CV32E40X resets mcountinhibit */
/* with mcycle stopped, so it is cleared once in main().                    */
/* ------------------------------------------------------------------------ */
static unsigned int cycles(void)
{
    unsigned int c;
    __asm__ volatile ("csrr %0, 0xB00" : "=r"(c));      /* mcycle */
    return c;
}

/* ------------------------------------------------------------------------ */
/* Accelerometer access                                                     */
/* ------------------------------------------------------------------------ */
static int acl_write(unsigned char reg, unsigned char v)
{
    return i2c_reg_write(acl, reg, &v, 1u);
}

static int acl_read(unsigned char reg, unsigned char *v)
{
    return i2c_reg_read(acl, reg, v, 1u);
}

/* Wait for a fresh sample, then read X, Y, Z (8-bit, in the _H registers). */
static int acl_xyz(int *x, int *y, int *z)
{
    unsigned char st = 0u, b[6];
    unsigned int  t0 = cycles();
    int r;

    do {
        r = acl_read(REG_STATUS, &st);
        if (r != I2C_OK)
            return r;
        if (cycles() - t0 > 50000000u / 20u)        /* 50 ms, 5 sample periods */
            return I2C_ERR_TIMEOUT;
    } while (!(st & ST_ZYXDA));

    r = i2c_reg_read(acl, REG_OUT_X_L | AUTO_INC, b, 6u);
    if (r != I2C_OK)
        return r;
    *x = (signed char)b[1];
    *y = (signed char)b[3];
    *z = (signed char)b[5];
    return I2C_OK;
}

static void put_xyz_mg(int x, int y, int z)
{
    uart_puts("X ");
    putsdec(x * 156 / 10, 6);
    uart_puts(" mg  Y ");
    putsdec(y * 156 / 10, 6);
    uart_puts(" mg  Z ");
    putsdec(z * 156 / 10, 6);
    uart_puts(" mg");
}

/* ------------------------------------------------------------------------ */
/* One full test at one bus speed.                                          */
/* Returns bit0 bus OK, bit1 WHO_AM_I, bit2 write/readback, bit3 g.         */
/* ------------------------------------------------------------------------ */
static unsigned int run(unsigned int clkdiv)
{
    static const unsigned char pats[4] = { 0x00u, 0x7Fu, 0x55u, 0x2Au };
    unsigned char v, save[2], two[2], back[2];
    unsigned int  res = 0u, wr_ok = 1u, found = 0u;
    int x, y, z, g2, r;

    i2c_init(clkdiv);
    uart_puts("\n--- CLKDIV ");
    putdec(clkdiv);
    uart_puts(", SCL ");
    putdec(SYS_CLK_HZ / (4u * clkdiv) / 1000u);
    uart_puts(" kHz ---\n");

    /* 1. idle levels */
    if (!i2c_bus_idle_ok()) {
        uart_puts("bus: SCL=");
        putdec((I2C_STATUS & I2C_ST_SCL) ? 1u : 0u);
        uart_puts(" SDA=");
        putdec((I2C_STATUS & I2C_ST_SDA) ? 1u : 0u);
        uart_puts(" while idle. Missing pull-up, wrong pins, or a stuck slave\n");
        return res;
    }
    uart_puts("bus: idle high, OK\n");
    res |= 1u;

    /* 2. scan */
    acl = 0u;
    uart_puts("scan:");
    for (unsigned int a = 0x08u; a <= 0x77u; a++) {
        if (i2c_probe((unsigned char)a)) {
            uart_puts(" 0x");
            puthex8(a);
            found++;
            if ((a == ACL_ADDR_A || a == ACL_ADDR_B) && acl == 0u)
                acl = (unsigned char)a;
        }
    }
    if (found == 0u)
        uart_puts(" nothing answered");
    uart_puts("\n");
    n_found = found;
    if (acl == 0u) {
        uart_puts("no LIS2DE12 at 0x18 or 0x19: accelerometer tests skipped\n");
        return res;
    }

    /* 3. known-answer read */
    r = acl_read(REG_WHO_AM_I, &v);
    uart_puts("WHO_AM_I: ");
    if (r != I2C_OK) { puterr(r); uart_puts("\n"); return res; }
    uart_puts("0x");
    puthex8(v);
    if (v == WHO_AM_I_VAL) { uart_puts(" (expected 0x33) PASS\n"); res |= 2u; }
    else                   { uart_puts(" (expected 0x33) FAIL\n"); }

    /* 4. write/readback, restoring the originals afterwards */
    r = i2c_reg_read(acl, REG_INT1_THS | AUTO_INC, save, 2u);
    if (r != I2C_OK) { uart_puts("save: "); puterr(r); uart_puts("\n"); return res; }

    for (unsigned int i = 0u; i < 4u; i++) {
        r = acl_write(REG_INT1_THS, pats[i]);
        if (r == I2C_OK)
            r = acl_read(REG_INT1_THS, &v);
        if (r != I2C_OK || v != pats[i]) {
            uart_puts("INT1_THS: wrote 0x");
            puthex8(pats[i]);
            uart_puts(", ");
            if (r != I2C_OK) puterr(r);
            else { uart_puts("read 0x"); puthex8(v); }
            uart_puts("\n");
            wr_ok = 0u;
        }
    }

    two[0] = 0x3Cu;                                 /* INT1_THS */
    two[1] = 0x5Au;                                 /* INT1_DURATION */
    r = i2c_reg_write(acl, REG_INT1_THS | AUTO_INC, two, 2u);
    if (r == I2C_OK)
        r = i2c_reg_read(acl, REG_INT1_THS | AUTO_INC, back, 2u);
    if (r != I2C_OK || back[0] != two[0] || back[1] != two[1]) {
        uart_puts("burst write/read: ");
        if (r != I2C_OK) puterr(r);
        else { uart_puts("read 0x"); puthex8(back[0]); uart_puts(" 0x"); puthex8(back[1]); }
        uart_puts("\n");
        wr_ok = 0u;
    }

    r = i2c_reg_write(acl, REG_INT1_THS | AUTO_INC, save, 2u);
    if (r == I2C_OK)
        r = i2c_reg_read(acl, REG_INT1_THS | AUTO_INC, back, 2u);
    if (r != I2C_OK || back[0] != save[0] || back[1] != save[1]) {
        uart_puts("restore of INT1_THS/INT1_DURATION failed\n");
        wr_ok = 0u;
    }

    if (wr_ok) {
        uart_puts("write/readback: 4 patterns + 2-byte burst, PASS (originals restored)\n");
        res |= 4u;
    }

    /* 5. gravity */
    r = acl_write(REG_CTRL1, CTRL1_100HZ);
    if (r == I2C_OK)
        r = acl_read(REG_CTRL1, &v);
    if (r != I2C_OK || v != CTRL1_100HZ) {
        uart_puts("CTRL_REG1: could not enable 100 Hz mode\n");
        return res;
    }
    (void)acl_xyz(&x, &y, &z);                      /* first sample after power-up may be stale */
    r = acl_xyz(&x, &y, &z);
    if (r != I2C_OK) { uart_puts("measure: "); puterr(r); uart_puts("\n"); return res; }
    put_xyz_mg(x, y, z);
    g2 = x * x + y * y + z * z;
    if (g2 >= G2_MIN && g2 <= G2_MAX) { uart_puts("   |a| about 1 g, PASS\n"); res |= 8u; }
    else                              { uart_puts("   |a| not about 1 g, FAIL (is the board moving?)\n"); }

    return res;
}

int main(void)
{
    __asm__ volatile ("csrw 0x320, zero");          /* mcountinhibit = 0: let mcycle count */

    uart_init(115200u);
    uart_puts("\nHMS CV32E40X on SCU35: I2C test on PMOD2 (SCL pin 3, SDA pin 4)\n");

    for (;;) {
        unsigned int a = run(I2C_CLKDIV_100K);
        unsigned int b = run(I2C_CLKDIV_400K);
        unsigned int leds = a & b & 0xFu;
        int x, y, z;

        LED_REG = (unsigned char)leds;

        uart_puts("\nresult: ");
        if (leds == 0xFu)
            uart_puts("PASS");
        else if (leds == 0x1u && acl == 0u) {
            uart_puts("bus OK, ");
            putdec(n_found);
            uart_puts(" device(s) answered, no LIS2DE12 to test");
        } else
            uart_puts("FAIL");
        uart_puts(" (LEDs 0x");
        puthex8(leds);
        uart_puts(")\n");

        if (!(a & b & 2u)) {
            uart_puts("press any key to run again\n");
            (void)uart_getc();
            continue;
        }

        /* Live view at ~4 updates per second until a key is pressed. */
        uart_puts("live readings, tilt the board. Press any key to run the test again\n");
        while (uart_try_getc() < 0) {
            unsigned int t0 = cycles();
            uart_putc('\r');
            if (acl_xyz(&x, &y, &z) == I2C_OK)
                put_xyz_mg(x, y, z);
            else
                uart_puts("read error                                   ");
            while (cycles() - t0 < 50000000u / 4u) {
                /* 250 ms */
            }
        }
        uart_puts("\n");
    }

    return 0;   /* not reached */
}
