#!/bin/bash
#
# test-panel-helper.sh -- prove am01-panel-helper refuses hostile requests.
#
# am01-panel-helper runs as ROOT and acts on files written by an UNPRIVILEGED
# process. Reaching /run/odod/request/ only takes the miner account, so this
# script is the step that turns that into root. Its validation is the entire
# security property, and shipping it unproven would be indefensible.
#
# Runs anywhere with bash; it copies the helper, redirects its paths into a
# sandbox and stubs systemctl, so nothing real is touched.
#
#   ./test-panel-helper.sh
#
set -u

HELPER_SRC="$(dirname "$0")/overlay/usr/bin/am01-panel-helper"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

REQ="$SANDBOX/run/odod/request"
POOL="$SANDBOX/boot/am01-miner.conf"
WPA="$SANDBOX/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
BOOTWPA="$SANDBOX/boot/wpa_supplicant.conf"
SCAN="$SANDBOX/run/odod/wifi_scan.txt"
STAGE="$SANDBOX/run/am01-panel-helper"
mkdir -p "$REQ" "$SANDBOX/boot" "$SANDBOX/etc/wpa_supplicant" "$SANDBOX/bin"

# Stub systemctl: record calls, never act.
cat > "$SANDBOX/bin/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >> "$SANDBOX_CALLS"
STUB
chmod +x "$SANDBOX/bin/systemctl"
export SANDBOX_CALLS="$SANDBOX/systemctl.calls"
: > "$SANDBOX_CALLS"

# Copy the helper with its three paths redirected. Everything else -- crucially
# every validator -- is byte-identical to what ships.
HELPER="$SANDBOX/bin/helper"
sed -e "s#^REQ_DIR=.*#REQ_DIR=$REQ#" \
    -e "s#^POOL_CONF=.*#POOL_CONF=$POOL#" \
    -e "s#^WPA_CONF=.*#WPA_CONF=$WPA#" \
    -e "s#^WPA_BOOT=.*#WPA_BOOT=$BOOTWPA#" \
    -e "s#^SCAN_PATH=.*#SCAN_PATH=$SCAN#" \
    -e "s#^STAGE_DIR=.*#STAGE_DIR=$STAGE#" \
    "$HELPER_SRC" > "$HELPER"
chmod +x "$HELPER"
grep -q "^REQ_DIR=$REQ\$" "$HELPER" || { echo "sed redirect failed"; exit 1; }
# Checked, because without it this test writes the real /boot.
grep -q "^WPA_BOOT=$BOOTWPA\$" "$HELPER" || { echo "WPA_BOOT redirect failed"; exit 1; }
# Same reason: without these two the scan test writes the real /run.
grep -q "^SCAN_PATH=$SCAN$" "$HELPER" || { echo "SCAN_PATH redirect failed"; exit 1; }
grep -q "^STAGE_DIR=$STAGE$" "$HELPER" || { echo "STAGE_DIR redirect failed"; exit 1; }

PATH="$SANDBOX/bin:$PATH"
checks=0; errors=0
ok() {
	checks=$((checks + 1))
	if [ "$1" = 0 ]; then printf '  PASS  %s\n' "$2"
	else printf '  FAIL  %s\n' "$2"; errors=$((errors + 1)); fi
}

run() { "$HELPER" >"$SANDBOX/err" 2>&1; }
req() { printf '%s' "$2" > "$REQ/$1"; }

echo "=== am01-panel-helper: the privilege boundary ==="
echo

# ---- set_pool: the shell-metacharacter cases ----------------------------
echo "-- set_pool rejects anything that is not a hostname --"
for evil in 'pool.example; reboot' 'pool$(id)' 'pool`id`' 'pool|nc 1.2.3.4 1' \
            'pool example' '../../etc/passwd' 'pool"x'; do
	rm -f "$POOL"
	req set_pool "$evil
3333
wallet.rig
x"
	run
	[ ! -f "$POOL" ]; ok $? "host refused: $evil"
done

echo "-- set_pool rejects a bad port --"
for p in 0 65536 99999 abc '' '33 33' '-1'; do
	rm -f "$POOL"
	req set_pool "pool.example
$p
wallet.rig
x"
	run
	[ ! -f "$POOL" ]; ok $? "port refused: '$p'"
done

echo "-- set_pool rejects a worker or password with metacharacters --"
rm -f "$POOL"; req set_pool "pool.example
3333
wallet;reboot
x"; run
[ ! -f "$POOL" ]; ok $? "worker refused: wallet;reboot"
rm -f "$POOL"; req set_pool "pool.example
3333
wallet.rig
\$(id)"; run
[ ! -f "$POOL" ]; ok $? 'pass refused: $(id)'

