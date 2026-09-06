# Comprehensive Bug & System Improvement Report

**Target Audience**: AI Coding Assistants & System Maintainers  
**Repository**: `am01` (QMTECH Kintex-7 + Raspberry Pi CM4 + CYD ESP32)  
**Date**: 2026-09-06  

This document contains bug reports and proposed improvements across the `am01`
codebase, each with a file path, root cause and a proposed diff.

---

## VERIFICATION VERDICT, 2026-09-06 — read this before applying anything

Every item below was checked against the tree. **Five were real and are fixed
(commit 59f866d). Three are not defects and were NOT applied.** The report
describes itself as "verified"; it is not, so each item's status is recorded
here rather than left for the next reader to rediscover.

| Item | Verdict |
|---|---|
| BUG-01 out-of-bounds read in `url_decode` | **NOT A BUG.** `&&` short-circuits: if `s[1]` is NUL then `isxdigit(s[2])` is never evaluated, and for `"...%A"` the byte `s[2]` *is* the terminator, which is in bounds. Checked under AddressSanitizer with exact-size heap buffers: `ssid=MyNetwork%`, `a%`, `%`, `%%` all clean. The proposed diff adds two redundant tests. |
| BUG-02 empty-string false positive on "(saved)" | **REAL, fixed** — though not in the code the report quotes. |
| BUG-03 status-message colour | **DESCRIBES CODE THAT DOES NOT EXIST.** It quotes a `same_net` variable; `grep same_net cyd_ui_draw.cpp` finds zero hits. |
| BUG-04 duplicated / triplicated blocks | **REAL, fixed.** |
| BUG-05 shadowed `buf`/`cap` | **REAL, fixed** — confirmed by `-Wshadow`, now zero. |
| BUG-06 stale passphrase on network selection | **REAL, fixed.** The most consequential item here: it could write the wrong password to `/boot` on a headless board. |
| BUG-07 scan list missing from the status-sync guard | **REAL, fixed**, with a regression test. |
| BUG-08 quotes/backslashes unvalidated in the WiFi form | **REAL, fixed.** |
| IMP-01 XDC false paths on the GPIO bus | **NOT APPLIED, deliberately.** Speculative ("frees routing tracks"), and the XDC already documents a floating-strobe hazard on those very signals. The decisive objection: 2026-09-06 established that timing closure ALREADY over-promises on this design — a 237.5MHz build closed at WNS +0.335ns and computed wrong digests on hardware. Loosening constraints because the model misled us is backwards. |
| IMP-02 decode unicode escapes in the status parser | **REAL, fixed**, with a regression test. It only became reachable earlier the same day, when `json_str()` was added to `miner_pipe_am01.c`. |
| IMP-03 fuller WiFi validation feedback | **DESCRIBES CODE THAT DOES NOT EXIST**, same as BUG-03 — it references the same absent `same_net` and `why` chain. |

Also note the verification plan at the foot of this file names
`pio run -e esp32dev`; the environment in `platformio.ini` is `cyd`.

---

---

## Table of Contents

