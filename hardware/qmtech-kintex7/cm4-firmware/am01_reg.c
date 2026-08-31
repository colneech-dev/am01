/*
 * am01_reg.c -- read (or write) an arbitrary GPIO-bus register.
 *
 * WHY. am01_diag prints a fixed, curated set of registers. When something is
 * wrong with a register it does NOT print -- v2.0's FIFO_STAT, say -- the
 * only options were to extend am01_diag and redeploy, or to guess. Guessing
 * is what this project has repeatedly paid for.
 *
 *   am01_reg <addr>            read one register (addr in hex or decimal)
 *   am01_reg <addr> <value>    write one register
 *   am01_reg                   dump the whole 5-bit address space
 *
 * Run as root with odo-miner stopped -- the GPIO chip is opened exclusively.
 */

#define _POSIX_C_SOURCE 200809L

#include "am01_gpio_bus.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Names for the dump, so a bare `am01_reg` is readable. Keep in step with the
 * localparams at the top of odocrypt_gpio_wrapper.v. */
static const char *reg_name(unsigned a)
{
    switch (a) {
    case 0x00: return "VERSION";
    case 0x01: return "CTRL";
    case 0x02: return "STATUS";
    case 0x03: return "NONCE_LO";
    case 0x04: return "NONCE_HI";
    case 0x05: return "HEADER_LO";
    case 0x06: return "HEADER_HI";
    case 0x07: return "TARGET_LO";
    case 0x08: return "TARGET_HI";
    case 0x09: return "SEED_LO";
    case 0x0A: return "SEED_HI";
    case 0x0B: return "TEMP";
    case 0x0C: return "VCCINT";
    case 0x0D: return "VCCAUX";
    case 0x0E: return "VCCBRAM";
    case 0x0F: return "FAN";
    case 0x12: return "LCD_STAT";
    case 0x14: return "TOUCH_X";
    case 0x15: return "TOUCH_Y";
    case 0x16: return "TOUCH_STAT";
    case 0x18: return "FIFO_STAT";
    default:   return "";
    }
}

int main(int argc, char **argv)
{
    am01_bus_t *bus = am01_bus_open(getenv("AM01_GPIOCHIP"));
    if (!bus) {
        fprintf(stderr, "am01_reg: am01_bus_open failed "
                        "(run as root, and stop odo-miner first)\n");
        return 1;
    }

    int rc = 0;

    if (argc == 1) {
        /* Dump. NONCE_HI is SKIPPED on purpose: reading it is what clears
         * NONCE_VALID and, on v2.0, acks the found-FIFO handoff. A dump that
         * silently consumed a nonce would corrupt the very thing someone
         * running this is usually trying to observe. */
        for (unsigned a = 0; a < 32; a++) {
            const char *nm = reg_name(a);
            if (a == 0x04) {
                printf("  0x%02x %-11s <skipped: reading it consumes a nonce>\n",
                       a, "NONCE_HI");
                continue;
            }
            uint16_t v = 0;
            if (am01_bus_read_reg(bus, (uint8_t)a, &v) < 0) {
                printf("  0x%02x %-11s <read failed>\n", a, nm);
                rc = 1;
                continue;
            }
            printf("  0x%02x %-11s 0x%04x  %5u\n", a, nm, v, v);
        }
    } else if (argc == 2) {
        unsigned a = (unsigned)strtoul(argv[1], NULL, 0);
        uint16_t v = 0;
        if (am01_bus_read_reg(bus, (uint8_t)a, &v) < 0) {
            fprintf(stderr, "read of 0x%02x failed\n", a);
            rc = 1;
        } else {
            printf("0x%02x %s = 0x%04x (%u)\n", a, reg_name(a), v, v);
        }
    } else {
        unsigned a = (unsigned)strtoul(argv[1], NULL, 0);
        unsigned v = (unsigned)strtoul(argv[2], NULL, 0);
        if (am01_bus_write_reg(bus, (uint8_t)a, (uint16_t)v) < 0) {
            fprintf(stderr, "write of 0x%04x to 0x%02x failed\n", v, a);
            rc = 1;
        } else {
            printf("wrote 0x%04x to 0x%02x %s\n", v, a, reg_name(a));
        }
    }

    am01_bus_close(bus);
    return rc;
}
