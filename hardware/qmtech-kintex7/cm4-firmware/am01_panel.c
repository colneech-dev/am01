/*
 * am01_panel -- ILI9341 output driven cooperatively from the miner's idle path.
 * See am01_panel.h for why this is a library rather than a daemon.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#include "am01_panel.h"

/* ILI9341 commands used here. */
#define ILI_SWRESET 0x01
#define ILI_SLPOUT  0x11
#define ILI_DISPOFF 0x28
#define ILI_DISPON  0x29
#define ILI_CASET   0x2A
#define ILI_PASET   0x2B
#define ILI_RAMWR   0x2C
#define ILI_MADCTL  0x36
#define ILI_COLMOD  0x3A

/* MADCTL: MV|MX -> landscape, BGR bit set to match the panel's filter order. */
#define MADCTL_LANDSCAPE 0x28

#define TILES_X ((AM01_PANEL_W + AM01_PANEL_TILE - 1) / AM01_PANEL_TILE)
#define TILES_Y ((AM01_PANEL_H + AM01_PANEL_TILE - 1) / AM01_PANEL_TILE)
#define TILES_N (TILES_X * TILES_Y)

/* Give up on the panel after this many consecutive bus failures. A display
 * that keeps erroring must not keep borrowing the bus from mining. */
#define MAX_CONSEC_ERRORS 32

static struct {
    int       enabled;
    int       fb_fd;
    uint16_t *fb;            /* mmapped RGB565, AM01_PANEL_W * AM01_PANEL_H */
    uint16_t *shadow;        /* last pushed contents, for damage detection */
    size_t    fb_bytes;
    int       next_tile;     /* round-robin scan position across slices */
    int       errors;
    int       full_repaint;  /* force every tile once, after init */
} P;

static double now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

