# Quarantined bitstreams -- DO NOT PROGRAM

Two `.bit` files in this tree load and run but compute wrong results. Both came
from builds that failed loudly in the log and still emitted a full-size
bitstream, because `build.sh` only checked that `.frames` was non-empty and
nextpnr exits 0 even when it abandons arcs.

Renamed to `*.bit.POISONED-DO-NOT-PROGRAM` rather than deleted, so the evidence
survives. Regenerate from source; do not resurrect these.

## out_nm1/am01_qmtech_top.bit

FASM truncated mid-tile after a control-set error: **zero `INIT_` lines**, i.e.
every one of the 420 S-box ROMs is absent.

11,443,734 bytes -- within 5 bytes of a good bitstream, and `file(1)` reports it
as valid Xilinx BIT data for the right part. Nothing short of decoding the FASM
distinguishes it from a working build.

## out_nm1_nosr/am01_qmtech_top.bit

ROM contents are fine here (26,880 `INIT_` lines, all 420 BRAMs present). The
problem is elsewhere: **48 skipped arcs on net `clk_h`**, including
`BUFGCTRL_X0Y10/O -> SLICE_X4Y200/CLKINV_OUT`. Flip-flops with no clock.

Worse, an unrouted arc into a LUT input does not merely leave that input
floating. `fixupRouting` erases `X_ORIG_PORT_A1..A6` for the LUT pair and
restores only the ports whose permutation pip was actually bound; `get_lut_init`
then skips any physical pin lacking that attribute when building `INIT[63:0]`.
The result is the truth table **with that input forced to 0** -- a cofactor. The
LUT deterministically computes the wrong function, and nothing warns.

## How these got past the build

- `NEXTPNR_SKIP_FAILED_ARCS=1` makes nextpnr accept a partial route and exit 0
- `xilinx/arch.cc` returns `result = true` unconditionally for router2, so the
  router's outcome never reaches the exit status
- `command.cc` therefore never fires its `log_error`, and `set -e` cannot help
- `Arch::writeFasm` performs no completeness check of any kind
- timing failures are logged at INFO ("FAIL"), never escalated

## Prevention

`build.sh` now gates on all three failure modes after place-and-route:

- any `SKIP_FAILED_ARCS` line -> hard error
- any `FAIL at` (timing) -> hard error
- design has BRAM but FASM has no `INIT_` lines -> hard error

and it removes stale `.frames`/`.bit` before regenerating, so a failure part-way
cannot leave last run's artifacts looking fresh.

Overrides exist for debug/visualisation builds only:
`OPENXC7_ALLOW_UNROUTED=1`, `OPENXC7_ALLOW_TIMING_FAIL=1`.
