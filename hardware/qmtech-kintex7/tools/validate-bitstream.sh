#!/bin/sh
# validate-bitstream.sh -- flash a bitstream and decide from HARDWARE whether
# it is fit to mine. Run this ON THE BOARD.
#
# WHY THIS EXISTS
#
# Vivado's WNS does not predict whether this design hashes correctly. Measured
# 2026-09-06/07, all at the same 225MHz:
#
#   VERSION 0x0203   WNS +0.273 ns   96% of finds valid   106 MH/s
#   VERSION 0x0208   WNS +0.347 ns   37% of finds valid    43 MH/s
#   237.47 MHz       WNS +0.335 ns   ~0% valid
#
# The build with the MOST slack was the second worst. Sign-off passed all
# three. So "timing met" is necessary and nowhere near sufficient, and a
# bitstream must be judged on the fraction of hardware finds that survive the
# host's revalidation.
#
# That fraction is not visible at the pool: the host filters before submitting,
# so a miner losing 60% of its work still reports ZERO rejects. It is only
# visible as hashrate, and hashrate takes many minutes to converge because it
# is a cumulative share-based estimate. The per-core pass rate converges in
# minutes and says WHICH instance is bad.
#
# USAGE
#   validate-bitstream.sh /boot/am01_candidate.bit [minutes]
#
# Needs an odo-miner that emits CORESTAT lines. Exit 0 = PASS.

set -e

BIT="$1"
MINS="${2:-10}"

[ -n "$BIT" ] || { echo "usage: $0 <bitstream.bit> [minutes]" >&2; exit 2; }
[ -f "$BIT" ] || { echo "no such bitstream: $BIT" >&2; exit 2; }

# Pass mark. 0x0203 sits at 96% and the residual is genuine job-handover
# races, so anything below 90 is a real fault, not noise. A GOOD build should
# clear this easily; the point is to catch 37%, not to shave percentages.
FLOOR=90

# ftdi_sio steals the FT232H and makes flash WRITES fail while JTAG detect
# still works -- which is what made this look like a clock-speed problem for
# two sessions. Unbind it and CHECK, do not assume.
for d in $(ls /sys/bus/usb/drivers/ftdi_sio/ 2>/dev/null | grep -E '^[0-9]'); do
    echo "$d" > /sys/bus/usb/drivers/ftdi_sio/unbind || true
done
sleep 1
if ls /sys/bus/usb/drivers/ftdi_sio/ 2>/dev/null | grep -qE '^[0-9]'; then
    echo "ftdi_sio still bound to the FT232H; flash writes will fail" >&2
    exit 1
fi

OPTS="-c ft232 --freq 500000 --fpga-part xc7k325tffg676"
# 500 kHz, not 1 MHz: 1 MHz has failed with "write en: Error" more than once.

echo "== flashing $BIT"
systemctl stop odo-miner
sleep 1
openFPGALoader $OPTS --unprotect-flash -f "$BIT"
openFPGALoader $OPTS -r >/dev/null 2>&1
sleep 4

systemctl start odo-miner
sleep 20

VER=$(journalctl -u odo-miner --no-pager -o cat --since '-2 min' \
      | grep -o 'version=0x[0-9a-f]*' | tail -1)
echo "== running $VER"

echo "== sampling for $MINS minute(s)"
sleep $((MINS * 60))

LINE=$(journalctl -u odo-miner --no-pager -o cat --since "-${MINS} min" \
       | grep CORESTAT | tail -1)
if [ -z "$LINE" ]; then
    echo "no CORESTAT output -- is this odo-miner new enough?" >&2
    exit 1
fi
echo "$LINE"

# core0 found=N ok=M (P%)  core1 found=N ok=M (P%)
P0=$(echo "$LINE" | sed -n 's/.*core0 [^(]*(\([0-9]*\)\..*/\1/p')
P1=$(echo "$LINE" | sed -n 's/.*core1 [^(]*(\([0-9]*\)\..*/\1/p')
[ -n "$P0" ] && [ -n "$P1" ] || { echo "could not parse CORESTAT" >&2; exit 1; }

echo
echo "  core0 pass ${P0}%   core1 pass ${P1}%   floor ${FLOOR}%"

RC=0
[ "$P0" -lt "$FLOOR" ] && { echo "  core0 FAILS"; RC=1; }
[ "$P1" -lt "$FLOOR" ] && { echo "  core1 FAILS"; RC=1; }

# An asymmetry says the two instances were placed differently and one landed
# worse -- per-instance, so not shared state like a mis-committed header.
D=$((P0 - P1)); [ "$D" -lt 0 ] && D=$((-D))
[ "$D" -gt 10 ] && echo "  NOTE: ${D}-point split between instances (placement, not shared state)"

if [ "$RC" = 0 ]; then
    echo "  PASS -- fit to mine"
else
    echo "  FAIL -- do not ship this bitstream"
fi
exit $RC
