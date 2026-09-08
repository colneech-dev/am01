/*
 * reset_watch.h -- notice that the FPGA reset underneath us.
 *
 * WHY
 *
 * bus_rst_n can assert on its own: SW2 is sampled raw and undebounced, and a
 * momentary MMCM unlock does it too. When it does, found_path discards
 * whatever was queued, clears `lost`, and the clk_h word counters are left
 * wherever the dispatch had got to. Zeroing those counters is NOT restoring
 * alignment -- if reset lands after 3 of a job's 8 target words, the remaining
 * 5 still arrive and the NEXT job commits on its third word, permanently.
 *
 * Only the host knows how many words it sent, so only the host can fix it: see
 * the reset, reissue OP_SOFT_RESET, redispatch from word 0. VERSION 0x020A
 * publishes a saturating reset count in ADDR_FIFO_STAT's spare nibble so the
 * event is visible at all; before that it left no trace anywhere.
 *
 * The decision is split out here because it has three edge cases that are easy
 * to get wrong and impossible to exercise through a mining loop: the first
 * observation must not fire, a failed register read must not fire, and the
 * counter saturates at 15 rather than wrapping.
 */

#ifndef RESET_WATCH_H
#define RESET_WATCH_H

#include <stdint.h>

struct reset_watch {
    int     have_prev;
    uint8_t prev;
};

#define RESET_WATCH_INIT { 0, 0 }

/*
 * Feed one observation of the FPGA's reset counter.
 *
 *   read_ok  0 if the register could not be read -- see below
 *   now      the 4-bit count, 0..15
 *
 * Returns 1 if a reset happened since the last call and the caller must
 * resync and redispatch; 0 otherwise.
 *
 * A FAILED READ RETURNS 0 AND CHANGES NOTHING. A dropped read is
 * indistinguishable from no reset, and treating it as a reset would restart
 * the job on a glitch -- turning a diagnostic into a fault of its own. The
 * same reasoning covers a bitstream older than 0x020A: the nibble was a
 * hard-coded zero there, so it simply never reports.
 *
 * THE FIRST CALL NEVER FIRES. It establishes the baseline. The counter is not
 * cleared by reset (a counter a reset clears cannot count resets), so at
 * startup it holds however many resets happened before the daemon existed --
 * which is history, not an event to act on.
 */
int reset_watch_step(struct reset_watch *w, int read_ok, uint8_t now);

#endif /* RESET_WATCH_H */
