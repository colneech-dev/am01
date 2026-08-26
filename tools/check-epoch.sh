#!/bin/sh
# Report whether the OdoCrypt epoch baked into this tree is current, and
# whether the two places that record it agree.
#
#   hdl/odocrypt/encrypt.v          header stamp -- what the RTL implements
#   .../hdl/odocrypt_gpio_wrapper.v ODO_SEED     -- what the hardware reports
#                                                   to the daemon over the bus
#
# They must match: the daemon compares the reported value against the pool's
# job epoch to decide whether the bitstream is stale, so a wrong ODO_SEED
# makes a stale bitstream look current.
#
# Exit 0 current, 1 stale, 2 inconsistent or unreadable.

set -e
here=$(dirname "$0")
root=$(cd "$here/.." && pwd)

ENC="$root/hdl/odocrypt/encrypt.v"
WRAP="$root/hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v"
INTERVAL=864000

[ -f "$ENC" ]  || { echo "missing $ENC";  exit 2; }
[ -f "$WRAP" ] || { echo "missing $WRAP"; exit 2; }

enc_seed=$(sed -n 's|^// OdoCrypt epoch seed: *\([0-9][0-9]*\).*|\1|p' "$ENC" | head -1)
wrap_seed=$(sed -n "s|.*parameter \[31:0\] ODO_SEED *= *32'd\([0-9][0-9]*\).*|\1|p" "$WRAP" | head -1)

if [ -z "$enc_seed" ]; then
	echo "encrypt.v carries no epoch stamp -- regenerate it with tools/odo_gen"
	echo "(a copy generated before the stamp existed cannot be dated by inspection)"
	exit 2
fi
[ -n "$wrap_seed" ] || { echo "could not read ODO_SEED from $WRAP"; exit 2; }

now=$(date -u +%s)
cur=$(( now - now % INTERVAL ))

fmt() { date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$1"; }

echo "encrypt.v epoch : $enc_seed  ($(fmt "$enc_seed"))"
echo "ODO_SEED        : $wrap_seed  ($(fmt "$wrap_seed"))"
echo "chain epoch now : $cur  ($(fmt "$cur"))"

if [ "$enc_seed" != "$wrap_seed" ]; then
	echo
	echo "INCONSISTENT: the RTL implements $enc_seed but the hardware would report"
	echo "$wrap_seed. The daemon's staleness check would be comparing against the"
	echo "wrong value. Fix ODO_SEED in odocrypt_gpio_wrapper.v."
	exit 2
fi

if [ "$enc_seed" != "$cur" ]; then
	behind=$(( (cur - enc_seed) / INTERVAL ))
	echo
	echo "STALE by $behind epoch(s). Shares will be rejected. Regenerate:"
	echo "  cd tools/odo_gen && make odo_gen"
	echo "  ./odo_gen $cur 4 encrypt_4 > ../../hdl/odocrypt/encrypt.v"
	echo "  then set ODO_SEED = 32'd$cur in odocrypt_gpio_wrapper.v"
	echo
	echo "Note this changes the sbox contents, so place-and-route results from"
	echo "the previous epoch no longer apply."
	exit 1
fi

echo
echo "CURRENT. Next rollover $(fmt $(( cur + INTERVAL )))," \
     "in $(( (cur + INTERVAL - now) / 3600 )) hours."
