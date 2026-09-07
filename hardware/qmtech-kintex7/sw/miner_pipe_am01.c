/*
 * miner_pipe.c — Stratum mining daemon for the PIPELINED OdoCrypt FPGA core.
 *
 * Counterpart to miner.c (sequential FSM). The pipelined bitstream bakes the
 * epoch in and free-runs, so this daemon is much simpler than the FSM one:
 *   - no epoch-table streaming (verify the baked-in REG_PIPE_SEED instead),
 *   - no nonce-range allocation (the core sweeps all nonces continuously),
 *   - on each new job: build the header, write header+target+COMMIT,
 *   - poll the found-FIFO, validate each nonce against the current job with the
 *     oracle (== upstream odocrypt.cpp), and submit the ones that meet target.
 *
 * Validating against the *current* job is also the stale-job guard: a nonce
 * computed for a previous header (one that slipped past the wrapper's settle
 * window) recomputes to a non-qualifying hash and is dropped.
 *
 * Usage: odo-miner-pipe <host> <port> <worker> [pass]
 *   (or STRATUM_HOST / STRATUM_PORT / STRATUM_WORKER env vars)
 */

#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE          /* sync(), reboot() */

#include "stratum.h"
#include "job.h"
#include "odocrypt_header.h"
#include "odocrypt_state.h"
#include "KeccakP-800-SnP.h"
#include "miner_io_pipe.h"
/* thermal_am01.h, NOT the sibling repo's thermal.h. That one drives a
 * DS18B20 over a bit-banged one-wire bus on a Cyclone V Avalon-MM PIO via
 * /dev/mem; none of those three things exist on this board, so
 * thermal_init() failed here and temp_c/fan_rpm stayed at -1 on the
 * dashboard. Same API, FPGA registers underneath. */
#include "thermal_am01.h"
/* CYD front panel. A THREAD, not a daemon: libgpiod line requests are
 * exclusive and this process holds all 25 lines, so nothing else can open
 * the bus while the miner runs. Safe because am01_gpio_bus.c serialises
 * every transaction. */
#include "cyd_panel.h"
/* cyd_panel_stop() MUST be called before miner_io_pipe_shutdown(): the
 * panel thread holds the am01_bus_t pointer it was handed at creation,
 * and shutdown destroys the bus mutex and frees it. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
#include <signal.h>
#include <time.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <linux/wireless.h>
#include <math.h>
#include <pthread.h>
#include <unistd.h>
#include <errno.h>
#include <sys/reboot.h>

static volatile sig_atomic_t g_term = 0;
static void on_sig(int s) { (void)s; g_term = 1; }

/* Epoch state for share validation — generated once to match the bitstream. */
static odo_epoch_state_t g_epoch;

static void sleep_ms(unsigned ms)
{
    struct timespec ts = { ms / 1000u, (long)(ms % 1000u) * 1000000L };
    nanosleep(&ts, NULL);
}

/* OdoCrypt + Keccak PoW for (header, nonce), nonce injected at bytes 76..79. */
/* AM01 LOCAL COPY of odo-miner-cyclonev/hps/miner_pipe.c.
 *
 * Copied rather than edited in place: that repo is a separate project and the
 * Cyclone V build has different hardware underneath it, so a change that is
 * right here is not automatically right there.
 *
 * DIVERGENCE FROM THE ORIGINAL -- keep this list current:
 *
 *   1. A found nonce is validated and submitted against the job it was
 *      DISPATCHED for, not against whatever job is current when it is drained.
 *      See the `disp` job below.
 *
 * Everything else is byte-identical to the sibling as of 2026-08-30. If you
 * pull an update from there, re-apply the list above rather than diffing by
 * eye.
 */
static void compute_pow(const uint8_t header[80], uint32_t nonce, uint8_t hash[32])
{
    uint8_t st[KeccakP800_stateSizeInBytes];
    memset(st, 0, sizeof(st));
    memcpy(st, header, 80);
    st[76] = (uint8_t)(nonce);       st[77] = (uint8_t)(nonce >> 8);
    st[78] = (uint8_t)(nonce >> 16); st[79] = (uint8_t)(nonce >> 24);
    st[80] = 1;
    odo_encrypt(&g_epoch, st, st);
    KeccakP800_Permute_12rounds(st);
    memcpy(hash, st, 32);
}

/* uint256 hash <= target (little-endian, byte[31] = MSB). */
static int target_met(const uint8_t hash[32], const uint8_t target[32])
{
    for (int i = 31; i >= 0; i--) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 1;
}

/* -----------------------------------------------------------------------
 * Status JSON — same schema odod writes, so odo-ui / odo-webd render the
 * pipelined miner on the screen + web dashboard with no changes.
 * ---------------------------------------------------------------------- */
static struct {
    char     pool[80];
    int      connected;
    char     job_id[JOB_MAX_JOBID_LEN];
    uint32_t epoch;             /* CURRENT JOB's epoch (overwritten per job)  */
    uint32_t bitstream_epoch;   /* FPGA's baked-in epoch (fixed at startup) -
                                  * the authoritative epoch-renewal trigger is
                                  * epoch != bitstream_epoch, not a wall-clock
                                  * guess (see epoch-update.sh) */
    uint32_t epoch_interval;
    uint64_t found;
    uint64_t shares;
    uint64_t shares_accepted;   /* pool-confirmed result:true (H3)  */
    uint64_t shares_rejected;   /* pool-confirmed result:false (H3) */
    time_t   last_share;
    time_t   started;
    double   work_acc;        /* cumulative expected hashes from accepted shares */
    double   hashrate;        /* H/s = work_acc / uptime (pool-style estimate)   */
    double   best_diff_session; /* highest difficulty share this run */
    double   best_diff_alltime; /* highest difficulty share ever (persisted) */
    uint64_t blocks_found;      /* shares that ALSO met the network target,
                                  * ever (persisted) — a genuine found block,
                                  * not just a pool share */
    time_t   last_block;        /* unix time of the most recent block (0 = none yet) */
    int      temp_c;            /* DS18B20 reading, -1 = no sensor/no reading yet */
    /* XADC supply rails, volts. -1 = not read yet.
     *
     * This board has NO current sense: XADC gives temperature and these
     * three voltages and nothing else. The 1.0V core rail comes from an
     * MP8712 rated 12A, and the panel firmware already notes the miner
     * drawing about that -- so how hard the core is being pushed shows up
     * only as VCCINT drooping. Read from the thermal thread, which holds
     * the bus once a second anyway. Reading them by stopping the miner,
     * the only way before, gives an IDLE value: exactly the case that
     * cannot show load. */
    double   vccint, vccaux, vccbram;
    int      fan_pct;           /* current commanded fan speed, 0-100 (%) */
    int      fan_rpm;           /* tach-measured RPM, -1 = no tach */
    int      pool_slot;         /* active pool: 1 = primary, 2 = backup */
    int      pool_count;        /* number of configured pools (1 or 2) */
} g_st;

