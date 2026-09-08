/*
 * reset_watch.c -- see reset_watch.h for why this exists.
 */

#include "reset_watch.h"

int reset_watch_step(struct reset_watch *w, int read_ok, uint8_t now)
{
    if (!w || !read_ok)
        return 0;

    now &= 0x0Fu;                 /* it is a nibble; ignore anything above */

    if (!w->have_prev) {
        w->have_prev = 1;
        w->prev      = now;
        return 0;
    }

    if (now == w->prev)
        return 0;

    /*
     * Rebaseline on ANY change, including a decrease.
     *
     * The counter only counts up and saturates at 15, so a decrease means the
     * FPGA was reconfigured -- reflashed, or power-cycled -- which is at least
     * as strong a reason to resync as a reset is. Comparing with > would miss
     * it and leave the host dispatching into a core that has never seen a job.
     */
    w->prev = now;
    return 1;
}
