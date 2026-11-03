/*
 * mic.c - polled driver for mic_peripheral on the HMS SoC
 */
#include "mic.h"

static unsigned int mask_q = 0xFFu;

void mic_start(unsigned int slot_mask)
{
    mask_q   = slot_mask & 0xFFu;
    MIC_CTRL = MIC_CTRL_MASK(mask_q) | MIC_CTRL_FLUSH | MIC_CTRL_EN;
}

void mic_stop(void)
{
    MIC_CTRL = MIC_CTRL_MASK(mask_q) | MIC_CTRL_FLUSH;
}

void mic_flush(void)
{
    MIC_CTRL = MIC_CTRL_MASK(mask_q) | MIC_CTRL_FLUSH |
               (MIC_STATUS & MIC_ST_RUNNING ? MIC_CTRL_EN : 0u);
}

void mic_wait_frames(unsigned int frames)
{
    unsigned int start = MIC_FRAMES;

    while (MIC_FRAMES - start < frames)
        (void)MIC_DATA;                     /* keep the FIFO from overrunning */
    mic_flush();
}