/* UI control files (odo-ui touches these; the daemon polls them): */
#define FAN_BOOST_PATH   "/run/odod/fan_boost"     /* present => force fan 100% */
#define RESET_STATS_PATH "/run/odod/reset_stats"   /* present => reset session stats */

/* -----------------------------------------------------------------------
 * Thermal monitoring runs on its own thread so a tach-sampling window
 * (thermal_tach_rpm blocks for its full duration) never delays draining
 * the FPGA's 1-deep found-FIFO. g_therm_mu only guards the three fields
 * above between this thread and status_write() on the main thread.
 * ---------------------------------------------------------------------- */
static pthread_mutex_t g_therm_mu = PTHREAD_MUTEX_INITIALIZER;

/* Reset button (pio_thermal bit2): hold ~2 s to reboot. Polled at 10 Hz during
 * the thermal thread's idle window; the line idles high, so a floating/unpressed
 * pin never triggers, and the long hold rules out accidental brushes. */
#define RESET_HOLD_TICKS  20   /* 20 x 100 ms = ~2 s held */

static void *thermal_thread(void *arg)
{
    (void)arg;
    if (thermal_init() != 0)
        fprintf(stderr, "[pipe] thermal_init failed; fan control disabled\n");

    int reset_held = 0;
    int read_fail = 0;
    while (!g_term) {
        int t;
        if (thermal_read_c(&t) == 0) {
            read_fail = 0;
            if (access(FAN_BOOST_PATH, F_OK) == 0)
                thermal_fan_set_pct(100);   /* UI-forced full speed (soak/stress) */
            else
                thermal_fan_update(t);       /* normal temperature ramp */
            int rpm = thermal_tach_rpm(200);
            double vi = -1, va = -1, vb = -1;
            (void)thermal_read_rails(&vi, &va, &vb);   /* best effort */
            pthread_mutex_lock(&g_therm_mu);
            g_st.temp_c  = t;
            g_st.vccint  = vi;
            g_st.vccaux  = va;
            g_st.vccbram = vb;
            g_st.fan_pct = thermal_fan_state();
            g_st.fan_rpm = rpm;
            pthread_mutex_unlock(&g_therm_mu);
        } else if (++read_fail >= 3) {
            /* Sustained sensor-read failure: force the fan to full as a
             * thermal-safety default rather than holding the last duty — this
             * board browns out at T=6 if it overheats. */
            thermal_fan_set_pct(100);
            pthread_mutex_lock(&g_therm_mu);
            g_st.fan_pct = thermal_fan_state();
            pthread_mutex_unlock(&g_therm_mu);
        }
        /* Idle window doubles as the reset-button poll (10 Hz). */
        for (int i = 0; i < 20 && !g_term; i++) {
            if (thermal_reset_pressed()) {
                if (++reset_held >= RESET_HOLD_TICKS) {
                    /* reboot() directly — NOT system("reboot"): fork() in this
                     * worker thread while the main thread holds malloc/stdio
                     * locks can deadlock the child before exec. sync()+reboot()
                     * are bare syscalls, no fork. */
                    fprintf(stderr, "[pipe] reset button held -- rebooting\n");
                    sync();
                    reboot(RB_AUTOBOOT);
                    fprintf(stderr, "[pipe] reboot() failed: %s\n", strerror(errno));
                    reset_held = 0;
                }
            } else {
                reset_held = 0;
            }
            sleep_ms(100);
        }
    }
    thermal_shutdown();
    return NULL;
}

/* -----------------------------------------------------------------------
 * best_diff_alltime / blocks_found persistence — separate file from the FSM
 * daemon's /var/lib/odod/stats (different share-counting semantics; only
 * the all-time records would make sense to share, not worth the format
 * coordination between two independently-evolving daemons).
 * ---------------------------------------------------------------------- */
#define PIPE_STATS_PATH "/var/lib/odod/stats_pipe"

static void stats_load(void)
{
    FILE *f = fopen(PIPE_STATS_PATH, "r");
    if (!f) return;
    double best = 0.0;
    unsigned long long blocks = 0;
    int n = fscanf(f, "%lf %llu", &best, &blocks);
    if (n >= 1)
        g_st.best_diff_alltime = best;
    if (n >= 2)
        g_st.blocks_found = blocks;
    fclose(f);
}

/* Difficulty and block bookkeeping for a share that has just been submitted.
 * Returns the share's difficulty so the caller can log it.
 *
 * FACTORED OUT because it existed on only ONE of the two drain paths. The
 * handover drain -- the few hundred microseconds while a new job's 27 words
 * are being written, during which the core is still returning nonces for the
 * previous job -- submitted its shares correctly and then recorded none of
 * this: no difficulty, no best_diff_session, no best_diff_alltime, no
 * target_met against the NETWORK target, no blocks_found, no last_block, no
 * banner, and no stats_save(). A genuine block found in that window would
 * have been paid by the pool and left no local trace whatsoever.
 *
 * Copying the block into the second path would have fixed today's bug and
 * left the next one; one function called from both cannot drift. */
/* JSON string escaping for the few fields that are not ours.
 *
 * status.json interpolates the pool's job_id, the access point's SSID, and
 * the configured worker straight into quoted values. A pool issuing a job_id
 * of a"b -- or an SSID containing a quote or a trailing backslash -- produced
 * a syntactically invalid file, and odo-webd, odo-ui and the CYD panel all
 * failed to parse it. The panel then displays MINER DOWN while the miner is
 * mining perfectly, which is the worst kind of wrong: it invites someone to
 * go and "fix" a healthy board.
 *
 * Escaping rather than rejecting, because these values are not ours to
 * refuse -- the pool picks the job_id and the neighbour picks the SSID. */