# ---- set_pool: the good case, and it must write DAEMON_OPTS -------------
echo "-- set_pool accepts a valid request --"
rm -f "$POOL"
req set_pool "pool.example.com
5103
DTGwfAPbxQaKViGpoy8XfVguMPj5sGxTdS.Odo02
x"
run
[ -f "$POOL" ]; ok $? "a valid pool is written"
grep -q '^DAEMON_OPTS="pool.example.com 5103 DTGwfAPbxQaKViGpoy8XfVguMPj5sGxTdS.Odo02 x"$' "$POOL"
ok $? "as DAEMON_OPTS -- the only key am01-miner-provision reads"
[ ! -e "$REQ/set_pool" ]; ok $? "and the request file is consumed"

# ---- set_wifi ------------------------------------------------------------
echo
echo "-- set_wifi rejects what would break wpa_supplicant.conf --"
for evil in 'pass"word' 'password\' 'pa\ss"wd'; do
	rm -f "$WPA"
	req set_wifi "HomeNet
$evil"
	run
	[ ! -f "$WPA" ]; ok $? "psk refused: $evil"
done
rm -f "$WPA"; req set_wifi 'Home"Net
password123'; run
[ ! -f "$WPA" ]; ok $? 'ssid refused: Home"Net'

echo "-- set_wifi enforces WPA2 length --"
rm -f "$WPA"; req set_wifi "HomeNet
short7"; run
[ ! -f "$WPA" ]; ok $? "psk of 6 refused"
rm -f "$WPA"; req set_wifi "HomeNet
$(printf 'x%.0s' $(seq 1 64))"; run
[ ! -f "$WPA" ]; ok $? "psk of 64 refused"

echo "-- set_wifi accepts a valid request --"
rm -f "$WPA"
req set_wifi "Home Net
correct horse battery"
run
[ -f "$WPA" ]; ok $? "a valid config is written (SSID with a space)"
grep -q '^country=GB$' "$WPA"
ok $? "country= is present -- without it wlan0 sits in SCANNING for ever"
grep -q 'key_mgmt=WPA-PSK' "$WPA"; ok $? "key_mgmt is present"
grep -q 'psk="correct horse battery"' "$WPA"
ok $? "a passphrase containing spaces survives intact"
[ "$(stat -c %a "$WPA")" = 600 ]; ok $? "and the file is 0600 -- it holds a PSK"
grep -q "am01-wifi.service" "$SANDBOX_CALLS"
ok $? "am01-wifi.service is restarted, not wpa_supplicant@wlan0"

# THE COPY THAT SURVIVES A REBOOT. am01-wifi-provision.service copies
# /boot/wpa_supplicant.conf over /etc before am01-wifi starts, so a change
# written only to /etc applies now and is reverted at the next boot. That is
# exactly what happened on 2026-09-05: the panel changed the network, it
# worked, and the old one came back after a restart.
[ -f "$BOOTWPA" ]; ok $? "the /boot copy is written, so the change survives a reboot"
cmp -s "$WPA" "$BOOTWPA"; ok $? "and matches the config that took effect"

# ---- unknown verbs -------------------------------------------------------
echo
echo "-- anything unrecognised is dropped, not guessed at --"
# NOT a name containing '/': the shell cannot create that file at all, so the
# check would pass without the helper being involved. A filename that really
# can exist is the only one that tests anything.
req 'reboot;rm -rf' ''
req 'set_pool.bak' 'pool.example
3333
w
x'
rm -f "$POOL"
run
[ -z "$(ls -A "$REQ")" ]; ok $? "unknown verbs are removed"
# The stronger half: set_pool.bak must not be treated as set_pool. A helper
# matching set_pool* rather than the exact name would pass the check above.
[ ! -f "$POOL" ]; ok $? "and set_pool.bak does NOT act as set_pool"
grep -q "REFUSED unknown request" "$SANDBOX/err"; ok $? "and is logged"

# A malformed request must not survive to be retried for ever by the path unit.
req set_wifi "onlyoneline"
run
[ ! -e "$REQ/set_wifi" ]; ok $? "a malformed set_wifi is consumed, not retried"

# ---- wifi_scan -----------------------------------------------------------
#
# Untested until 2026-09-06, which is how it came to be the one verb carrying a
# privilege hole: it was the only one writing a file into a directory the miner
# owns, and no test ever went near it.
echo "-- wifi_scan --"

