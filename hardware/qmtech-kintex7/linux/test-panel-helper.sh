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
    "$HELPER_SRC" > "$HELPER"
chmod +x "$HELPER"
grep -q "^REQ_DIR=$REQ\$" "$HELPER" || { echo "sed redirect failed"; exit 1; }
# Checked, because without it this test writes the real /boot.
grep -q "^WPA_BOOT=$BOOTWPA\$" "$HELPER" || { echo "WPA_BOOT redirect failed"; exit 1; }

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

echo
if [ "$errors" = 0 ]; then echo "=== ALL $checks CHECKS PASSED ==="; exit 0; fi
echo "=== $errors of $checks CHECK(S) FAILED ==="; exit 1