static const char *json_str(const char *in, char *out, size_t cap)
{
    size_t o = 0;
    if (!in) in = "";
    for (; *in && o + 7 < cap; in++) {
        unsigned char c = (unsigned char)*in;
        if (c == '"' || c == '\\') {
            out[o++] = '\\'; out[o++] = (char)c;
        } else if (c < 0x20) {
            /* Control characters are not legal raw in a JSON string, and a
             * stray one from a corrupted line would break the file just as
             * surely as a quote. */
            o += (size_t)snprintf(out + o, cap - o, "\\u%04x", c);
        } else {
            out[o++] = (char)c;
        }
    }
    out[o] = '\0';
    return out;
}

static void stats_save(void);
static double hash_to_difficulty(const uint8_t hash_le[32]);

static double account_share(const uint8_t h[32], const job_t *j,
                            uint32_t nonce, const char *tag)
{
    double d = hash_to_difficulty(h);

    if (d > g_st.best_diff_session)
        g_st.best_diff_session = d;
    int new_best = (d > g_st.best_diff_alltime);
    if (new_best)
        g_st.best_diff_alltime = d;

    /* j->target is the NETWORK target; j->share_target is the pool's. Only
     * the former makes it a block. */
    int is_block = target_met(h, j->target);
    if (is_block) {
        g_st.blocks_found++;
        g_st.last_block = time(NULL);
        printf("[pipe] *** BLOCK FOUND ***%s job=%s nonce=0x%08" PRIx32
               " diff=%.6g (blocks_found=%" PRIu64 ")\n",
               tag, j->job_id, nonce, d, g_st.blocks_found);
    }
    if (new_best || is_block)
        stats_save();
    return d;
}

static void stats_save(void)
{
    FILE *f = fopen(PIPE_STATS_PATH ".tmp", "w");
    if (!f) {
        /* ONCE. This failed silently from the day it was written -- the unit
         * creates /run/odod but nothing created /var/lib/odod -- so the
         * all-time best difficulty reset on every restart and nothing ever
         * said why. A save that cannot happen is worth exactly one line. */
        static int moaned;
        if (!moaned) {
            moaned = 1;
            fprintf(stderr, "[pipe] cannot write %s: %s -- all-time stats "
                            "will not survive a restart\n",
                    PIPE_STATS_PATH ".tmp", strerror(errno));
        }
        return;
    }
    fprintf(f, "%.6g %" PRIu64 "\n", g_st.best_diff_alltime, g_st.blocks_found);
    fclose(f);
    rename(PIPE_STATS_PATH ".tmp", PIPE_STATS_PATH);
}

/* Difficulty of a 32-byte LE hash relative to the OdoCrypt diff-1 target
 * (0xFFFF << 208). Uses the top bytes for a good double approximation.
 * Mirrors miner.c's hash_to_difficulty exactly (same diff-1 convention). */
static double hash_to_difficulty(const uint8_t hash_le[32])
{
    double h = 0.0;
    int i;
    for (i = 31; i >= 24; i--)
        h = h * 256.0 + (double)hash_le[i];
    if (h < 1.0) {
        for (i = 23; i >= 16; i--)
            h = h * 256.0 + (double)hash_le[i];
        if (h < 1.0) return 1e15;
        return (double)0xFFFF0000U / h * 18446744073709551616.0;
    }
    return (double)0xFFFF0000U / h;
}

/* Expected number of hashes represented by one share at this target:
 * P(hash <= target) = target / 2^256, so each accepted share is ~2^256/target
 * hashes of work. The free-running core has no hardware hash counter, so this
 * statistical estimate (summed over accepted shares / uptime) is the only sound
 * hashrate measure — the found nonces themselves are random, not a sweep count.
 * target is little-endian (byte[31] = MSB). */
static double share_work(const uint8_t target[32])
{
    double tv = 0.0;
    for (int i = 31; i >= 0; i--) tv = tv * 256.0 + (double)target[i];
    if (tv <= 0.0) return 0.0;
    return ldexp(1.0, 256) / tv;          /* 2^256 / target */
}

/* Monotonic seconds — immune to the wall-clock step when the board's clock
 * syncs after boot (using time(NULL) for elapsed gave uptime ~= now and
 * hashrate ~= 0 because g_st.started was captured at ~unix 0). */
static double g_mono_start;
static double mono_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/*
 * First non-loopback IPv4, or "" if the box has no address yet.
 *
 * Looked up fresh on every status write rather than cached: DHCP leases
 * change, wlan0 comes and goes, and a panel confidently showing the address
 * the miner had an hour ago is worse than one showing nothing. It is a couple
 * of syscalls every three seconds.
 */
/*
 * The SSID wlan0 is currently associated with, or "" if none.
 *
 * SIOCGIWESSID is the old wireless-extensions ioctl. cfg80211 still answers it
 * for a station interface, and it costs two syscalls -- the alternative is a
 * netlink conversation or shelling out to iw, and neither is worth it for one
 * string. A failure here is not an error: an unassociated radio, a missing
 * interface and a driver without WEXT all mean the same thing to the panel,
 * which is "nothing to show".
 */
static void wifi_ssid(char *out, size_t n)
{
    out[0] = '\0';

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return;

    char buf[IW_ESSID_MAX_SIZE + 1];
    memset(buf, 0, sizeof buf);

    struct iwreq wrq;
    memset(&wrq, 0, sizeof wrq);
    snprintf(wrq.ifr_name, sizeof wrq.ifr_name, "%s", "wlan0");
    wrq.u.essid.pointer = buf;
    wrq.u.essid.length  = IW_ESSID_MAX_SIZE;

    if (ioctl(fd, SIOCGIWESSID, &wrq) == 0 && wrq.u.essid.length > 0) {
        buf[IW_ESSID_MAX_SIZE] = '\0';
        snprintf(out, n, "%s", buf);
    }
    close(fd);
}

/*
 * Signal level of the associated network, in dBm. 0 when unknown.
 *
 * /proc/net/wireless rather than another ioctl: it is one open and one line,
 * the kernel already maintains it, and it needs no privileges. The columns are
 *
 *     iface: status  link  level  noise  ...
 *
 * and the values carry a trailing '.', which is why they are read as floats
 * and rounded rather than parsed as integers.
 *
 * A level of 0 means "no idea" -- unassociated, no wlan0, or a driver that
 * does not fill this in -- and the panel draws that as no bars rather than as
 * a very weak signal, which would be a different and wrong claim.
 */
