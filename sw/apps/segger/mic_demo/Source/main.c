/*
 * main.c - microphone capture demo for CV32E40X on SCU35
 *
 * The SoC drives the SB-POLARIS board (8 SBM100B-TDM mics) as TDM master
 * through mic_peripheral: J2 BCLK, WS and DATA on PMOD0 silkscreen pins 1,
 * 3 and 5, GND on 9-10, 3.3 V on 11-12. Same wiring as the mic_test build.
 *
 * After start-up the program captures CAPTURE_N samples from every mic,
 * then prints one line per mic on the UART (FT4232 port B, 115200 8N1):
 *
 *   slot  samples  level(dBFS)  peak  tone(Hz)
 *
 *   level    RMS after removing DC, relative to 24-bit full scale, the same
 *            measure as plot_ila_tdm.m
 *   peak     largest |sample - DC| in LSB
 *   tone     frequency from the rising zero crossings (with hysteresis and
 *            interpolation between samples). Meaningful while a single tone
 *            is playing, e.g. 1 kHz from a phone; it reads noise otherwise.
 *
 * LEDs: LED0 = capture complete with no FIFO overrun, LED1 = all 8 mics
 * gave non-constant data, LED2 = all 8 mics agree on the tone within 1 %,
 * LED4 = heartbeat (hardware).
 *
 * Then press 0-7 to print that mic's raw samples (one per line between
 * BEGIN and END, for MATLAB or a spreadsheet), or any other key to capture
 * again.
 *
 * Everything is integer math: no FPU on the core, and no float library
 * needed.
 */
#include "uart.h"
#include "mic.h"

#define LED_REG         (*(volatile unsigned char *)0x10000000u)

/* SIM: short run for the SoC testbench, not for the board */
#ifdef SIM
#define CAPTURE_N       256u            /* per mic, power of two */
#define CAPTURE_LOG2    8u
#define SETTLE_FRAMES   16u
#define BAUD            3125000u        /* fast UART so the testbench is quick */
#else
#define CAPTURE_N       1024u           /* per mic: 41.9 ms at 24.414 kHz */
#define CAPTURE_LOG2    10u
#define SETTLE_FRAMES   4883u           /* 200 ms after BCLK starts */
#define BAUD            115200u
#endif

static int samples[MIC_NUM_SLOTS][CAPTURE_N];   /* 32 KB on hardware */
static unsigned int count[MIC_NUM_SLOTS];

/* ------------------------------------------------------------------------ */
/* Printing                                                                 */
/* ------------------------------------------------------------------------ */
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

static void putint(int v)
{
    if (v < 0) {
        uart_putc('-');
        putdec((unsigned int)(-v));
    } else {
        putdec((unsigned int)v);
    }
}

/* v in tenths, printed as e.g. -63.4, right-aligned in width characters */
static void putfix1(int v, int width)
{
    unsigned int a = (unsigned int)(v < 0 ? -v : v);
    int digits = 1;
    for (unsigned int t = a / 10u; t != 0u; t /= 10u)
        digits++;
    for (int n = width - digits - 2 - (v < 0); n > 0; n--)
        uart_putc(' ');
    if (v < 0)
        uart_putc('-');
    putdec(a / 10u);
    uart_putc('.');
    uart_putc((char)('0' + a % 10u));
}

static void putpad(unsigned int v, int width)
{
    int digits = 1;
    for (unsigned int t = v / 10u; t != 0u; t /= 10u)
        digits++;
    for (int n = width - digits; n > 0; n--)
        uart_putc(' ');
    putdec(v);
}

/* ------------------------------------------------------------------------ */
/* Integer math                                                             */
/* ------------------------------------------------------------------------ */
static unsigned int isqrt64(unsigned long long x)
{
    unsigned long long r = 0, bit = 1ull << 62;
    while (bit > x)
        bit >>= 2;
    while (bit != 0u) {
        if (x >= r + bit) {
            x -= r + bit;
            r  = (r >> 1) + bit;
        } else {
            r >>= 1;
        }
        bit >>= 2;
    }
    return (unsigned int)r;
}

