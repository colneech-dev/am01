/*
 * cyd_panel.h -- the CYD front panel service, run inside odo-miner.
 *
 * WHY IT LIVES IN THE MINER AND NOT IN ITS OWN DAEMON. libgpiod line requests
 * are exclusive: odo-miner holds all 25 GPIO lines for as long as it runs, so
 * a separate process cannot open the register bus alongside it. am01-uartd
 * therefore only works with the miner STOPPED, which is fine for flashing the
 * panel and useless for pushing status once a second.
 *
 * Running it as a thread here is what makes the panel usable at all. It is
 * safe because am01_gpio_bus.c serialises every register transaction (see the
 * lock in reg_read16/reg_write16) -- that was added when the thermal thread
 * became the second bus user, and this is the third.
 *
 * COSTS NOTHING WHEN THERE IS NO PANEL. It checks VERSION once; a bitstream
 * below 0x0203 has no UART and the thread exits immediately. With a UART but
 * no CYD attached, it writes status into a FIFO that drains to a pin nobody
 * is listening to, which is a handful of register writes a second against a
 * bus measured at ~50k/s.
 */

#ifndef CYD_PANEL_H
#define CYD_PANEL_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Start the panel thread. Returns 0 if it started, -1 if not (no UART in this
 * bitstream, bus unavailable, or thread creation failed).
 *
 * FAILING IS NOT AN ERROR the miner should care about: a missing panel must
 * never stop mining, so the caller is expected to log and carry on.
 *
 * Must be called AFTER miner_io_pipe_init(), which opens the bus this uses.
 */
int cyd_panel_start(void);

/* Ask the thread to finish. Safe to call if it never started. */
void cyd_panel_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* CYD_PANEL_H */