static int wifi_rssi(void)
{
    FILE *f = fopen("/proc/net/wireless", "r");
    if (!f)
        return 0;

    char line[256];
    int  rssi = 0;
    while (fgets(line, sizeof line, f)) {
        char *p = strstr(line, "wlan0:");
        if (!p)
            continue;
        p += 6;
        float status, link, level;
        if (sscanf(p, "%f %f %f", &status, &link, &level) == 3)
            rssi = (int)level;
        break;
    }
    fclose(f);
    return rssi;
}

/*
 * Is a WPA passphrase configured? The file is 0600 root and this runs as
 * miner, so it cannot be read -- but stat() answers the only question the
 * panel asks, which is whether one is there at all. The panel shows that a
 * password is set; it never shows the password.
 */
static int wifi_psk_configured(void)
{
    struct stat stbuf;
    if (stat("/etc/wpa_supplicant/wpa_supplicant-wlan0.conf", &stbuf) != 0)
        return 0;
    return stbuf.st_size > 0;
}

/* The stratum worker, as given on the command line. Published so
 * the panel can SHOW what is configured: it is a separate device
 * and argv is not something it can see. */
static char g_worker[96];

static void first_ipv4(char *out, size_t n)
{
    out[0] = '\0';

    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0)
        return;

    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET)
            continue;
        if (p->ifa_flags & IFF_LOOPBACK)
            continue;
        if (!(p->ifa_flags & IFF_UP))
            continue;
        inet_ntop(AF_INET,
                  &((struct sockaddr_in *)p->ifa_addr)->sin_addr, out, n);
        break;
    }
    freeifaddrs(ifa);
}

static void status_write(void)
{
    const char *path = getenv("ODOD_STATUS_FILE");
    if (!path) path = "/run/odod/status.json";
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    time_t now = time(NULL);
    char ip[INET_ADDRSTRLEN] = "";
    first_ipv4(ip, sizeof ip);
    char wssid[IW_ESSID_MAX_SIZE + 1] = "";
    wifi_ssid(wssid, sizeof wssid);
    /* Escaped copies. Sized x6 + 1 because the worst case is every byte
     * expanding to a six-character backslash-u escape. */
    char jbuf_pool[sizeof g_st.pool * 6 + 1];
    char jbuf_ip[sizeof ip * 6 + 1];
    char jbuf_worker[sizeof g_worker * 6 + 1];
    char jbuf_ssid[sizeof wssid * 6 + 1];
    char jbuf_job[sizeof g_st.job_id * 6 + 1];
    double up = mono_s() - g_mono_start;          /* elapsed, clock-step safe */
    g_st.hashrate = (up > 0.0) ? g_st.work_acc / up : 0.0;
    /* long long, not long: on 32-bit ARM `long` is 32-bit and these Unix-time
     * values truncate past 2038 (the epoch sum already sits near 1.78e9). */
    long long enext = (g_st.epoch && g_st.epoch_interval)
               ? (long long)g_st.epoch + (long long)g_st.epoch_interval : 0LL;
    pthread_mutex_lock(&g_therm_mu);
    int temp_c = g_st.temp_c, fan_pct = g_st.fan_pct, fan_rpm = g_st.fan_rpm;
    double vccint = g_st.vccint, vccaux = g_st.vccaux, vccbram = g_st.vccbram;
    pthread_mutex_unlock(&g_therm_mu);
    fprintf(f,
        "{\n"
        "  \"pool\": \"%s\",\n"
        "  \"ip\": \"%s\",\n"
        "  \"worker\": \"%s\",\n"
        "  \"wifi_ssid\": \"%s\",\n"
        "  \"wifi_psk_set\": %s,\n"
        "  \"wifi_rssi\": %d,\n"
        "  \"connected\": %s,\n"
        "  \"core\": \"pipelined\",\n"
        "  \"job_id\": \"%s\",\n"
        "  \"epoch\": %" PRIu32 ",\n"
        "  \"bitstream_epoch\": %" PRIu32 ",\n"
        "  \"epoch_interval\": %" PRIu32 ",\n"
        "  \"epoch_next\": %lld,\n"
        "  \"hashrate\": %.1f,\n"
        "  \"hashes_total\": 0,\n"
        "  \"shares_found\": %" PRIu64 ",\n"
        "  \"shares_submitted\": %" PRIu64 ",\n"
        "  \"shares_accepted\": %" PRIu64 ",\n"
        "  \"shares_rejected\": %" PRIu64 ",\n"
        "  \"last_share\": %lld,\n"
        "  \"best_diff_session\": %.6g,\n"
        "  \"best_diff_alltime\": %.6g,\n"
        "  \"blocks_found\": %" PRIu64 ",\n"
        "  \"last_block\": %lld,\n"
        "  \"temp_c\": %d,\n"
        "  \"vccint\": %.3f,\n"
        "  \"vccaux\": %.3f,\n"
        "  \"vccbram\": %.3f,\n"
        "  \"fan_duty_pct\": %d,\n"
        "  \"fan_rpm\": %d,\n"
        "  \"backend\": \"%s\",\n"
        "  \"pool_slot\": %d,\n"
        "  \"pool_count\": %d,\n"
        "  \"uptime\": %lld,\n"
        "  \"updated\": %lld\n"
        "}\n",
        /* ESCAPED. The pool picks job_id and the neighbour picks the SSID,
         * and either can contain a quote or a backslash -- which made
         * status.json unparseable and had the panel report MINER DOWN on a
         * perfectly healthy miner. pool/ip/worker are ours, but go through
         * the same path so nothing here is a special case. */
        json_str(g_st.pool,  jbuf_pool,   sizeof jbuf_pool),
        json_str(ip,         jbuf_ip,     sizeof jbuf_ip),
        json_str(g_worker,   jbuf_worker, sizeof jbuf_worker),
        json_str(wssid,      jbuf_ssid,   sizeof jbuf_ssid),
        wifi_psk_configured() ? "true" : "false",
        wifi_rssi(),
        g_st.connected ? "true" : "false",
        json_str(g_st.job_id, jbuf_job, sizeof jbuf_job),
        g_st.epoch, g_st.bitstream_epoch, g_st.epoch_interval, enext, g_st.hashrate,
        g_st.found, g_st.shares, g_st.shares_accepted, g_st.shares_rejected,
        (long long)g_st.last_share,
        g_st.best_diff_session, g_st.best_diff_alltime,
        g_st.blocks_found, (long long)g_st.last_block,
        temp_c, vccint, vccaux, vccbram, fan_pct, fan_rpm, miner_io_pipe_backend(),
        g_st.pool_slot, g_st.pool_count,
        (long long)up, (long long)now);
    fclose(f);
    rename(tmp, path);
}

