/*
 * am01-uartd -- bridge the FPGA-hosted UART to a PTY, and to the CYD panel.
 *
 * SCAFFOLDING. This does not build yet: hdl/uart_bridge.v does not exist, so
 * the register accessors below are stubs. It is committed as a skeleton so the
 * host and RTL halves are designed against one protocol definition rather than
 * two that drift. Nothing here touches the existing ILI9341 path.
 *
 * TWO JOBS, one link:
 *
 *   1. PANEL MODE (normal): push /run/odod/status.json to the panel once a
 *      second, and apply the commands it sends back.
 *
 *   2. FLASH MODE: expose the UART as a PTY so STOCK esptool can reprogram the
 *      ESP32 over the same four wires, with no cable and without taking the
 *      panel out of the case:
 *
 *          esptool --port /dev/am01-cyd --before no_reset write_flash 0x0 fw.bin
 *
 *      This is the piece that makes the whole approach maintainable. Without
 *      it, every firmware change means physical access. esptool wants a tty
 *      and the FPGA offers a register interface, so a PTY is the adapter --
 *      and using a PTY rather than reimplementing the esptool protocol means
 *      the flashing path is code nobody here has to own.
 *
 * WHY A DAEMON AND NOT A KERNEL DRIVER: the register bus is already driven
 * from userspace by libgpiod (am01_gpio_bus.c), the traffic is a status line a
 * second, and a userspace bug is a restart rather than a kernel oops on a
 * headless miner.
 */

#define _POSIX_C_SOURCE 200809L

#include "cyd_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

/* ------------------------------------------------------------------ */
/* FPGA UART access -- STUBS until hdl/uart_bridge.v exists.           */
/*                                                                     */
/* These will wrap am01_bus_read_reg/am01_bus_write_reg from            */
/* cm4-firmware/am01_gpio_bus.h, which already exist and are already    */
/* used by am01_reg. Deliberately NOT wired up yet: a stub that returns */
/* "no data" is honest, whereas one that pretended to work would make   */
/* the first real bring-up debug two unknowns at once.                  */
/* ------------------------------------------------------------------ */

/* Returns bytes read, 0 if none pending, -1 on error. */
static int uart_rx(uint8_t *buf, size_t max)
{
    (void)buf; (void)max;
    errno = ENOSYS;
    return -1;
}

/* Returns bytes written, -1 on error. Short writes are expected and normal:
 * the FPGA TX FIFO is finite and the caller must be prepared to resume. */
static int uart_tx(const uint8_t *buf, size_t len)
{
    (void)buf; (void)len;
    errno = ENOSYS;
    return -1;
}

/* Drive the ESP32's EN/IO0. The reset-into-bootloader sequence lives HERE, in
 * software, precisely so it can be adjusted without a bitstream rebuild --
 * module-to-module timing differences are common and a 1h35m turnaround to
 * chase one would be absurd. */
static int esp_ctrl(int en, int io0)
{
    (void)en; (void)io0;
    errno = ENOSYS;
    return -1;
}

/* ------------------------------------------------------------------ */
/* Status push                                                         */
/* ------------------------------------------------------------------ */

/* The payload is passed through VERBATIM -- this deliberately does not parse
 * or re-encode it. The panel reads the same object odo-webd and odo-ui do, so
 * it cannot drift from them, and a new miner field needs no change here. */
static int push_status(void)
{
    FILE *f = fopen(CYD_STATUS_PATH, "r");
    if (!f)
        return -1;   /* miner not running yet; the panel shows MINER DOWN */

    char json[CYD_LINE_MAX];
    size_t n = fread(json, 1, sizeof(json) - 1, f);
    fclose(f);
    if (n == 0)
        return -1;
    json[n] = '\0';

    /* Strip newlines: the protocol is line-oriented, and status.json is
     * pretty-printed. A single embedded newline would split one message into
     * several and desynchronise the panel -- the kind of fault that presents
     * as "the display is occasionally garbage" and takes a day to find. */
    for (size_t i = 0; i < n; i++)
        if (json[i] == '\n' || json[i] == '\r')
            json[i] = ' ';

    char line[CYD_LINE_MAX + 16];
    int len = snprintf(line, sizeof(line), "%s%s\n", CYD_MSG_STATUS, json);
    if (len <= 0 || (size_t)len >= sizeof(line))
        return -1;   /* refuse to send a truncated, unparseable object */

    return uart_tx((const uint8_t *)line, (size_t)len);
}

/* ------------------------------------------------------------------ */
/* Commands from the panel                                             */
/* ------------------------------------------------------------------ */

static int touch_flag(const char *path, int on)
{
    if (!on)
        return unlink(path) == 0 || errno == ENOENT ? 0 : -1;
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fclose(f);
    return 0;
}

/* Every command lands on something that ALREADY EXISTS. Nothing here invents a
 * new control surface: fan_boost and reset_stats are the flag files odo-webd
 * already watches, and a pool change is written to the boot-partition config
 * that am01-miner-provision.service installs -- so it survives a reflash, and
 * it survives in the one place that is already authoritative for it. */
static int handle_cmd(const char *line)
{
    const char *p = line + strlen(CYD_CMD_PREFIX);

    if (!strncmp(p, CYD_CMD_FAN_BOOST, strlen(CYD_CMD_FAN_BOOST)))
        return touch_flag(CYD_FAN_BOOST_PATH,
                          strstr(p, " 1") != NULL);

    if (!strncmp(p, CYD_CMD_RESET_STAT, strlen(CYD_CMD_RESET_STAT)))
        return touch_flag(CYD_RESET_STAT_PATH, 1);

    if (!strncmp(p, CYD_CMD_REBOOT, strlen(CYD_CMD_REBOOT))) {
        /* TODO: confirm-guard this at the protocol level too. odo-ui already
         * puts a CONFIRM REBOOT step in front of it on the panel, but a link
         * that can reboot the miner on one malformed line is a link that will
         * eventually do so. */
        return -1;
    }

    if (!strncmp(p, CYD_CMD_SET_POOL, strlen(CYD_CMD_SET_POOL))) {
        /* TODO: write DAEMON_OPTS into CYD_POOL_CONF_PATH, then
         * `systemctl restart am01-miner-provision odo-miner`. Must validate
         * before writing: am01-miner-provision refuses a file with no
         * DAEMON_OPTS or with placeholders still in it, and silently writing
         * something it will refuse would look like the panel doing nothing. */
        return -1;
    }

    return -1;
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;

    fprintf(stderr,
        "am01-uartd: SCAFFOLDING ONLY -- hdl/uart_bridge.v does not exist yet,\n"
        "            so the UART accessors are stubs and this does nothing.\n"
        "            See docs/PLAN-cyd-display.md and cyd/README.md.\n");

    /* Silence unused-function warnings while the stubs are stubs, without
     * deleting the call sites that document the intended shape. */
    (void)uart_rx; (void)esp_ctrl; (void)push_status; (void)handle_cmd;
    return 1;
}