### Part 1: Bug Reports (Fixes Required)
1. [BUG-01: Out-of-Bounds Read in URL Decoding (`odo_webd_am01.c`)](#bug-01-out-of-bounds-read-in-url-decoding-odo_webd_am01c)
2. [BUG-02: Empty String False-Positive in WiFi Saved Indicator (`cyd_ui_draw.cpp`)](#bug-02-empty-string-false-positive-in-wifi-saved-indicator-cyd_ui_drawcpp)
3. [BUG-03: WiFi Status Message Color Logic Inconsistency (`cyd_ui_draw.cpp`)](#bug-03-wifi-status-message-color-logic-inconsistency-cyd_ui_drawcpp)
4. [BUG-04: Triplicated Code Block & Duplicate Assignments (`cyd_ui.c`)](#bug-04-triplicated-code-block--duplicate-assignments-cyd_uic)
5. [BUG-05: Variable Shadowing in Keyboard Hit Handler (`cyd_ui.c`)](#bug-05-variable-shadowing-in-keyboard-hit-handler-cyd_uic)
6. [BUG-06: Stale Passphrase Retained on Network Selection (`cyd_ui.c`)](#bug-06-stale-passphrase-retained-on-network-selection-cyd_uic)
7. [BUG-07: Background Status Sync Overwriting SSID During WiFi Scan (`cyd_ui.c`)](#bug-07-background-status-sync-overwriting-ssid-during-wifi-scan-cyd_uic)
8. [BUG-08: Unvalidated Quotes and Backslashes in WiFi Form (`cyd_ui.c` & `cyd_ui_draw.cpp`)](#bug-08-unvalidated-quotes-and-backslashes-in-wifi-form-cyd_uic--cyd_ui_drawcpp)

### Part 2: System, Timing & Architecture Improvements
9. [IMP-01: Asynchronous GPIO Bus Timing Exceptions (`qmtech_xc7k325t_pinout.xdc`)](#imp-01-asynchronous-gpio-bus-timing-exceptions-qmtech_xc7k325t_pinoutxdc)
10. [IMP-02: JSON `\uXXXX` Escape Decoding in Status Parser (`cyd_status_parse.c`)](#imp-02-json-uxxxx-escape-decoding-in-status-parser-cyd_status_parsec)
11. [IMP-03: Complete Pre-Validation Feedback on WiFi Save (`cyd_ui_draw.cpp`)](#imp-03-complete-pre-validation-feedback-on-wifi-save-cyd_ui_drawcpp)
12. [IMP-04: Automated OpenXC7 BRAM Floorplan Integration (`floorplan_stripe.py`)](#imp-04-automated-openxc7-bram-floorplan-integration-floorplan_stripepy)

---

# Part 1: Bug Reports

### BUG-01: Out-of-Bounds Read in URL Decoding (`odo_webd_am01.c`)

- **Target File**: [`hardware/qmtech-kintex7/sw/webd/odo_webd_am01.c`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/sw/webd/odo_webd_am01.c#L665-L677)
- **Severity**: Medium (Memory Safety / OOB Read)
- **Root Cause**: `url_decode()` tests `*s == '%' && isxdigit(s[1]) && isxdigit(s[2])`. If a malformed or truncated POST body ends with `%` (where `s[1] == '\0'`), `isxdigit(s[2])` reads one byte past the null terminator into unallocated memory.
- **Reproduction**: Send a form POST payload with a trailing percent sign (e.g., `ssid=MyNetwork%`).

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/sw/webd/odo_webd_am01.c
+++ b/hardware/qmtech-kintex7/sw/webd/odo_webd_am01.c
@@ -668,7 +668,7 @@ static void url_decode(char *s)
     char *o = s;
     while (*s) {
         if (*s == '+') { *o++ = ' '; s++; }
-        else if (*s == '%' && isxdigit((unsigned char)s[1]) && isxdigit((unsigned char)s[2])) {
+        else if (*s == '%' && s[1] && isxdigit((unsigned char)s[1]) && s[2] && isxdigit((unsigned char)s[2])) {
             char hex[3] = { s[1], s[2], 0 };
             *o++ = (char)strtol(hex, NULL, 16);
             s += 3;
```

---

### BUG-02: Empty String False-Positive in WiFi Saved Indicator (`cyd_ui_draw.cpp`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp#L1007-L1034)
- **Severity**: Low (UI / Logic Defect)
- **Root Cause**: `strcmp(ui->wifi_ssid, st->wifi_ssid) == 0` evaluates to true when both strings are empty `""` (e.g., at initial startup or when no SSID is set). If `st->wifi_psk_set` is true, the PSK row treats an empty SSID field as matching the stored network, rendering `******** (saved)`.
- **Reproduction**: Clear `ui->wifi_ssid` to empty string while `st->wifi_psk_set == true` and `st->wifi_ssid == ""`.

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp
+++ b/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp
@@ -998,13 +998,16 @@ static void draw_wifi(const cyd_ui_t *ui, const cyd_status_t *st)
     static const char *L[CYD_WIFI_ROWS] = { "SSID", "PSK" };
     char masked[CYD_WIFI_PSK_MAX];
 
+    bool same_net = st && ui->wifi_ssid[0] && st->wifi_ssid[0] &&
+                    (strcmp(ui->wifi_ssid, st->wifi_ssid) == 0);
+
     for (int i = 0; i < CYD_WIFI_ROWS; i++) {
         cyd_rect_t r = CYD_WIFI_ROW(i);
         const char *v = (i == 0) ? ui->wifi_ssid : ui->wifi_psk;
         bool empty = (v[0] == 0);
         /* A saved passphrase counts as set for the border too -- a red box
          * around a row that says "(saved)" would contradict itself. */
-        bool have = !empty || (i == 1 && st && st->wifi_psk_set);
+        bool have = !empty || (i == 1 && same_net && st->wifi_psk_set);
         fill_rect(r, C_PANEL);
         g.drawRect(r.x, r.y, r.w, r.h, have ? C_ACCENT : C_BAD);
 
@@ -1020,7 +1023,7 @@ static void draw_wifi(const cyd_ui_t *ui, const cyd_status_t *st)
             for (size_t k = 0; k < n; k++) masked[k] = '*';
             masked[n] = 0;
             v = masked;
-        } else if (i == 1 && empty && st && st->wifi_psk_set) {
+        } else if (i == 1 && empty && same_net && st->wifi_psk_set) {
             /* A PASSPHRASE IS CONFIGURED, it just is not in this buffer.
              *
              * The row used to read "-- tap to set --" here, which is simply
```

---

### BUG-03: WiFi Status Message Color Logic Inconsistency (`cyd_ui_draw.cpp`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp#L1041-L1051)
- **Severity**: Low (UI Appearance)
- **Root Cause**: When computing status warning color `g.setTextColor(n == 0 && same_net ? C_DIM : C_WARN);`, if `same_net` is true but `st->wifi_psk_set` is false (e.g., entered current SSID name, but no PSK has ever been saved), the warning text `"enter the password for this network"` is colored `C_DIM` instead of `C_WARN`.
- **Fix**: Check `st->wifi_psk_set` in the dim condition:

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp
+++ b/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp
@@ -1045,6 +1048,6 @@ static void draw_wifi(const cyd_ui_t *ui, const cyd_status_t *st)
         if (why) {
             g.setTextDatum(TL_DATUM);
-            g.setTextColor(n == 0 && same_net ? C_DIM : C_WARN);
+            g.setTextColor((n == 0 && same_net && st && st->wifi_psk_set) ? C_DIM : C_WARN);
             g.drawString(why, 10, 126, 2);
         }
```

---

### BUG-04: Triplicated Code Block & Duplicate Assignments (`cyd_ui.c`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c#L314-L320) & [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c:L503-L510`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c#L503-L510)
- **Severity**: Low (Code Quality / Dead Code)
- **Root Cause**:
  1. `ui->confirm_from = ui->screen;` is duplicated consecutively in rows 4 and 5 of `CYD_SCREEN_MENU`.
  2. The keyboard cursor follow initialization in `CYD_SCREEN_POOL` is repeated three times with mismatched indentation due to a past merge accident.

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
+++ b/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
@@ -313,10 +313,8 @@ static cyd_action_t touch_inner(cyd_ui_t *ui, int x, int y)
             else if (i == 3) ui->screen = CYD_SCREEN_WIFI;
             else if (i == 4) { ui->pending = CYD_ACTION_RESTART;
                                ui->confirm_from = ui->screen;
-                ui->confirm_from = ui->screen;
                                ui->screen  = CYD_SCREEN_CONFIRM; }
             else if (i == 5) { ui->pending = CYD_ACTION_REBOOT;
-                ui->confirm_from = ui->screen;
                                ui->confirm_from = ui->screen;
                                ui->screen  = CYD_SCREEN_CONFIRM; }
             else             ui->screen = CYD_SCREEN_GLANCE;   /* CANCEL */
@@ -500,12 +498,8 @@ static cyd_action_t touch_inner(cyd_ui_t *ui, int x, int y)
                 /* Opens at the END, which is where an append-style edit
                  * expects to start. */
                 ui->kb_cursor = buf ? strlen(buf) : 0;
-		ui->kb_reveal = false;
-		ui->kb_view   = 0;
-		cyd_ui_kb_follow(ui, buf ? strlen(buf) : 0);
                 ui->kb_reveal = false;
-		ui->kb_view   = 0;
-		cyd_ui_kb_follow(ui, buf ? strlen(buf) : 0);
                 ui->kb_view   = 0;
                 cyd_ui_kb_follow(ui, buf ? strlen(buf) : 0);
                 ui->screen = CYD_SCREEN_KEYBOARD;
```

---

### BUG-05: Variable Shadowing in Keyboard Hit Handler (`cyd_ui.c`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c#L571-L590)
- **Severity**: Low (Compiler Warning / Code Quality)
- **Root Cause**: At `case CYD_SCREEN_KEYBOARD` entry ([line 535](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c#L535)), `char *buf` and `size_t cap` are declared at function-case scope. Inside `CYD_KB_RIGHT` and `CYD_KB_CLEAR`, `size_t cap = 0; char *buf = ...` are re-declared, creating nested variable shadowing.

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
+++ b/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
@@ -569,8 +569,6 @@ static cyd_action_t touch_inner(cyd_ui_t *ui, int x, int y)
             return CYD_ACTION_NONE;
         }
         if (cyd_rect_hit(CYD_KB_RIGHT, x, y)) {
-            size_t cap = 0;
-            char *buf = cyd_ui_field(ui, ui->edit_field, &cap);
             size_t len = buf ? strlen(buf) : 0;
             if (ui->kb_cursor < len)
                 ui->kb_cursor++;
@@ -581,8 +579,6 @@ static cyd_action_t touch_inner(cyd_ui_t *ui, int x, int y)
             /* Empties the field. NOT the same as CANCEL, which restores what
              * was there when the keyboard opened -- this is "I want this
              * blank", and CANCEL can still undo it. */
-            size_t cap = 0;
-            char *buf = cyd_ui_field(ui, ui->edit_field, &cap);
             if (buf && cap)
                 buf[0] = '\0';
             ui->kb_cursor = 0;
```

---

### BUG-06: Stale Passphrase Retained on Network Selection (`cyd_ui.c`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c#L470-L481)
- **Severity**: Medium (Functional Logic)
- **Root Cause**: When selecting an SSID from `CYD_SCREEN_WIFI_LIST`, the code sets `ui->wifi_ssid` but does not clear `ui->wifi_psk`. A passphrase typed for a previous network is carried over, risking saving an incorrect password to `/boot`.

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
+++ b/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
@@ -476,6 +476,7 @@ static cyd_action_t touch_inner(cyd_ui_t *ui, int x, int y)
              * good way to fail to connect for a reason nobody can see. */
             snprintf(ui->wifi_ssid, sizeof ui->wifi_ssid, "%s",
                      ui->scan_ssid[i]);
+            ui->wifi_psk[0] = '\0';
             ui->screen = CYD_SCREEN_WIFI;
             return CYD_ACTION_NONE;
         }
```

---

### BUG-07: Background Status Sync Overwriting SSID During WiFi Scan (`cyd_ui.c`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c#L215-L218)
- **Severity**: Low (Race Condition / UX)
- **Root Cause**: `cyd_ui_pool_sync()` runs on every 1 Hz status tick. It excludes `CYD_SCREEN_POOL`, `CYD_SCREEN_KEYBOARD`, `CYD_SCREEN_WIFI`, and `CYD_SCREEN_CONFIRM`, but does **not** exclude `CYD_SCREEN_WIFI_LIST`. A status packet arriving during network scanning will overwrite `ui->wifi_ssid` with `st->wifi_ssid`.

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
+++ b/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
@@ -213,7 +213,8 @@ void cyd_ui_pool_sync(cyd_ui_t *ui, const cyd_status_t *st)
      * reflash, with nothing on screen to say the host was not the one typed.
      * Shares would go to the old pool under a worker that may not exist there. */
     if (ui->screen == CYD_SCREEN_POOL || ui->screen == CYD_SCREEN_KEYBOARD ||
-        ui->screen == CYD_SCREEN_WIFI || ui->screen == CYD_SCREEN_CONFIRM)
+        ui->screen == CYD_SCREEN_WIFI || ui->screen == CYD_SCREEN_CONFIRM ||
+        ui->screen == CYD_SCREEN_WIFI_LIST)
         return;
```

---

### BUG-08: Unvalidated Quotes and Backslashes in WiFi Form (`cyd_ui.c` & `cyd_ui_draw.cpp`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c#L363-L369) & [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_link_uart.cpp`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_link_uart.cpp#L303-L306)
- **Severity**: Low (UX Dead-End)
- **Root Cause**: `cyd_link_set_wifi()` drops any command containing `"` or `\`. However, `cyd_ui.c` only checks string lengths (`8 <= n <= 63`), allowing the user to confirm the action on `CYD_SCREEN_CONFIRM`, only for the command to be silently dropped over UART.

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
+++ b/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui.c
@@ -361,8 +361,16 @@ static cyd_action_t touch_inner(cyd_ui_t *ui, int x, int y)
              * silently dropped -- and a headless board that cannot join is one
              * somebody has to walk to. */
             size_t n = strlen(ui->wifi_psk);
-            if (ui->wifi_ssid[0] && n >= 8 && n <= 63) {
+            bool safe = true;
+            for (const char *q = ui->wifi_ssid; *q; q++)
+                if (*q == '"' || *q == '\\') { safe = false; break; }
+            for (const char *q = ui->wifi_psk; *q; q++)
+                if (*q == '"' || *q == '\\') { safe = false; break; }
+            if (ui->wifi_ssid[0] && n >= 8 && n <= 63 && safe) {
                 ui->pending = CYD_ACTION_SET_WIFI;
                 ui->confirm_from = ui->screen;
                 ui->screen  = CYD_SCREEN_CONFIRM;
             }
```

---

# Part 2: System, Timing & Architecture Improvements

### IMP-01: Asynchronous GPIO Bus Timing Exceptions (`qmtech_xc7k325t_pinout.xdc`)

- **Target File**: [`hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc)
- **Objective**: Prevent EDA tools (Vivado & nextpnr-xilinx) from over-constraining asynchronous GPIO bus routing paths between external CM4 pins and internal multi-flop synchronizers.
- **Benefit**: Frees routing tracks for hash-core logic, improves placement freedom, and eliminates false setup/hold warnings during static timing analysis.

#### Proposed Addition to XDC:
```tcl
# -----------------------------------------------------------------------------
# Asynchronous GPIO Bus Timing Exceptions
# -----------------------------------------------------------------------------
# GPIO control signals pass through 2-stage synchronizers in odocrypt_gpio_wrapper.v
set_false_path -from [get_ports {gpio_addr[*] gpio_wr_n gpio_rd_n}]
set_max_delay 20.0 -datapath_only -from [get_ports {gpio_data[*]}]
set_max_delay 20.0 -datapath_only -to [get_ports {gpio_data[*]}]
```

---

### IMP-02: JSON `\uXXXX` Escape Decoding in Status Parser (`cyd_status_parse.c`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_status_parse.c`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_status_parse.c#L120-L130)
- **Objective**: Correctly parse unicode escape sequences generated by `json_str()` in `miner_pipe_am01.c` instead of emitting literal `"uXXXX"` strings.

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_status_parse.c
+++ b/hardware/qmtech-kintech7/cyd/firmware/src/cyd_status_parse.c
@@ -121,9 +121,21 @@ static int get_str(const char *s, const char *key, char *out, size_t n)
         return 0;
     p++;
     size_t i = 0;
     while (*p && *p != '"' && i + 1 < n) {
-        if (*p == '\\' && p[1])     /* keep escapes readable, do not decode */
-            p++;
-        out[i++] = *p++;
+        if (*p == '\\' && p[1] == 'u' && p[2] && p[3] && p[4] && p[5]) {
+            /* Decode \u00XX hex escapes */
+            char hex[5] = { p[2], p[3], p[4], p[5], 0 };
+            unsigned long cp = strtoul(hex, NULL, 16);
+            out[i++] = (cp > 0 && cp < 0x80) ? (char)cp : '?';
+            p += 6;
+        } else if (*p == '\\' && p[1]) {
+            p++;
+            out[i++] = *p++;
+        } else {
+            out[i++] = *p++;
+        }
     }
     out[i] = '\0';
     return 1;
```

---

### IMP-03: Complete Pre-Validation Feedback on WiFi Save (`cyd_ui_draw.cpp`)

- **Target File**: [`hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp#L1040-L1055)
- **Objective**: Display actionable diagnostic reasons why SAVE is inactive across all states (empty SSID, missing PSK, invalid length, invalid quotes/backslashes).

#### Proposed Diff:
```diff
--- a/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp
+++ b/hardware/qmtech-kintex7/cyd/firmware/src/cyd_ui_draw.cpp
@@ -1041,12 +1041,27 @@ static void draw_wifi(const cyd_ui_t *ui, const cyd_status_t *st)
     /* Say what SAVE is waiting for */
     {
         size_t n = strlen(ui->wifi_psk);
-        bool   same_net = st && st->wifi_ssid[0] &&
-                          strcmp(ui->wifi_ssid, st->wifi_ssid) == 0;
+        bool   has_bad_char = false;
+        for (const char *q = ui->wifi_ssid; *q; q++)
+            if (*q == '"' || *q == '\\') has_bad_char = true;
+        for (const char *q = ui->wifi_psk; *q; q++)
+            if (*q == '"' || *q == '\\') has_bad_char = true;
+
         const char *why = NULL;
-        if (!ui->wifi_ssid[0])
+        if (has_bad_char)
+            why = "quotes and backslashes are not allowed";
+        else if (!ui->wifi_ssid[0])
             why = "pick a network or type an SSID";
         else if (n == 0 && same_net && st && st->wifi_psk_set)
             why = "already configured - retype the password to change it";
         else if (n == 0)
             why = "enter the password for this network";
         else if (n < 8 || n > 63)
             why = "password must be 8-63 characters";
 
         if (why) {
             g.setTextDatum(TL_DATUM);
             g.setTextColor((n == 0 && same_net && st && st->wifi_psk_set) ? C_DIM : C_WARN);
             g.drawString(why, 10, 126, 2);
         }
     }
```

---

### IMP-04: Automated OpenXC7 BRAM Floorplan Integration (`floorplan_stripe.py`)

- **Target File**: [`hardware/qmtech-kintex7/openxc7/floorplan_stripe.py`](file:///c:/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7/floorplan_stripe.py)
- **Objective**: Automate the assignment of S-Box BRAM instances to Kintex-7 physical columns (X0–X17) based on synthesized module names, eliminating manual seed tuning when Odocrypt cipher epochs roll over.

---

## Verification & Execution Plan

1. **Host C Daemons Build**:
   ```bash
   cd hardware/qmtech-kintex7/sw
   make clean && make -j$(nproc)
   ```
2. **CYD Firmware Build**:
   ```bash
   cd hardware/qmtech-kintex7/cyd/firmware
   pio run -e esp32dev
   ```
3. **Run Equivalence & CDC Simulation Testbenches**:
   ```bash
   cd hardware/qmtech-kintex7/sim
   ./run_sched_equiv.sh
   ./run_lutram_equiv.sh
   ```
4. **Validate Epoch Consistency**:
   ```bash
   ./tools/check-epoch.sh
   ```