int main(int argc, char **argv)
{
    const char *host   = argc > 1 ? argv[1] : getenv("STRATUM_HOST");
    const char *port   = argc > 2 ? argv[2] : getenv("STRATUM_PORT");
    const char *worker = argc > 3 ? argv[3] : getenv("STRATUM_WORKER");
    if (worker)
        snprintf(g_worker, sizeof g_worker, "%s", worker);
    const char *pass   = argc > 4 ? argv[4] : "x";
    if (!host || !port || !worker) {
        fprintf(stderr, "usage: %s <host> <port> <worker> [pass]\n", argv[0]);
        return 1;
    }

    signal(SIGINT,  on_sig);
    signal(SIGTERM, on_sig);

    if (miner_io_pipe_init() != 0) {
        fprintf(stderr, "[pipe] miner_io_pipe_init failed (run as root?)\n");
        return 1;
    }
    uint32_t seed = miner_io_pipe_seed();
    uint32_t ver  = miner_io_pipe_version();
    printf("[pipe] FPGA epoch=%" PRIu32 " (0x%08" PRIx32 ") version=0x%08" PRIx32 "\n",
           seed, seed, ver);
    odo_epoch_generate(&g_epoch, seed);   /* validation uses the baked-in epoch */

    /* CYD front panel. AFTER miner_io_pipe_init(), which opens the bus it
     * shares -- cyd_panel.h says so, and starting it before the init was the
     * first thing I got wrong here: it logged "bus not open" and disabled
     * itself, which is the failure behaving as designed but still a failure.
     *
     * Its return value is deliberately ignored. A bitstream without a UART,
     * or a panel that is simply not fitted, must never stop the miner; it
     * logs its own reason either way. */
    (void)cyd_panel_start();

    /* Optional backup pool: tried alternately after each failed connect. */
    const char *hosts[2] = { host, getenv("ODOD_POOL_HOST2") };
    const char *ports[2] = { port, getenv("ODOD_POOL_PORT2") };
    int n_pools  = (hosts[1] && hosts[1][0] && ports[1] && ports[1][0]) ? 2 : 1;
    int pool_idx = 0;
    if (n_pools > 1)
        printf("[pipe] backup pool configured: %s:%s\n", hosts[1], ports[1]);

    /* Seed the status struct: pool string, epoch params, start time. */
    snprintf(g_st.pool, sizeof(g_st.pool), "%s:%s", host, port);
    g_st.pool_count      = n_pools;
    g_st.pool_slot       = pool_idx + 1;
    g_st.epoch           = seed;   /* overwritten per job below */
    g_st.bitstream_epoch = seed;   /* fixed: what's actually baked into the FPGA */
    g_st.started = time(NULL);
    g_st.temp_c  = -1;             /* no reading yet */
    g_st.vccint  = -1;
    g_st.vccaux  = -1;
    g_st.vccbram = -1;
    g_st.fan_rpm = -1;
    g_mono_start = mono_s();       /* clock-step-safe uptime baseline */
    stats_load();                  /* best_diff_alltime, survives reboots */
    status_write();

    pthread_t therm_tid;
    int have_therm = (pthread_create(&therm_tid, NULL, thermal_thread, NULL) == 0);
    if (!have_therm)
        fprintf(stderr, "[pipe] failed to start thermal thread\n");

    stratum_ctx_t st;
    if (stratum_init(&st, host, port, worker, pass) != 0) {
        fprintf(stderr, "[pipe] stratum_init failed\n");
        cyd_panel_stop();          /* before the bus it uses is freed */
        miner_io_pipe_shutdown();
        return 1;
    }
    g_st.epoch_interval = st.odo_interval;   /* from ODO_TESTNET/ODO_EPOCH_INTERVAL */

    job_t cur; job_init(&cur);
    int have_cur = 0;

    /* The job the FPGA is ACTUALLY working on.
     *
     * This is not the same thing as `cur`. The core halts on every find
     * (host_break_sm asserts on ticket2moon and the wrapper clears
     * start_hash_h), so a nonce belongs to whichever job armed the core. The
     * pool pushes a new job every 3-10 s, so `cur` has usually advanced by the
     * time that nonce is drained -- and hashing it against the newer header
     * cannot possibly meet the target. Every find was being discarded that
     * way: found=38, shares=0, stale=38 on hardware.
     *
     * Stratum accepts a share for an earlier job unless clean_jobs was set,
     * so these are real, submittable shares. */
    job_t disp; job_init(&disp);
    int have_disp = 0;

    /* The first find after a NEW job is not a solution -- see the file banner.
     * miner.v's 204-cycle warm-up does not cover this build's pipeline, so
     * results computed with the previous header emerge first, wearing nonces
     * from the new sweep. Drop exactly one per job. */
    int discard_first = 0;
    uint64_t discarded = 0;

    /* Only bitstreams BEFORE 0x0108 need the discard.
     *
     * 0x0108 fixes the real cause in miner.v -- nonce_out was gated on
     * nonce_out_go, so results arriving before the warm-up went uncounted and
     * the counter lost sync with the result stream permanently. With that
     * fixed, the first find after an arm is a genuine solution and discarding
     * it would throw away a real share on every job.
     *
     * So this must NOT simply be left in place after the rebuild. Gated on the
     * version the hardware reports, the same way the double-arm workaround is,
     * so flashing 0x0108 retires it with no coordination.
     *
     * miner_io_pipe_version() returns major<<16 | minor (v1.8 -> 0x00010008),
     * not the raw 16-bit VERSION register (0x0108). Masking that with 0xFFFF
     * threw away the major byte and left only the minor (0x0008), which is
     * always < 0x0108u -- so this never retired regardless of the flashed
     * version. Compare against the same encoding the getter produces instead
     * of the raw register value. */
    const uint32_t fpga_ver = miner_io_pipe_version();
    const int warmup_broken = (fpga_ver < ((1u << 16) | 8u));

    /* v2.0 (0x0200 -> major 2) replaced the halt-on-find AtomMiner core with
     * the free-running one. Below that, the core stops dead on every find and
     * the host must re-arm it. At or above it, re-dispatching would re-commit
     * the job and reopen the settle window instead -- see the RE-ARM comment
     * in the drain loop. */
    const int rearm_on_find = ((fpga_ver >> 16) < 2u);
    fprintf(stderr, "[pipe] FPGA v%u.%u: %s\n",
            fpga_ver >> 16, fpga_ver & 0xFFFFu,
            rearm_on_find ? "halt-on-find core, re-arming after each find"
                          : "free-running core, no re-arm");
    if (warmup_broken)
        fprintf(stderr, "[pipe] FPGA v%u.%u predates the nonce_out fix; "
                        "discarding the first find of each job\n",
                        fpga_ver >> 16, fpga_ver & 0xFFFFu);
    uint64_t found = 0, shares = 0, stale = 0;
    time_t last_status = 0;

    /* Per-core validity accounting.
     *
     * The two miner_pipelined instances are given INONCE
     * gi * ((32'hFFFFFFFF / NUM_MINERS) + 1), i.e. 0x00000000 and 0x80000000
     * (odocrypt_gpio_wrapper.v, the NUM_MINERS generate loop). Each sweeps its
     * own half of the nonce space and takes ~43s at 50MH/s to get round it, so
     * bit 31 of a returned nonce identifies the instance that found it and
     * stays put for the whole run.
     *
     * Split found/ok on that bit and a core that is producing bad digests
     * shows up immediately as a lopsided pass rate. An even split says the
     * corruption is global, and FIFO_STAT.lost then says whether the found
     * path is congested or the cipher itself is wrong. */
    uint64_t core_found[2] = { 0, 0 };
    uint64_t core_ok[2]    = { 0, 0 };

    /* Neighbour histogram for stale finds: index d+4 counts stales whose
     * digest at nonce+d WOULD have met the target. Index 4 (d = 0) stays zero
     * by construction -- that case is a share, not a stale. */
    uint64_t nbr_hit[2][9] = { { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                               { 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    uint64_t nbr_none[2]   = { 0, 0 };
    uint64_t recovered[2]  = { 0, 0 };   /* shares saved by the -1 retry */
    time_t   last_corestat = 0;

    /* Whole-job clustering. A commit that snapshots a half-loaded header makes
     * EVERY find for that job invalid, so runs of stale bounded by job changes
     * look different from corruption scattered across jobs. */
    char     stale_job[64]  = "";
    uint32_t stale_run      = 0;
    uint32_t stale_run_max  = 0;

    while (!g_term) {
        if (stratum_connect(&st) != 0) {
            fprintf(stderr, "[pipe] connect %s:%s failed; retry in 5 s\n",
                    hosts[pool_idx], ports[pool_idx]);
            g_st.connected = 0;
            status_write();
            if (n_pools > 1) {
                pool_idx = (pool_idx + 1) % n_pools;
                g_st.pool_slot = pool_idx + 1;
                if (stratum_init(&st, hosts[pool_idx], ports[pool_idx], worker, pass) != 0) {
                    /* Only fails on NULL args, which can't happen here (all four
                     * come from validated argv/env at startup) — but don't mine
                     * blind against a zeroed ctx if that assumption ever breaks. */
                    fprintf(stderr, "[pipe] stratum_init failed for backup pool %s:%s\n",
                            hosts[pool_idx], ports[pool_idx]);
                    sleep_ms(5000);
                    continue;
                }
                g_st.epoch_interval = st.odo_interval;
                snprintf(g_st.pool, sizeof(g_st.pool), "%s:%s",
                         hosts[pool_idx], ports[pool_idx]);
                printf("[pipe] switching to pool %s:%s\n",
                       hosts[pool_idx], ports[pool_idx]);
            }
            sleep_ms(5000);
            continue;
        }
        printf("[pipe] connected to %s:%s\n", hosts[pool_idx], ports[pool_idx]);
        have_cur = 0;
        have_disp = 0;   /* nothing is armed on the FPGA across a reconnect */
        g_st.connected = 1;
        status_write();

        while (!g_term) {
            /* WS3b: pace the loop on the found-nonce wait, then service stratum
             * non-blocking. The UIO backend blocks on the found-nonce IRQ (waking
             * the drain the instant a nonce lands); the /dev/mem backend does a
             * bounded ~5 ms nap (returning early if one is already pending), so
             * both keep the ~200/s drain that the 1-deep found-latch needs (a
             * 50 ms cap previously dropped most finds, incl. potential blocks).
             *
             * A negative return means the backend itself has faulted (mmap/fd
             * gone bad) — spinning on that with no backoff would peg the single
             * ARM core with no chance of recovery. Back off and let the loop's
             * own connection-retry cadence apply; if the fault is permanent, the
             * hardware watchdog (if enabled) or an operator restart recovers it. */
            if (miner_io_pipe_wait(5) < 0) {
                fprintf(stderr, "[pipe] miner_io backend error; backing off\n");
                sleep_ms(1000);
                continue;
            }
            if (stratum_poll(&st, 0) < 0) {
                fprintf(stderr, "[pipe] poll error; reconnecting\n");
                break;
            }

            /* Drain the found-FIFO FIRST, validating against whatever job is
             * CURRENTLY live in `cur` — a nonce sitting in the FIFO was found
             * for that job, not for a new job that might arrive this same
             * iteration below. Doing this before a possible dispatch() of a new
             * job (which used to happen first) prevents a genuine find from
             * being checked against the wrong header and silently bucketed as
             * stale — that was a guaranteed miss on every job switch, not just
             * a race window, since dispatch() ran unconditionally before drain
             * whenever a new job had already arrived in the same tick.
             *
             * Bounded to one FIFO depth's worth of iterations (the hardware FIFO
             * is 8 deep) plus margin, so a stuck FSTATUS.VALID (hardware fault)
             * can't turn this into an infinite loop. */
            if (have_disp) {
                uint32_t nonce;
                int drained = 0;
                while (drained++ < 64 && miner_io_pipe_poll(&nonce) == 0) {
                    if (discard_first && warmup_broken) {
                        /* Poisoned by the too-short warm-up. Not counted as a
                         * find: counting it would make the found/stale ratio
                         * look like a hashing fault, which is what sent this
                         * investigation the wrong way for hours. */
                        discard_first = 0;
                        discarded++;
                        /* Re-arm: the core halted on this find, and without a
                         * fresh dispatch it will sit idle until the next job. */
                        miner_io_pipe_dispatch(disp.header, disp.share_target);
                        continue;
                    }
                    found++;
                    g_st.found = found;
                    core_found[nonce >> 31]++;
                    uint8_t h[32];
                    /* `disp`, NOT `cur` -- see the job_t disp declaration. */
                    compute_pow(disp.header, nonce, h);
                    if (target_met(h, disp.share_target)) {
                        if (stratum_submit_share(&st, &disp, nonce) == 0) {
                            shares++;
                            core_ok[nonce >> 31]++;
                            stale_run = 0;
                            g_st.shares     = shares;
                            g_st.last_share = time(NULL);
                            g_st.work_acc  += share_work(disp.share_target);
                            double d = account_share(h, &disp, nonce, "");
                            printf("[pipe] SHARE job=%s nonce=0x%08" PRIx32
                                   " diff=%.6g (found=%" PRIu64 " shares=%" PRIu64 ")\n",
                                   cur.job_id, nonce, d, found, shares);
                        } else {
                            fprintf(stderr, "[pipe] stratum_submit_share failed\n");
                        }
                    } else if (compute_pow(disp.header, nonce - 1u, h),
                               target_met(h, disp.share_target)) {
                        /* OFF BY ONE, not stale. The digest at nonce-1 meets
                         * the target, so the core hashed correctly and the
                         * found path mislabelled the result. Submit the nonce
                         * that actually works. See the note at `recovered`. */
                        if (stratum_submit_share(&st, &disp, nonce - 1u) == 0) {
                            shares++;
                            core_ok[nonce >> 31]++;
                            recovered[nonce >> 31]++;
                            stale_run = 0;
                            g_st.shares     = shares;
                            g_st.last_share = time(NULL);
                            g_st.work_acc  += share_work(disp.share_target);
                            double d = account_share(h, &disp, nonce - 1u,
                                                     " (off-by-one)");
                            /* Also one in 64: this fires on 40% of finds
                             * when the fault is active, and the RECOVERED
                             * counters already carry the rate. */
                            if ((shares & 63u) == 0u)
                                printf("[pipe] SHARE (off-by-one) job=%s "
                                       "nonce=0x%08" PRIx32 " diff=%.6g\n",
                                       cur.job_id, nonce - 1u, d);
                        } else {
                            fprintf(stderr, "[pipe] stratum_submit_share"
                                            " failed (off-by-one)\n");
                        }
                    } else {
                        /* A REAL stale: neither this nonce nor its predecessor
                         * satisfied the job it was dispatched for. */
                        stale++;
                        if (strcmp(stale_job, disp.job_id) == 0) {
                            stale_run++;
                        } else {
                            snprintf(stale_job, sizeof stale_job, "%s",
                                     disp.job_id);
                            stale_run = 1;
                        }
                        if (stale_run > stale_run_max)
                            stale_run_max = stale_run;

                        /* Was a nonce NEAR this one valid? See the note on
                         * nbr_hit. Nine extra OdoCrypt evaluations per stale
                         * is nothing next to 100 MH/s in fabric, and it only
                         * runs on the failing path. */
                        {
                            int hit = 0;
                            for (int d = -4; d <= 4; d++) {
                                if (d == 0)
                                    continue;
                                uint8_t hn[32];
                                compute_pow(disp.header,
                                            (uint32_t)(nonce + (uint32_t)d),
                                            hn);
                                if (target_met(hn, disp.share_target)) {
                                    nbr_hit[nonce >> 31][d + 4]++;
                                    hit = 1;
                                    break;
                                }
                            }
                            if (!hit)
                                nbr_none[nonce >> 31]++;
                        }
                        /* One in 64. A recurrence still leaves nonces in
                         * the log to inspect, without burying everything else
                         * behind a block-buffered flood. */
                        if ((stale & 63u) == 0u)
                            printf("[pipe] STALE nonce=0x%08" PRIx32
                                   " core=%u job=%s run=%u (stale=%" PRIu64
                                   " of found=%" PRIu64 ")\n",
                                   nonce, (unsigned)(nonce >> 31), disp.job_id,
                                   stale_run, stale, found);
                    }

                    /* RE-ARM after every find, solution or not. The AtomMiner
                     * core halted when it raised ticket2moon; without this it
                     * idles until the next job arrives, which is why the
                     * measured find rate was ~1 per job rather than a
                     * continuous stream.
                     *
                     * MUST NOT be done on v2.0+. There the core free-runs and
                     * never halts, so there is nothing to re-arm -- and a
                     * dispatch is no longer an arm, it is a COMMIT that
                     * restarts the 4096-cycle settle window. Re-committing
                     * after every find would hold that window open essentially
                     * all the time and suppress nearly every find, which would
                     * present exactly like the found>0/shares=0 symptom this
                     * whole line of work started from. */
                    if (rearm_on_find)
                        miner_io_pipe_dispatch(disp.header, disp.share_target);
                }
            }

            job_t nj;
            if (stratum_get_job(&st, &nj)) {
                int same = have_cur && job_same(&nj, &cur);
                if (!same) {
                    cur = nj;
                    have_cur = 1;
                    if (cur.epoch != seed) {
                        fprintf(stderr, "[pipe] WARN job epoch %" PRIu32
                                " != bitstream epoch %" PRIu32 " — bitstream stale;"
                                " shares invalid until reconfigure (Phase 2)\n",
                                cur.epoch, seed);
                    }
                    odocrypt_build_header(&cur, cur.header);

                    /* Keep the OUTGOING job: a find can land while the
                     * dispatch below is still being written, and that find
                     * belongs to this job, not the new one. */
                    job_t prev = disp;
                    int   had_prev = have_disp;

                    miner_io_pipe_dispatch(cur.header, cur.share_target);

                    /* DRAIN THE HANDOVER GAP.
                     *
                     * The loop already drains before dispatching, but a
                     * 27-word dispatch takes a few hundred microseconds over
                     * the bit-banged bus, and a find arriving inside that
                     * window is latched by the FPGA against the OLD job. The
                     * commit at the last target word flushes the found-FIFO
                     * but NOT the already-offered nonce in the handoff latch
                     * -- deliberately, because clearing it from the RTL would
                     * reopen the torn-read window that 0x0201 just closed.
                     *
                     * So it is taken here instead, where the ambiguity does
                     * not exist: this nonce provably predates the commit, and
                     * the job it belongs to is still in hand.
                     *
                     * It is VALIDATED, not discarded. It is a genuine find for
                     * the previous job and the pool will still take it -- the
                     * old job stays current for seconds after a new one
                     * arrives. Throwing away real work to tidy up a race would
                     * be the wrong trade.
                     *
                     * Without this the nonce surfaces on the next iteration
                     * and is checked against the NEW header, where it fails
                     * and is counted stale. Measured: harmless in production
                     * (found=547 shares=547, no bad shares), but it is a real
                     * mismatch and am01_smoke's header-cycling mode shows it
                     * as a 100% failure. */
                    if (had_prev) {
                        uint32_t gap_nonce;
                        int gap_drained = 0;
                        while (gap_drained++ < 8 &&
                               miner_io_pipe_poll(&gap_nonce) == 0) {
                            found++;
                            g_st.found = found;
                            uint8_t gh[32];
                            compute_pow(prev.header, gap_nonce, gh);
                            if (target_met(gh, prev.share_target)) {
                                if (stratum_submit_share(&st, &prev, gap_nonce) == 0) {
                                    shares++;
                                    g_st.shares     = shares;
                                    g_st.last_share = time(NULL);
                                    g_st.work_acc  += share_work(prev.share_target);
                                    /* The accounting the main path does. This
                                     * is where a block could previously be
                                     * submitted and never recorded. */
                                    double gd = account_share(gh, &prev,
                                                              gap_nonce,
                                                              " (handover)");
                                    printf("[pipe] SHARE (handover) job=%s "
                                           "nonce=0x%08" PRIx32 " diff=%.6g\n",
                                           prev.job_id, gap_nonce, gd);
                                }
                            } else {
                                stale++;
                            }
                        }
                    }

                    /* Remember what the FPGA is now working on. Copied AFTER
                     * odocrypt_build_header() so disp.header is the built
                     * header, byte for byte what was pushed to the core. */
                    disp = cur;
                    have_disp = 1;
                    discard_first = 1;   /* drop the warm-up artefact */
                    snprintf(g_st.job_id, sizeof(g_st.job_id), "%s", cur.job_id);
                    g_st.epoch = cur.epoch;
                    printf("[pipe] new job id=%s epoch=%" PRIu32 " dispatched\n",
                           cur.job_id, cur.epoch);
                }
            }
            if (!have_cur) goto status_tick;

        status_tick:
            /* Refresh status.json ~every 3 s for odo-ui / odo-webd. */
            {
                time_t now = time(NULL);
                if (now - last_corestat >= 60) {
                    last_corestat = now;
                    printf("[pipe] CORESTAT "
                           "core0 found=%" PRIu64 " ok=%" PRIu64 " (%.1f%%)  "
                           "core1 found=%" PRIu64 " ok=%" PRIu64 " (%.1f%%)  "
                           "longest_stale_run=%u\n",
                           core_found[0], core_ok[0],
                           core_found[0] ? 100.0 * (double)core_ok[0]
                                                 / (double)core_found[0] : 0.0,
                           core_found[1], core_ok[1],
                           core_found[1] ? 100.0 * (double)core_ok[1]
                                                 / (double)core_found[1] : 0.0,
                           stale_run_max);
                    for (int c = 0; c < 2; c++)
                        printf("[pipe] NEIGHBOUR core%d stale digests valid at "
                               "nonce+d: -4=%" PRIu64 " -3=%" PRIu64 " -2=%"
                               PRIu64 " -1=%" PRIu64 " +1=%" PRIu64 " +2=%"
                               PRIu64 " +3=%" PRIu64 " +4=%" PRIu64
                               "  none=%" PRIu64 "\n", c,
                               nbr_hit[c][0], nbr_hit[c][1], nbr_hit[c][2],
                               nbr_hit[c][3], nbr_hit[c][5], nbr_hit[c][6],
                               nbr_hit[c][7], nbr_hit[c][8], nbr_none[c]);
                    printf("[pipe] RECOVERED core0=%" PRIu64 " core1=%" PRIu64
                           " (shares saved by the -1 retry)\n",
                           recovered[0], recovered[1]);
                    fflush(stdout);
                }

                if (now - last_status >= 3) {
                    last_status = now;
                    /* UI-requested session reset: clear best-diff + restart the
                     * hashrate average. Pool-confirmed share counts are left
                     * alone (they mirror the pool's authoritative view). */
                    if (access(RESET_STATS_PATH, F_OK) == 0) {
                        unlink(RESET_STATS_PATH);
                        g_st.best_diff_session = 0.0;
                        g_st.work_acc = 0.0;
                        g_mono_start = mono_s();
                    }
                    stratum_share_stats(&st, &g_st.shares_accepted,
                                        &g_st.shares_rejected);
                    status_write();
                }
            }
        }
        g_st.connected = 0;
        status_write();
        stratum_disconnect(&st);
    }

    stratum_destroy(&st);

    /* JOIN EVERY BUS USER BEFORE FREEING THE BUS.
     *
     * miner_io_pipe_shutdown() calls am01_bus_close(), which destroys the bus
     * mutex and frees the handle. Both the panel and thermal threads hold
     * that pointer -- the panel captured it at creation and never re-checks
     * miner_io_gpio_bus(), so setting the global to NULL does not protect it.
     *
     * This was a guaranteed use-after-free on EVERY clean exit, including
     * every systemctl restart: a pthread_mutex_lock on a destroyed mutex, a
     * dereference of freed memory, and a half-issued GPIO transaction -- the
     * very "host died mid-transaction" state found_path's soft_reset exists
     * to recover from. The thermal join was already on the wrong side of
     * shutdown for the same reason. */
    cyd_panel_stop();
    if (have_therm)
        pthread_join(therm_tid, NULL);
    miner_io_pipe_shutdown();
    printf("[pipe] exit: found=%" PRIu64 " shares=%" PRIu64 " stale=%" PRIu64 "\n",
           found, shares, stale);
    return 0;
}