# A realistic `iw` capture: the signal line precedes the SSID line, one SSID is
# advertised twice at different strengths (mesh / band steering), and one
# network is cloaked.
cat > "$SANDBOX/bin/iw" <<'STUB'
#!/bin/sh
cat <<'SCANOUT'
BSS aa:bb:cc:dd:ee:01(on wlan0)
	signal: -72.00 dBm
	SSID: FarNetwork
BSS aa:bb:cc:dd:ee:02(on wlan0)
	signal: -41.00 dBm
	SSID: MeshNet
BSS aa:bb:cc:dd:ee:03(on wlan0)
	signal: -66.00 dBm
	SSID: MeshNet
BSS aa:bb:cc:dd:ee:04(on wlan0)
	signal: -50.00 dBm
	SSID: \x00\x00\x00
SCANOUT
STUB
chmod +x "$SANDBOX/bin/iw"

rm -rf "$SCAN" "$STAGE"
req wifi_scan ""
run
[ -f "$SCAN" ]; ok $? "a scan writes its result where the panel reads it"
[ "$(head -n1 "$SCAN" | cut -f2)" = "MeshNet" ]
ok $? "strongest first -- the -41 radio, not the -66 one"
[ "$(grep -c MeshNet "$SCAN")" = 1 ]; ok $? "one entry per SSID, not one per radio"
grep -q FarNetwork "$SCAN"; ok $? "weaker networks are still listed"
! grep -q 'x00' "$SCAN"; ok $? "cloaked networks are dropped -- they cannot be joined"

# THE MODE MATTERS. The panel thread runs as `miner`; a 0600 root-owned result
# reads as "scan found nothing" after a 20s wait, with nothing to explain it.
[ "$(stat -c %a "$SCAN")" = 644 ]; ok $? "and is readable by the panel (0644)"

# The umask leak that produced exactly that: set_pool sets umask 077 and the
# dispatch glob is sorted, so wifi_scan is handled by the same invocation.
rm -f "$SCAN" "$POOL"
req set_pool "pool.example.com
5103
w.x
x"
req wifi_scan ""
run
[ "$(stat -c %a "$SCAN")" = 644 ]
ok $? "still 0644 with a set_pool queued ahead of it in the same run"

# ---- the privilege boundary ----------------------------------------------
#
# /run/odod is owned by `miner` (odo-miner.service RuntimeDirectory=odod), so
# any miner-uid process can pre-create names inside it. This helper runs as
# root. A shell redirect follows a symlink; rename(2) does not. If this check
# ever fails, a compromised miner can overwrite any file on the system.
echo "-- a symlink planted by the miner uid must not be written through --"

# THE STAGING PATH IS THE ONE THAT MATTERED.
#
# Until 2026-09-06 the scan was staged at $SCAN_PATH.tmp with a shell redirect,
# inside /run/odod -- a directory owned by `miner`. A redirect follows a
# symlink and truncates its target, so any miner-uid process could point that
# name at /etc/shadow and have root do the write.
#
# Note which path is planted. An earlier version of this test planted the link
# at $SCAN_PATH, the DESTINATION, and passed against the vulnerable helper --
# because publishing has always been mv, i.e. rename(2), which replaces a
# symlink rather than following it. Testing the safe half proved nothing. The
# staging path is the attack surface, so the staging path is what is planted.
rm -f "$SCAN" "$SCAN.tmp"
echo "ORIGINAL" > "$SANDBOX/canary"
ln -s "$SANDBOX/canary" "$SCAN.tmp"
req wifi_scan ""
run
[ "$(cat "$SANDBOX/canary")" = "ORIGINAL" ]
ok $? "root does NOT write through a symlink at the old staging path"
[ -L "$SCAN.tmp" ]; ok $? "and does not go near that path at all"

# The destination is safe for a different reason (rename, not redirect), and
# that property is worth pinning too -- it is what lets the publish stay a mv.
rm -f "$SCAN" "$SCAN.tmp"
echo "ORIGINAL" > "$SANDBOX/canary"
ln -s "$SANDBOX/canary" "$SCAN"
req wifi_scan ""
run
[ "$(cat "$SANDBOX/canary")" = "ORIGINAL" ]
ok $? "nor through one at the destination -- mv replaces, it does not follow"
[ ! -L "$SCAN" ]; ok $? "the destination symlink is replaced by the real result"
grep -q MeshNet "$SCAN"; ok $? "and the scan still lands correctly"

echo
if [ "$errors" = 0 ]; then echo "=== ALL $checks CHECKS PASSED ==="; exit 0; fi
echo "=== $errors of $checks CHECK(S) FAILED ==="; exit 1
