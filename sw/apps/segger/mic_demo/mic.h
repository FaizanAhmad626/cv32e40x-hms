/*
 * mic.h - polled driver for mic_peripheral on the HMS SoC
 *
 * Register map must match fpga/scu35/rtl/mic_peripheral.sv and the
 * MIC_BASE parameter in cv32e40x_wrapper.sv.
 *
 * The SoC is the TDM bus master for the SB-POLARIS board (8 SBM100B mics).
 * Each mic delivers one signed 24-bit sample per TDM frame, at
 * MIC_FS_HZ = 50 MHz / 8 / 256 = 24414.0625 Hz.
 */
#ifndef MIC_H
#define MIC_H

#define MIC_BASE            0x10040000u

#define MIC_DATA            (*(volatile unsigned int *)(MIC_BASE + 0x00u))
#define MIC_STATUS          (*(volatile unsigned int *)(MIC_BASE + 0x04u))
#define MIC_CTRL            (*(volatile unsigned int *)(MIC_BASE + 0x08u))
#define MIC_IRQ_EN          (*(volatile unsigned int *)(MIC_BASE + 0x0Cu))
#define MIC_FRAMES          (*(volatile unsigned int *)(MIC_BASE + 0x10u))

#define MIC_DATA_VALID      (1u << 31)  /* this read returned a sample */
#define MIC_DATA_SLOT(v)    (((v) >> 24) & 0x7u)

#define MIC_ST_RX_VALID     (1u << 0)
#define MIC_ST_RX_FULL      (1u << 1)
#define MIC_ST_OVERRUN      (1u << 2)   /* sticky, write 1 to clear */
#define MIC_ST_RUNNING      (1u << 3)

#define MIC_CTRL_EN         (1u << 0)
#define MIC_CTRL_FLUSH      (1u << 1)
#define MIC_CTRL_MASK(m)    (((m) & 0xFFu) << 8)

#define MIC_NUM_SLOTS       8u
#define MIC_FULL_SCALE      8388608     /* 2^23 */

/* 50 MHz / (8 * 256) = 24414.0625 Hz, kept as a fraction for integer math */
#define MIC_FS_NUM          390625u
#define MIC_FS_DEN          16u
#define MIC_FS_HZ           24414u      /* rounded, for messages and delays */

/* Signed 24-bit sample from a DATA word */
static inline int mic_sample(unsigned int v)
{
    return (int)(v << 8) >> 8;
}

void mic_start(unsigned int slot_mask);     /* flush, then start BCLK and WS */
void mic_stop(void);                        /* BCLK and WS stop low */
void mic_flush(void);                       /* empty the FIFO, clear OVERRUN */
void mic_wait_frames(unsigned int frames);  /* discard samples for this many frames */

#endif