/* log2(x) in Q16, x >= 1 */
static int log2_q16(unsigned int x)
{
    int n = 0;
    while ((x >> n) > 1u)
        n++;
    unsigned long long y = ((unsigned long long)x << 31) >> n;   /* Q31, [1, 2) */
    int r = n << 16;
    for (int b = 15; b >= 0; b--) {
        y = (y * y) >> 31;
        if (y >= (1ull << 32)) {
            y >>= 1;
            r |= 1 << b;
        }
    }
    return r;
}

/* 20*log10(rms / 2^23) in tenths of a dB. rms must be >= 1. */
static int dbfs10(unsigned int rms)
{
    int d = log2_q16(rms) - (23 << 16);
    /* 20*log10(2) = 6.0206 dB per octave; in tenths per Q16 unit that is
     * 60.206 / 65536 = 3853 / 2^22 (error 0.005 %). */
    return (int)(((long long)d * 3853 + (1 << 21)) >> 22);   /* rounded */
}

/* ------------------------------------------------------------------------ */
/* Capture                                                                  */
/* ------------------------------------------------------------------------ */

/* Fills samples[][] with CAPTURE_N samples per mic. Returns 1 if the FIFO
 * never overran, 0 if samples were dropped. */
static int capture(void)
{
    unsigned int need = MIC_NUM_SLOTS;
    unsigned int limit;

    for (unsigned int s = 0u; s < MIC_NUM_SLOTS; s++)
        count[s] = 0u;

    mic_flush();
    limit = MIC_FRAMES + CAPTURE_N + 64u;   /* stop even if a mic never answers */

    while (need != 0u && (int)(MIC_FRAMES - limit) < 0) {
        unsigned int v = MIC_DATA;
        if (v & MIC_DATA_VALID) {
            unsigned int s = MIC_DATA_SLOT(v);
            unsigned int c = count[s];
            if (c < CAPTURE_N) {
                samples[s][c] = mic_sample(v);
                count[s] = c + 1u;
                if (c + 1u == CAPTURE_N)
                    need--;
            }
        }
    }
    return (MIC_STATUS & MIC_ST_OVERRUN) == 0u;
}

/* ------------------------------------------------------------------------ */
/* Analysis of one mic                                                      */
/* ------------------------------------------------------------------------ */
typedef struct {
    unsigned int rms;       /* LSB, DC removed */
    unsigned int peak;      /* LSB, DC removed */
    int          level10;   /* dBFS * 10 */
    unsigned int tone10;    /* Hz * 10, 0 if fewer than 3 crossings */
} stats_t;

static void analyse(const int *x, unsigned int n, stats_t *st)
{
    long long          sum = 0;
    unsigned long long sq  = 0;
    int                mean;

    for (unsigned int i = 0u; i < n; i++)
        sum += x[i];
    mean = (int)(sum >> CAPTURE_LOG2);

    st->peak = 0u;
    for (unsigned int i = 0u; i < n; i++) {
        int d = x[i] - mean;
        unsigned int a = (unsigned int)(d < 0 ? -d : d);
        sq += (unsigned long long)((long long)d * d);
        if (a > st->peak)
            st->peak = a;
    }
    st->rms     = isqrt64(sq >> CAPTURE_LOG2);
    st->level10 = st->rms ? dbfs10(st->rms) : -9999;

    /* Rising zero crossings. The signal has to dip below -rms/2 before the
     * next crossing counts, so small noise wiggles around zero are ignored.
     * Crossing times are interpolated between samples, in 1/16 sample. */
    int          thr   = (int)(st->rms / 2u);
    int          armed = 0;
    unsigned int n_cross = 0u, t_first = 0u, t_last = 0u;

    for (unsigned int i = 1u; i < n; i++) {
        int a = x[i - 1u] - mean;
        int b = x[i] - mean;
        if (a < -thr)
            armed = 1;
        if (armed && a < 0 && b >= 0) {
            unsigned int num = (unsigned int)(-a), den = (unsigned int)(b - a);
            while (den >= (1u << 15)) {
                num >>= 1;
                den >>= 1;
            }
            unsigned int t = ((i - 1u) << 4) + ((num << 4) + den / 2u) / den;
            if (n_cross == 0u)
                t_first = t;
            t_last = t;
            n_cross++;
            armed = 0;
        }
    }

    /* f = (crossings - 1) periods / elapsed time.
     * In tenths of Hz with time in 1/16 sample:
     *   f10 = (n - 1) * 10 * fs * 16 / dt = (n - 1) * 3906250 / dt   */
    if (n_cross >= 3u && t_last > t_first)
        st->tone10 = ((n_cross - 1u) * 3906250u + (t_last - t_first) / 2u) /
                     (t_last - t_first);
    else
        st->tone10 = 0u;
}

