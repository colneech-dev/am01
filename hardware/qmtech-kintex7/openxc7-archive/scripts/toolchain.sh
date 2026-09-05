# Shared tool discovery. Source this; do not execute it.
#
#     . "$(dirname "$0")/toolchain.sh"
#     resolve_tool YOSYS   yosys
#     resolve_tool NEXTPNR nextpnr-xilinx
#
# WHY THIS EXISTS
# ---------------
# Every script here had grown its own copy of an absolute path like
# /home/colin/src/yosys-upstream/build/yosys. That works on exactly one machine,
# and it is the same defect that made synth_fdre_only.ys unusable to anyone else
# (it read a path under a temp scratchpad directory).
#
# Nothing machine-specific belongs in a committed script. Local paths go in
# toolchain.local, which is gitignored.
#
# RESOLUTION ORDER, first hit wins:
#
#   1. an explicit environment variable        YOSYS=/path/to/yosys ./build.sh
#   2. toolchain.local next to these scripts   (gitignored, per-machine)
#   3. $PATH
#   4. a few conventional install locations
#
# Failing that, the caller reports which tool is missing and how to point at it.

# shellcheck shell=bash

_tc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-machine overrides. Create toolchain.local with e.g.
#     YOSYS=$HOME/src/yosys-upstream/build/yosys
#     NEXTPNR=$HOME/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
#     BBASM=$HOME/src/nextpnr-xilinx-heatmap/build/bbasm
#     NEXTPNR_SRC=$HOME/src/nextpnr-xilinx-heatmap
# Values already set in the environment are not overridden, so an explicit
# VAR=... on the command line still wins.
# Snapshot anything already set, source the file, then put the pre-existing
# values back. toolchain.local is written with plain assignments, which would
# otherwise clobber an explicit VAR=... from the command line -- the opposite of
# the documented precedence, and something a user would only discover by being
# quietly ignored.
if [ -f "$_tc_dir/toolchain.local" ]; then
    _tc_saved=""
    for _v in YOSYS NEXTPNR BBASM NEXTPNR_SRC; do
        if [ -n "${!_v:-}" ]; then
            _tc_saved="$_tc_saved $_v=${!_v}"
        fi
    done
    # shellcheck disable=SC1091
    . "$_tc_dir/toolchain.local"
    for _kv in $_tc_saved; do
        printf -v "${_kv%%=*}" %s "${_kv#*=}"
        export "${_kv%%=*}"
    done
    unset _tc_saved _v _kv
fi

# resolve_tool VARNAME binary-name [extra candidate paths...]
#
# Sets VARNAME if it is empty. Leaves it alone if already set, so an explicit
# override always wins over discovery.
resolve_tool() {
    local var="$1" bin="$2"; shift 2
    local cur="${!var:-}"
    if [ -n "$cur" ]; then
        return 0
    fi

    local cand
    for cand in "$@"; do
        if [ -x "$cand" ]; then
            printf -v "$var" '%s' "$cand"
            export "${var?}"
            return 0
        fi
    done

    cand="$(command -v "$bin" 2>/dev/null || true)"
    if [ -n "$cand" ]; then
        printf -v "$var" '%s' "$cand"
        export "${var?}"
        return 0
    fi

    # Conventional locations, last resort. Deliberately not a user's home
    # directory -- if a tool lives somewhere personal, that belongs in
    # toolchain.local, not in a committed script.
    for cand in "/opt/openxc7/bin/$bin" "/usr/local/bin/$bin" "/usr/bin/$bin"; do
        if [ -x "$cand" ]; then
            printf -v "$var" '%s' "$cand"
            export "${var?}"
            return 0
        fi
    done

    return 1
}

# require_tools VAR:label ...
# Reports every missing tool at once rather than failing on the first.
require_tools() {
    local missing=0 entry name path
    for entry in "$@"; do
        name="${entry%%:*}"
        path="${!name:-}"
        if [ -z "$path" ] || [ ! -x "$path" ]; then
            echo "ERROR: $name not found${path:+ (tried: $path)}" >&2
            missing=1
        fi
    done
    if [ "$missing" = "1" ]; then
        echo "" >&2
        echo "Set it explicitly:      $name=/path/to/tool $0 ..." >&2
        echo "Or once per machine:    echo '$name=/path/to/tool' >> $_tc_dir/toolchain.local" >&2
        return 1
    fi
    return 0
}