static void msleep(int ms)
{
    struct timespec ts = { .tv_sec = ms / 1000,
                           .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/*
 * Send a single 8-bit command parameter.
 *
 * The FPGA has no 8-bit DC=1 path: ADDR_LCD_CMD is 8 bits with DC=0, and
 * ADDR_LCD_DATA is 16 bits with DC=1. So a one-byte parameter goes out as the
 * HIGH byte of a 16-bit write, followed by a 0x00 the panel discards as a
 * surplus argument -- the ILI9341 ignores parameters beyond a command's
 * declared count.
 *
 * That is a workaround, not a design. The next bitstream should add an 8-bit
 * DC=1 register (ADDR_LCD_DATA8) and this should become a single clean write;
 * until then, do not use it for a command whose trailing byte would be
 * meaningful.
 */
static int param8(am01_bus_t *bus, uint8_t v)
{
    return am01_bus_lcd_data(bus, (uint16_t)v << 8);
}

/* Wait for the FPGA's SPI shifter to drain. The wrapper DROPS a write issued
 * while busy (see ADDR_LCD_CMD/ADDR_LCD_DATA in the RTL: "if (!spi_busy)"),
 * so skipping this silently loses bytes and desynchronises the panel. */
static int wait_idle(am01_bus_t *bus)
{
    for (int i = 0; i < 10000; i++) {
        int busy = 0;
        if (am01_bus_lcd_busy(bus, &busy) != 0)
            return -1;
        if (!busy)
            return 0;
    }
    errno = ETIMEDOUT;
    return -1;
}

static int cmd(am01_bus_t *bus, uint8_t c)
{
    if (wait_idle(bus) != 0) return -1;
    return am01_bus_lcd_cmd(bus, c);
}

static int data16(am01_bus_t *bus, uint16_t d)
{
    if (wait_idle(bus) != 0) return -1;
    return am01_bus_lcd_data(bus, d);
}

static int cmd_param(am01_bus_t *bus, uint8_t c, uint8_t p)
{
    if (cmd(bus, c) != 0) return -1;
    if (wait_idle(bus) != 0) return -1;
    return param8(bus, p);
}

/* Set the drawing window. CASET/PASET take four bytes each (start hi/lo,
 * end hi/lo), which is an even count -- so these pack cleanly into two 16-bit
 * writes and need no param8() workaround. */
static int set_window(am01_bus_t *bus, int x0, int y0, int x1, int y1)
{
    if (cmd(bus, ILI_CASET) != 0) return -1;
    if (data16(bus, (uint16_t)x0) != 0) return -1;
    if (data16(bus, (uint16_t)x1) != 0) return -1;
    if (cmd(bus, ILI_PASET) != 0) return -1;
    if (data16(bus, (uint16_t)y0) != 0) return -1;
    if (data16(bus, (uint16_t)y1) != 0) return -1;
    return cmd(bus, ILI_RAMWR);
}

static int panel_reset_and_init(am01_bus_t *bus)
{
    /* Hardware reset: hold RST_N low, backlight off. */
    if (am01_bus_lcd_ctrl(bus, 0, 0) != 0) return -1;
    msleep(20);
    if (am01_bus_lcd_ctrl(bus, 1, 0) != 0) return -1;
    msleep(150);

    if (cmd(bus, ILI_SWRESET) != 0) return -1;
    msleep(150);
    if (cmd(bus, ILI_SLPOUT) != 0) return -1;
    msleep(150);                       /* datasheet: 120ms minimum */

    if (cmd_param(bus, ILI_COLMOD, 0x55) != 0) return -1;   /* 16bpp RGB565 */
    if (cmd_param(bus, ILI_MADCTL, MADCTL_LANDSCAPE) != 0) return -1;

    if (cmd(bus, ILI_DISPON) != 0) return -1;
    msleep(20);

    /* Backlight on only once the panel is showing something defined --
     * otherwise the first thing visible is uninitialised GRAM noise. */
    if (set_window(bus, 0, 0, AM01_PANEL_W - 1, AM01_PANEL_H - 1) != 0) return -1;
    for (long i = 0; i < (long)AM01_PANEL_W * AM01_PANEL_H; i++) {
        if (am01_bus_lcd_data(bus, 0x0000) != 0) return -1;
    }
    return am01_bus_lcd_ctrl(bus, 1, 1);
}

int am01_panel_init(am01_bus_t *bus)
{
    memset(&P, 0, sizeof P);
    P.fb_fd = -1;

    const char *on = getenv("AM01_PANEL");
    if (!on || !*on || on[0] == '0') {
        /* Deliberately off. Not an error. */
        return 0;
    }

    const char *dev = getenv("AM01_PANEL_FB");
    if (!dev || !*dev) dev = "/dev/fb1";

    P.fb_fd = open(dev, O_RDONLY);
    if (P.fb_fd < 0) {
        fprintf(stderr, "am01_panel: open %s: %s (panel disabled)\n",
                dev, strerror(errno));
        return -1;
    }

    struct fb_var_screeninfo v;
    if (ioctl(P.fb_fd, FBIOGET_VSCREENINFO, &v) != 0) {
        fprintf(stderr, "am01_panel: FBIOGET_VSCREENINFO: %s (panel disabled)\n",
                strerror(errno));
        close(P.fb_fd); P.fb_fd = -1;
        return -1;
    }
    if (v.bits_per_pixel != 16) {
        fprintf(stderr, "am01_panel: %s is %ubpp, need 16 (RGB565) -- "
                        "panel disabled\n", dev, v.bits_per_pixel);
        close(P.fb_fd); P.fb_fd = -1;
        return -1;
    }
    if (v.xres < AM01_PANEL_W || v.yres < AM01_PANEL_H) {
        fprintf(stderr, "am01_panel: %s is %ux%u, need at least %dx%d -- "
                        "panel disabled\n", dev, v.xres, v.yres,
                        AM01_PANEL_W, AM01_PANEL_H);
        close(P.fb_fd); P.fb_fd = -1;
        return -1;
    }

    P.fb_bytes = (size_t)v.xres * v.yres * 2;
    P.fb = mmap(NULL, P.fb_bytes, PROT_READ, MAP_SHARED, P.fb_fd, 0);
    if (P.fb == MAP_FAILED) {
        fprintf(stderr, "am01_panel: mmap %s: %s (panel disabled)\n",
                dev, strerror(errno));
        P.fb = NULL; close(P.fb_fd); P.fb_fd = -1;
        return -1;
    }

    P.shadow = calloc((size_t)AM01_PANEL_W * AM01_PANEL_H, sizeof(uint16_t));
    if (!P.shadow) {
        munmap(P.fb, P.fb_bytes); P.fb = NULL;
        close(P.fb_fd); P.fb_fd = -1;
        fprintf(stderr, "am01_panel: out of memory (panel disabled)\n");
        return -1;
    }

    if (panel_reset_and_init(bus) != 0) {
        fprintf(stderr, "am01_panel: ILI9341 init failed: %s (panel disabled)\n",
                strerror(errno));
        free(P.shadow); P.shadow = NULL;
        munmap(P.fb, P.fb_bytes); P.fb = NULL;
        close(P.fb_fd); P.fb_fd = -1;
        return -1;
    }

    P.enabled = 1;
    P.full_repaint = 1;   /* shadow is zeroed but GRAM was just cleared too;
                           * repaint once anyway so a non-black fb shows up */
    fprintf(stderr, "am01_panel: ILI9341 up, source %s, %dx%d, %dx%d tiles\n",
            dev, AM01_PANEL_W, AM01_PANEL_H, TILES_X, TILES_Y);
    return 0;
}

int am01_panel_active(void)
{
    return P.enabled;
}

/* Push one tile. Returns 0 on success, -1 on a bus error. */
static int push_tile(am01_bus_t *bus, int tx, int ty)
{
    int x0 = tx * AM01_PANEL_TILE;
    int y0 = ty * AM01_PANEL_TILE;
    int x1 = x0 + AM01_PANEL_TILE - 1;
    int y1 = y0 + AM01_PANEL_TILE - 1;
    if (x1 >= AM01_PANEL_W) x1 = AM01_PANEL_W - 1;
    if (y1 >= AM01_PANEL_H) y1 = AM01_PANEL_H - 1;

    if (set_window(bus, x0, y0, x1, y1) != 0)
        return -1;

    for (int y = y0; y <= y1; y++) {
        const uint16_t *src = P.fb + (size_t)y * AM01_PANEL_W + x0;
        uint16_t *dst = P.shadow + (size_t)y * AM01_PANEL_W + x0;
        for (int x = 0; x <= x1 - x0; x++) {
            if (am01_bus_lcd_data(bus, src[x]) != 0)
                return -1;
            dst[x] = src[x];
        }
    }
    return 0;
}

static int tile_dirty(int tx, int ty)
{
    int x0 = tx * AM01_PANEL_TILE;
    int y0 = ty * AM01_PANEL_TILE;
    int x1 = x0 + AM01_PANEL_TILE; if (x1 > AM01_PANEL_W) x1 = AM01_PANEL_W;
    int y1 = y0 + AM01_PANEL_TILE; if (y1 > AM01_PANEL_H) y1 = AM01_PANEL_H;

    for (int y = y0; y < y1; y++) {
        const uint16_t *a = P.fb     + (size_t)y * AM01_PANEL_W + x0;
        const uint16_t *b = P.shadow + (size_t)y * AM01_PANEL_W + x0;
        if (memcmp(a, b, (size_t)(x1 - x0) * sizeof(uint16_t)) != 0)
            return 1;
    }
    return 0;
}

int am01_panel_slice(am01_bus_t *bus, unsigned budget_us)
{
    if (!P.enabled)
        return 0;

    double start = now_us();
    int pushed = 0;

    /* Round-robin from where the last slice stopped, so no tile can be
     * starved by a busier neighbour earlier in the scan order.
     *
     * WHAT budget_us ACTUALLY GUARANTEES, now that the bus has been measured:
     * it is checked BETWEEN tiles, and a tile is indivisible. So a slice runs
     * until the budget is spent and then finishes the tile in flight -- it can
     * overrun by up to one tile, and a budget smaller than one tile still
     * pushes exactly one, because pushing none would mean the panel never
     * renders at all.
     *
     * am01_busbench on hardware, 2026-08-30: 20.0us per 16-bit LCD_DATA write,
     * so a 16x16 tile is 256 writes = 5.1ms. The caller used to pass 2000us,
     * chosen before any of that was known, which described a slice 2.5x
     * shorter than the one it actually got. The number was wrong, not the
     * behaviour -- see AM01_PANEL_TILE_US in am01_panel.h. */
    for (int scanned = 0; scanned < TILES_N; scanned++) {
        if (now_us() - start >= (double)budget_us)
            break;

        int idx = P.next_tile;
        P.next_tile = (P.next_tile + 1) % TILES_N;

        int tx = idx % TILES_X;
        int ty = idx / TILES_X;

        if (!P.full_repaint && !tile_dirty(tx, ty))
            continue;

        if (push_tile(bus, tx, ty) != 0) {
            /* Contained: log sparsely, never propagate. */
            if (++P.errors >= MAX_CONSEC_ERRORS) {
                fprintf(stderr, "am01_panel: %d consecutive bus errors, "
                                "disabling the panel for this run\n", P.errors);
                P.enabled = 0;
            }
            return pushed;
        }
        P.errors = 0;
        pushed++;

        /* A full repaint is complete once the scan has wrapped. */
        if (P.full_repaint && P.next_tile == 0)
            P.full_repaint = 0;
    }
    return pushed;
}

void am01_panel_shutdown(am01_bus_t *bus)
{
    if (P.enabled && bus) {
        (void)am01_bus_lcd_ctrl(bus, 1, 0);   /* backlight off */
        (void)cmd(bus, ILI_DISPOFF);
    }
    if (P.shadow) { free(P.shadow); P.shadow = NULL; }
    if (P.fb)     { munmap(P.fb, P.fb_bytes); P.fb = NULL; }
    if (P.fb_fd >= 0) { close(P.fb_fd); P.fb_fd = -1; }
    P.enabled = 0;
}
