/*
 * AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant, design proposal
 *
 * Copyright 2015-2022 AtomMiner <atom@atomminer.com>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 3 of the License, or (at your option)
 * any later version. If not, see <http://www.gnu.org/licenses/>.
 *
 * -------------------------------------------------------------------------
 * Bring-up CLI: read STATUS, submit a dummy all-zero work item, wait for
 * a nonce (or the timeout, which is expected with all-zero work), print
 * the result. Not a pool client -- just proof the bus round-trips before
 * plugging in real header/target words from a stratum/pool connection.
 *
 * Usage: am01_bus_test [gpiochip_name]   (defaults to gpiochip0)
 */
#include "am01_gpio_bus.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    const char *chip_name = (argc > 1) ? argv[1] : "gpiochip0";

    am01_bus_t *bus = am01_bus_open(chip_name);
    if (!bus) {
        fprintf(stderr,
                "Failed to open %s.\n"
                "Check: running with GPIO permissions (root, or gpio group);\n"
                "the FPGA is programmed with am01_qmtech_top; and the\n"
                "gpiochip/line-offset assumption in am01_gpio_bus.c matches\n"
                "your kernel (`gpioinfo` to check).\n",
                chip_name);
        return 1;
    }

    uint16_t status;
    if (am01_bus_read_status(bus, &status) < 0) {
        fprintf(stderr,
                "Bus read failed -- check wiring against ../README.md's pinout table.\n");
        am01_bus_close(bus);
        return 1;
    }
    printf("STATUS = 0x%04x (hash_active=%d nonce_valid=%d)\n",
           status,
           (status & AM01_STATUS_HASH_ACTIVE) != 0,
           (status & AM01_STATUS_NONCE_VALID) != 0);

    /* Dummy all-zero work item. Replace with real header/target words
     * from a pool/stratum client before this does anything useful. */
    uint32_t header[19];
    uint32_t target[8];
    memset(header, 0, sizeof(header));
    memset(target, 0, sizeof(target));

    printf("Submitting test work (19 header words + 8 target words)...\n");
    if (am01_bus_submit_work(bus, header, target) < 0) {
        fprintf(stderr, "submit_work failed.\n");
        am01_bus_close(bus);
        return 1;
    }

    printf("Waiting for a nonce (IRQ, 30s timeout -- a timeout is expected\n"
           "with all-zero dummy work; this just proves the bus round-trips)...\n");
    if (am01_bus_wait_irq(bus, 30000) < 0) {
        printf("Timed out.\n");
    } else {
        uint32_t nonce;
        if (am01_bus_read_nonce(bus, &nonce) == 0)
            printf("Nonce: 0x%08x\n", nonce);
        else
            fprintf(stderr, "IRQ fired but nonce read failed.\n");
    }

    am01_bus_close(bus);
    return 0;
}
