/*
 * am01_diag -- read every register the FPGA exposes and print it.
 *
 * Written because there was no way to see any of it from the shell:
 * am01_bus_test only reads STATUS and submits dummy work, so the epoch seed,
 * die temperature, supply rails and fan state were all unobservable on the
 * running board. "The fan seems to be spinning" is not a measurement.
 *
 * Everything here is read-only and safe to run while the miner is going,
 * though the two will interleave on the bus.
 */
#include "am01_gpio_bus.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>

#define ODO_EPOCH_INTERVAL 864000u   /* mainnet: 10 days */

static void print_epoch(const char *label, uint32_t seed)
{
    if (seed == 0) {
        printf("  %-14s (none -- bitstream predates the SEED register,\n"
               "                 or the read failed)\n", label);
        return;
    }
    time_t t = (time_t)seed;
    char buf[32] = "?";
    struct tm tmv;
    if (gmtime_r(&t, &tmv))
        strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M UTC", &tmv);
    printf("  %-14s %u  (%s)\n", label, (unsigned)seed, buf);
}

int main(int argc, char **argv)
{
    const char *chip = (argc > 1) ? argv[1] : getenv("AM01_GPIOCHIP");

    am01_bus_t *bus = am01_bus_open(chip);
    if (!bus) {
        fprintf(stderr,
            "am01_bus_open failed: %s\n"
            "  Pass a chip name, or set AM01_GPIOCHIP. With neither, the SoC\n"
            "  controller is located by label (pinctrl-bcm*) -- run gpiodetect\n"
            "  to see what is present.\n", strerror(errno));
        return 1;
    }

    printf("=== interface ===\n");
    uint16_t ver = 0;
    if (am01_bus_read_version(bus, &ver) == 0) {
        printf("  VERSION        0x%04x  (v%u.%u)\n", ver, ver >> 8, ver & 0xFF);
        if (ver < 0x0101) printf("                 no SEED register\n");
        if (ver < 0x0102) printf("                 no XADC / fan registers\n");
        if (ver < 0x0103) printf("                 4-bit address only, no display\n");
    } else {
        printf("  VERSION        READ FAILED: %s\n", strerror(errno));
        printf("  A failed VERSION read means the 4-phase handshake is not\n"
               "  working at all -- nothing below will be meaningful.\n");
        am01_bus_close(bus);
        return 1;
    }

    uint16_t st = 0;
    if (am01_bus_read_status(bus, &st) == 0)
        printf("  STATUS         0x%04x  (hash_active=%d nonce_valid=%d)\n",
               st, st & AM01_STATUS_HASH_ACTIVE ? 1 : 0,
               st & AM01_STATUS_NONCE_VALID ? 1 : 0);

    printf("\n=== epoch ===\n");
    uint32_t seed = 0;
    if (am01_bus_read_seed(bus, &seed) == 0) {
        print_epoch("bitstream", seed);
        time_t now = time(NULL);
        uint32_t cur = (uint32_t)now - ((uint32_t)now % ODO_EPOCH_INTERVAL);
        print_epoch("chain now", cur);
        if (seed == cur) {
            printf("  CURRENT -- shares will be accepted\n");
        } else {
            printf("  STALE by %u epoch(s) -- shares WILL be rejected.\n",
                   (unsigned)((cur - seed) / ODO_EPOCH_INTERVAL));
            printf("  Regenerate encrypt.v and rebuild; see tools/check-epoch.sh\n");
        }
    } else {
        printf("  seed unreadable: %s\n", strerror(errno));
    }

    printf("\n=== XADC ===\n");
    double c;
    if (am01_bus_read_temp(bus, &c) == 0) {
        printf("  die temp       %.1f C", c);
        if (c > 85.0)      printf("   *** HOT -- check cooling ***");
        else if (c > 70.0) printf("   (warm)");
        printf("\n");
    } else {
        printf("  die temp       unavailable: %s\n", strerror(errno));
    }

    double vi, va, vb;
    if (am01_bus_read_rails(bus, &vi, &va, &vb) == 0) {
        printf("  VCCINT         %.3f V   (nominal 1.00)", vi);
        /* Xilinx spec is +/-5%; this design pulls ~12A through the MP8712, so
         * sag here shows up as wrong hashes long before anything crashes. */
        if (vi < 0.95 || vi > 1.05) printf("   *** OUT OF SPEC ***");
        printf("\n");
        printf("  VCCAUX         %.3f V   (nominal 1.80)%s\n", va,
               (va < 1.71 || va > 1.89) ? "   *** OUT OF SPEC ***" : "");
        printf("  VCCBRAM        %.3f V   (nominal 1.00)%s\n", vb,
               (vb < 0.95 || vb > 1.05) ? "   *** OUT OF SPEC ***" : "");
    }

    printf("\n=== fan ===\n");
    uint8_t duty = 0, tach = 0;
    if (am01_bus_fan(bus, 0, 0, &duty, &tach) == 0) {
        printf("  duty           %u/255  (%.0f%%)\n", duty, duty * 100.0 / 255.0);
        printf("  tach           %u pulses/sec  (~%u rpm at 2 pulses/rev)\n",
               tach, tach * 30u);
        if (duty > 0 && tach == 0)
            printf("  *** duty is non-zero but the tach reads 0: fan stalled,\n"
                   "      disconnected, or has no tach wire ***\n");
    } else {
        printf("  unavailable: %s\n", strerror(errno));
    }

    if (ver >= 0x0103) {
        printf("\n=== touch ===\n");
        uint16_t x = 0, y = 0;
        int pressed = 0;
        if (am01_bus_read_touch(bus, &x, &y, &pressed) == 0)
            printf("  x=%u y=%u pressed=%d\n", x, y, pressed);
    }

    am01_bus_close(bus);
    return 0;
}
