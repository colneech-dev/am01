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
# Exit 0 current, 1 stale, 2 inconsistent or unreadable,
#      3 prepared ahead of the chain (built early for a rollover).

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

# WHICH CORE this encrypt.v is, read from the file rather than assumed.
#
# The regenerate command printed below used to be hardcoded without
# --bram-out-reg. Following it after a --bram-out-reg build silently produced a
# different core -- 2 clock cycles per round instead of 3, with the round-key
# tap in a different place -- and the only symptom would have been rejected
# shares. Echoing back what the file itself records is what makes the
# instruction correct for whichever core is actually in the tree.
enc_flags=$(sed -n 's|^// odo_gen flags: *||p' "$ENC" | head -1)
enc_thr=$(sed -n 's|^// Throughput: *\([0-9][0-9]*\).*|\1|p' "$ENC" | head -1)
[ -n "$enc_thr" ] || enc_thr=4
flags_known=1
case "$enc_flags" in
"(none)") enc_flags="" ;;
"")       enc_flags=""; flags_known=0 ;;
*)        enc_flags=" $enc_flags" ;;
esac

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

# AHEAD of the chain, i.e. built early for a rollover that has not happened.
# Reported separately because it is a DELIBERATE state, not a fault: the
# rebuild takes ~1h35m and the sensible time to do it is before the deadline,
# not after it.
#
# This case used to fall through to the stale branch below, which printed
# "STALE by -1 epoch(s)" -- a negative count -- and then instructed the reader
# to regenerate back to the current epoch. Following that would silently undo
# the preparation it was reporting on.
if [ "$enc_seed" -gt "$cur" ]; then
	ahead=$(( (enc_seed - cur) / INTERVAL ))
	echo
	echo "PREPARED, $ahead epoch(s) AHEAD of the chain. This is not an error."
	echo
	echo "The tree implements $(fmt "$enc_seed"), the chain is still on"
	echo "$(fmt "$cur"). A bitstream built from this tree is CORRECT but must"
	echo "NOT be flashed until the rollover -- until then it would mine rejects."
	echo
	echo "  flash after : $(fmt "$enc_seed")"
	echo "  that is in  : $(( (enc_seed - now) / 3600 )) hours"
	echo
	echo "To go back to the live epoch instead:"
	echo "  cd tools/odo_gen && make odo_gen"
	echo "  ./odo_gen $cur $enc_thr encrypt_4$enc_flags > ../../hdl/odocrypt/encrypt.v"
	echo "  then set ODO_SEED = 32'd$cur in odocrypt_gpio_wrapper.v"
	exit 3
fi

if [ "$enc_seed" != "$cur" ]; then
	behind=$(( (cur - enc_seed) / INTERVAL ))
	echo
	echo "STALE by $behind epoch(s). Shares will be rejected. Regenerate:"
	echo "  cd tools/odo_gen && make odo_gen"
	echo "  ./odo_gen $cur $enc_thr encrypt_4$enc_flags > ../../hdl/odocrypt/encrypt.v"
	echo "  then set ODO_SEED = 32'd$cur in odocrypt_gpio_wrapper.v"
	if [ "$flags_known" = 0 ]; then
		echo
		echo "  WARNING: this encrypt.v predates the 'odo_gen flags' stamp, so"
		echo "  which core produced it is NOT recorded. Check whether the build"
		echo "  you are matching used --bram-out-reg before regenerating -- the"
		echo "  two are different designs and the wrong one mines rejects."
	fi
	echo
	echo "Note this changes the sbox contents, so place-and-route results from"
	echo "the previous epoch no longer apply."
	exit 1
fi

echo
if [ "$flags_known" = 1 ]; then
	echo "Core: throughput $enc_thr,${enc_flags:- no extra flags}."
else
	echo "Core: throughput $enc_thr, flags NOT RECORDED (pre-stamp encrypt.v)."
fi
echo "CURRENT. Next rollover $(fmt $(( cur + INTERVAL )))," \
     "in $(( (cur + INTERVAL - now) / 3600 )) hours."
