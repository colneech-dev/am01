/*
 * thermal_am01.h -- temperature and fan for the QMTECH XC7K325T + CM4 board.
 *
 * SAME API as odo-miner-cyclonev/hps/thermal.h, DIFFERENT HARDWARE UNDERNEATH.
 * A local file rather than an edit to the sibling repo, for the same reason
 * miner_pipe_am01.c and miner_pipelined.v are local copies: that is a separate
 * project with different silicon, and a change that is right here is not
 * automatically right there.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS EXISTS: the Cyclone V version cannot work on this board
 * ---------------------------------------------------------------------------
 * odo-miner-cyclonev/hps/thermal.c drives a DS18B20 one-wire sensor and a fan
 * tach through an Avalon-MM PIO at LWH2F offset 0x1500, reached by mmap'ing
 * /dev/mem. Every part of that is specific to a Cyclone V SoC:
 *
 *   * there is no DS18B20 anywhere on this board, and nowhere to put one --
 *     all 28 CM4 GPIOs terminate at FPGA balls, none at a header
 *   * there is no LWH2F bridge and no Avalon-MM anything; the CM4 talks to
 *     the FPGA over a 24-line parallel register bus
 *   * the fan tach is not on a host GPIO. It goes to JP5 pin 46 -> FPGA ball
 *     U25 and is counted in fabric
 *
 * So thermal_init() fails on this board, the daemon logs "thermal_init failed;
 * fan control disabled", and temp_c / fan_rpm stay at their -1 sentinels --
 * which is what the web dashboard has been showing.
 *
 * THIS WAS PREVIOUSLY MISDIAGNOSED, including by me, in comments now corrected
 * in three files: it was recorded as "the miner runs as user 'miner' so
 * /dev/mem is denied". Permissions are not the problem. Running it as root
 * would not help -- there is no such peripheral to map, and mapping that
 * physical address on a BCM2711 would at best fail and at worst hand back
 * something unrelated. The module targets hardware that is not here.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS ONE DOES INSTEAD
 * ---------------------------------------------------------------------------
 * Reads the numbers the FPGA already publishes over the register bus the
 * daemon is using anyway:
 *
 *   ADDR_TEMP (0x0B)  XADC on-die temperature, converted by
 *                     am01_bus_read_temp()
 *   ADDR_FAN  (0x0F)  read: [7:0] current duty, [15:8] tach pulses/sec
 *                     write: [7:0] duty FLOOR, 0 = fully automatic
 *
 * No new transport, no new permissions, no extra hardware. The accessors were
 * already written and tested (am01_gpio_bus.c); nothing was consuming them.
 *
 * ---------------------------------------------------------------------------
 * ONE IMPORTANT BEHAVIOURAL DIFFERENCE: THE FAN CURVE LIVES IN FABRIC
 * ---------------------------------------------------------------------------
 * On the Cyclone V, software owns the fan: thermal_fan_update() computes a
 * duty from the last reading and writes it.
 *
 * Here the FPGA runs the curve itself, closed-loop off XADC, stepping
 * 30/40/55/75/100% at 40/55/70/85 C. That is deliberate and it is a safety
 * property, not an optimisation: this design free-runs at full power the
 * moment it configures from flash -- before Linux boots, and whether or not
 * the miner is alive. Cooling must not depend on software having started.
 *
 * So thermal_fan_update() here does NOT command a duty. The write path sets a
 * FLOOR only: software can ask for more cooling than the curve wants, never
 * less. A bug in this file can therefore overheat nothing.
 */

#ifndef THERMAL_AM01_H
#define THERMAL_AM01_H

/* Curve thresholds are in the RTL (odocrypt_gpio_wrapper.v), not here, and
 * are listed only so this file is readable next to its Cyclone V counterpart:
 *   30% below 40 C, then 40/55/75/100% at 40/55/70/85 C.
 * Changing them needs a bitstream. That is the correct cost for a change to
 * the thing that stops the board cooking itself. */

/* Verify the FPGA is reachable and reporting a plausible temperature.
 * Returns 0 on success, -1 if the bus is not open or the bitstream is too old
 * (VERSION < 0x0102, before ADDR_TEMP existed). */
int  thermal_init(void);

/* Latest XADC die temperature, rounded to whole degrees.
 *
 * DOES NOT BLOCK. The DS18B20 version blocks ~750 ms for a conversion and its
 * header warns to call it only from the background thread; XADC free-runs and
 * this is a register read. The caller is unchanged and simply gets a fresher
 * number.
 *
 * Returns 0 on success, -1 if unreadable (including EAGAIN in the first few
 * microseconds after configuration, before the first conversion completes). */
int  thermal_read_c(int *temp_c);

/* Raise the fan to at least `pct`. CLAMPED TO [0,100] and applied as a FLOOR:
 * the fabric curve still runs above it, so this can only ever increase
 * cooling. 0 restores fully automatic control. */
void thermal_fan_set_pct(int pct);

/* No-op beyond bookkeeping -- the fabric owns the curve. Kept so the caller in
 * miner_pipe_am01.c needs no change and stays diffable against the Cyclone V
 * original. */
void thermal_fan_update(int temp_c);

/* ACTUAL current duty as a percentage, read back from the FPGA -- not the last
 * value software asked for. Those differ whenever the fabric curve is above
 * the floor, which is most of the time, and reporting the commanded value
 * would make the dashboard show a fan speed the fan is not running at.
 * Returns -1 if unreadable. */
int  thermal_fan_state(void);

/* Fan RPM from the tach counter in fabric.
 *
 * DOES NOT BLOCK, and ignores window_ms: the FPGA counts pulses continuously
 * and reports pulses/sec, so there is nothing to sample. The parameter is kept
 * for signature compatibility with the Cyclone V version.
 *
 * Returns -1 if unreadable. Zero pulses with a non-zero duty is reported as 0
 * rather than -1: that is a stalled or disconnected fan, which is a genuine
 * reading and one worth seeing. */
int  thermal_tach_rpm(int window_ms);

/* No reset button is wired on this board -- JP5 has one, but it is not
 * populated in this design and no RTL reads it. Always returns 0 (not
 * pressed), so the daemon's button poll is harmless rather than absent. */
int  thermal_reset_pressed(void);

/* Restore fully automatic fan control. NOT "turn the fan off" -- the Cyclone V
 * version does that, and doing it here would be wrong: the fabric would
 * override it anyway, and a shutdown path that appears to stop the fan on a
 * board drawing ~12A is a dangerous thing to leave in the source for someone
 * to copy. */
void thermal_shutdown(void);

#endif /* THERMAL_AM01_H */