/* ------------------------------------------------------------------------ */
/* Report                                                                   */
/* ------------------------------------------------------------------------ */
static void report(int no_overrun)
{
    stats_t      st[MIC_NUM_SLOTS];
    unsigned int leds = 0u;
    unsigned int live = 0u, agree = 0u;

    uart_puts("\nslot  samples  level(dBFS)    peak  tone(Hz)\n");
    for (unsigned int s = 0u; s < MIC_NUM_SLOTS; s++) {
        putpad(s, 4);
        putpad(count[s], 9);
        if (count[s] < CAPTURE_N) {
            uart_puts("  missing samples: no data from this mic\n");
            continue;
        }
        analyse(samples[s], CAPTURE_N, &st[s]);
        if (st[s].rms == 0u) {
            uart_puts("  constant value ");
            putint(samples[s][0]);
            uart_puts(": mic not driving DATA?\n");
            continue;
        }
        live++;
        putfix1(st[s].level10, 13);
        putpad(st[s].peak, 8);
        if (st[s].tone10 != 0u)
            putfix1((int)st[s].tone10, 10);
        else
            uart_puts("        --");
        uart_puts("\n");
    }

    /* do all mics hear the same tone? (within 1 % of mic 0) */
    if (live == MIC_NUM_SLOTS && st[0].tone10 != 0u) {
        for (unsigned int s = 0u; s < MIC_NUM_SLOTS; s++) {
            unsigned int f = st[s].tone10, f0 = st[0].tone10;
            unsigned int diff = f > f0 ? f - f0 : f0 - f;
            if (f != 0u && diff * 100u <= f0)
                agree++;
        }
    }

    if (!no_overrun)
        uart_puts("FIFO overrun during capture: samples were dropped, the CPU did not keep up\n");
    else
        leds |= 1u;
    if (live == MIC_NUM_SLOTS)
        leds |= 2u;
    if (agree == MIC_NUM_SLOTS) {
        leds |= 4u;
        uart_puts("all 8 mics agree on the tone\n");
    }
    LED_REG = (unsigned char)leds;
}

#ifndef SIM
static void dump(unsigned int s)
{
    uart_puts("BEGIN slot ");
    putdec(s);
    uart_puts(" fs 24414.0625 n ");
    putdec(count[s]);
    uart_puts("\n");
    for (unsigned int i = 0u; i < count[s]; i++) {
        putint(samples[s][i]);
        uart_puts("\n");
    }
    uart_puts("END\n");
}
#endif

/* ------------------------------------------------------------------------ */
int main(void)
{
    int ok;

    uart_init(BAUD);
    uart_puts("\nHMS CV32E40X on SCU35: TDM microphone capture\n");
    uart_puts("SB-POLARIS J2 on PMOD0: BCLK pin 1, WS pin 3, DATA pin 5\n");
    uart_puts("BCLK 6.25 MHz, 8 mics at 24414 Hz, ");
    putdec(CAPTURE_N);
    uart_puts(" samples per mic\n");

    LED_REG = 0u;
    mic_start(0xFFu);
    if (!(MIC_STATUS & MIC_ST_RUNNING)) {
        uart_puts("mic peripheral not responding at 0x10040000\n");
        for (;;) { }
    }
    mic_wait_frames(SETTLE_FRAMES);         /* mic start-up time */

    for (;;) {
        ok = capture();
        report(ok);

#ifdef SIM
        uart_puts("SIM DONE\n");
        for (;;) { }
#else
        uart_puts("press 0-7 to print that mic's samples, any other key to capture again\n");
        int c = uart_getc();
        if (c >= '0' && c <= '7') {
            dump((unsigned int)(c - '0'));
            uart_puts("press any key to capture again\n");
            (void)uart_getc();
        }
#endif
    }

    return 0;   /* not reached */
}
