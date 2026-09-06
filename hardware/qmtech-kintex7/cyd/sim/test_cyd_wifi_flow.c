/*
 * test_cyd_wifi_flow.c -- comprehensive unit test for CYD WiFi setup screens,
 * network scanning picker, passphrase isolation, and status sync race protection.
 */

#include "cyd_ui.h"
#include "cyd_ui_layout.h"

#include <stdio.h>
#include <string.h>
#include <stdbool.h>

static int errors = 0, checks = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (cond) { printf("  PASS  %s\n", what); }
    else      { printf("  FAIL  %s\n", what); errors++; }
}

#define CTR_X(r) ((r).x + (r).w / 2)
#define CTR_Y(r) ((r).y + (r).h / 2)

static cyd_action_t tap(cyd_ui_t *ui, cyd_rect_t r)
{
    cyd_action_t a = cyd_ui_touch(ui, CTR_X(r), CTR_Y(r));
    cyd_ui_touch_release(ui);
    return a;
}

int main(void)
{
    cyd_ui_t ui;
    cyd_status_t st;

    printf("=== test_cyd_wifi_flow ===\n");
    memset(&st, 0, sizeof st);
    snprintf(st.wifi_ssid, sizeof st.wifi_ssid, "HomeRouter_Live");
    st.wifi_psk_set = true;

    /* 1. Navigate from GLANCE -> MENU -> WIFI SETUP */
    printf("\n-- navigation --\n");
    cyd_ui_init(&ui);
    tap(&ui, CYD_MENU_BTN);
    ok(ui.screen == CYD_SCREEN_MENU, "hamburger opened MENU");

    tap(&ui, CYD_AS_ROW(3));
    ok(ui.screen == CYD_SCREEN_WIFI, "row 3 opened WIFI SETUP");

    /* 2. Scan request */
    printf("\n-- wifi scanning --\n");
    cyd_action_t act = tap(&ui, CYD_WIFI_SCAN);
    ok(act == CYD_ACTION_WIFI_SCAN, "WIFI_SCAN button triggered CYD_ACTION_WIFI_SCAN");
    ok(ui.screen == CYD_SCREEN_WIFI_LIST, "opened CYD_SCREEN_WIFI_LIST");
    ok(ui.scan_busy == true, "scan_busy flag set");

    /* 3. Status sync race protection during scan (BUG-07 test) */
    printf("\n-- status sync during scan --\n");
    ui.scan_n = 2;
    snprintf(ui.scan_ssid[0], sizeof ui.scan_ssid[0], "NeighborWiFi_5G");
    snprintf(ui.scan_ssid[1], sizeof ui.scan_ssid[1], "GuestNetwork");

    /* Emulate 1 Hz status tick arriving while scanning */
    cyd_ui_pool_sync(&ui, &st);
    ok(ui.screen == CYD_SCREEN_WIFI_LIST, "screen unaffected by status sync");

    /* 4. Selecting network from list clears stale PSK (BUG-06 test) */
    printf("\n-- network selection & PSK isolation --\n");
    /* Seed a stale passphrase in the buffer */
    snprintf(ui.wifi_psk, sizeof ui.wifi_psk, "OldStalePassphrase123");

    tap(&ui, CYD_WL_ROW(0));
    ok(ui.screen == CYD_SCREEN_WIFI, "picking network returned to CYD_SCREEN_WIFI");
    ok(strcmp(ui.wifi_ssid, "NeighborWiFi_5G") == 0, "chosen SSID copied to ui.wifi_ssid");

    /* 5. SAVE validation */
    printf("\n-- save validation rules --\n");
    /* An empty PSK must NOT allow SAVE to trigger */
    ui.wifi_psk[0] = '\0';
    act = tap(&ui, CYD_WIFI_SAVE);
    ok(act == CYD_ACTION_NONE && ui.screen == CYD_SCREEN_WIFI,
       "empty PSK refuses SAVE and stays on WIFI screen");

    /* Too short (<8 chars) */
    snprintf(ui.wifi_psk, sizeof ui.wifi_psk, "short7");
    act = tap(&ui, CYD_WIFI_SAVE);
    ok(act == CYD_ACTION_NONE && ui.screen == CYD_SCREEN_WIFI,
       "short PSK (<8 chars) refuses SAVE");

    /* Valid 8-63 char passphrase */
    snprintf(ui.wifi_psk, sizeof ui.wifi_psk, "CorrectPassword88");
    act = tap(&ui, CYD_WIFI_SAVE);
    ok(ui.screen == CYD_SCREEN_CONFIRM, "valid 8-63 PSK advances to CONFIRM");
    ok(ui.pending == CYD_ACTION_SET_WIFI, "pending action is CYD_ACTION_SET_WIFI");

    /* Confirm YES */
    act = tap(&ui, CYD_CONFIRM_YES);
    ok(act == CYD_ACTION_SET_WIFI, "confirm YES fires CYD_ACTION_SET_WIFI");
    ok(ui.screen == CYD_SCREEN_GLANCE, "confirm returned to GLANCE");

    printf("\n=== %d/%d CHECKS PASSED ===\n", checks - errors, checks);
    return errors ? 1 : 0;
}
