#!/bin/bash
# run_all_sims.sh -- compile and run the Verilog testbenches in this directory.
#
# WHY THE `run` HELPER EXISTS
#
# This script used to print "ALL VERILOG TESTBENCHES PASSED" unconditionally.
# `set -e` catches a non-zero exit, and a testbench that fails here does not
# produce one: it prints "RESULT: FAIL" and calls $finish, which exits 0. So a
# failing test was reported as a pass, and no one would look twice.
#
# That is not hypothetical either. tb_encrypt_oracle -- the only test here that
# compares the RTL against SOFTWARE rather than against other RTL -- sat failing
# for days on a vector from the previous epoch, was never in this script, and
# named a generator that had never been committed.
#
# So `run` greps the output. A testbench is counted as passing only if it says
# nothing about failing.

set -u

HERE=$(dirname "$0")
cd "$HERE"

FAILED=""
N=0

# Compile into a private directory. Two concurrent runs used to write the same
# tb_* executables next to the sources and clobber each other mid-compile,
# which surfaces as a bogus "FAILED TO COMPILE" on whichever lost the race.
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# run <name> <sources...>
run() {
    local name=$1; shift
    N=$((N + 1))
    echo
    echo "$N. Running $name..."
    if ! iverilog -g2005 -o "$BUILD/$name" "$@" 2>&1; then
        echo "   *** $name FAILED TO COMPILE"
        FAILED="$FAILED $name(compile)"
        return
    fi
    local out
    out=$(vvp "$BUILD/$name" 2>&1) || {
        echo "$out"
        echo "   *** $name EXITED NON-ZERO"
        FAILED="$FAILED $name(exit)"
        return
    }
    echo "$out"
    # $finish exits 0 whatever the testbench concluded, so read what it said.
    # Match FAIL/FAILURE as a word ANYWHERE in the line. The earlier
    # pattern anchored to line start after optional spaces, which missed
    # tb_uart_tx_pin's "=== FAIL (timeout) ===" -- a stalled transmitter
    # reported as a pass. ERROR: is case-SENSITIVE so a benign "error:" in
    # compiler-ish output is not a false alarm.
    if echo "$out" | grep -qE 'FAIL(URE)?S?\b|ERROR:'; then
        echo "   *** $name REPORTED FAILURE"
        FAILED="$FAILED $name"
    fi
}

echo "=========================================="
echo " Running All Verilog Testbenches (iverilog)"
echo "=========================================="

run tb_found_path    tb_found_path.v ../hdl/found_path.v
run tb_uart_bridge   tb_uart_bridge.v ../hdl/uart_bridge.v
run tb_bus_write     tb_bus_write.v stub_wrapper_deps.v ../hdl/odocrypt_gpio_wrapper.v ../hdl/uart_bridge.v ../hdl/found_path.v
run tb_uart_tx_pin   tb_uart_tx_pin.v stub_wrapper_deps.v ../hdl/odocrypt_gpio_wrapper.v ../hdl/uart_bridge.v ../hdl/found_path.v

# The software-oracle test. Slow -- a 259-stage pipeline under iverilog -- and
# worth every second of it: this is the only check here that can catch a fault
# the RTL agrees with itself about.
#
# ITS VECTOR IS EPOCH-SPECIFIC. OdoCrypt mutates every 10 days, so regenerate
# after every roll or this fails for a reason unrelated to correctness:
#   gcc -O2 -I<cyclonev>/hps -o gen_encrypt_vector \
#       ../../../tools/gen_encrypt_vector.c <cyclonev>/hps/odocrypt_state.c
#   ./gen_encrypt_vector <seed>      # paste over the localparams in the tb
run tb_encrypt_oracle tb_encrypt_oracle.v ../../../hdl/odocrypt/encrypt.v

# Does miner_pipelined put the right nonce on each result? Slower still --
# it drives the full cipher for 400+ cycles -- but it is the only test that
# exercises the module the whole miner depends on, and nothing did before.
run tb_nonce_label tb_nonce_label.v ../../../hdl/odocrypt/miner_pipelined.v ../../../hdl/odocrypt/miner.v ../../../hdl/odocrypt/encrypt.v ../../../hdl/odocrypt/keccak800.v

# Does INONCE actually split the nonce space between instances? Fast -- it only
# needs the counters, not a hash. It was written, retargeted at the shipping
# core on 2026-09-06, and then never wired into any runner, so nobody ran it.
# It matters more than it looks: the per-core accounting in miner_pipe_am01.c
# identifies which instance found a nonce from BIT 31, which is only meaningful
# if this split holds.
run tb_nonce_split tb_nonce_split.v ../../../hdl/odocrypt/miner_pipelined.v ../../../hdl/odocrypt/miner.v ../../../hdl/odocrypt/encrypt.v ../../../hdl/odocrypt/keccak800.v

echo
echo "=========================================="
if [ -n "$FAILED" ]; then
    echo " FAILED:$FAILED"
    echo "=========================================="
    exit 1
fi
echo " ALL $N VERILOG TESTBENCHES PASSED"
echo "=========================================="
