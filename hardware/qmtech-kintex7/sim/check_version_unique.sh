#!/bin/sh
# Every wrapper must report a VERSION no other wrapper reports.
#
# WHY THIS EXISTS. On 2026-09-15 hdl/odocrypt_gpio_wrapper.v and
# hdl/mux4/odocrypt_gpio_wrapper_mux4.v both reported 0x020C. The two designs
# differ in instance count, clocking and S-box structure, and the ONLY
# runtime way to tell which one a board had loaded was the VERSION register --
# which said the same thing for both. Three days of hardware measurements were
# attributed to a design that could not be shown to have been running.
#
# A filename is not identification: bitstreams get copied, renamed and staged
# to /boot by three different scripts. The register is the identification.
#
# Exits non-zero on a collision, so it can gate a build.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

dups=$(
    find "$here/hdl" -name '*_gpio_wrapper*.v' -print | sort | while read -r f; do
        v=$(sed -n "s/.*VERSION *= *16'h\([0-9A-Fa-f]*\).*/\1/p" "$f" | head -1)
        [ -n "$v" ] || continue
        printf '%s\t%s\n' "$(printf '%s' "$v" | tr 'a-f' 'A-F')" "$f"
    done | sort | awk -F'\t' '
        { if ($1 == prev) { if (!shown[$1]++) print prevline; print $0; n++ }
          prev = $1; prevline = $0 }
        END { exit (n ? 1 : 0) }'
) || {
    echo "check_version_unique: FAIL -- wrappers share a VERSION:" >&2
    printf '%s\n' "$dups" >&2
    echo "" >&2
    echo "Bump the MINOR byte of one of them. The major byte gates host" >&2
    echo "behaviour (miner_pipe_am01.c: major < 2 selects halt-on-find)." >&2
    exit 1
}

find "$here/hdl" -name '*_gpio_wrapper*.v' -print | sort | while read -r f; do
    v=$(sed -n "s/.*VERSION *= *16'h\([0-9A-Fa-f]*\).*/\1/p" "$f" | head -1)
    printf '  %-52s 0x%s\n' "${f#$here/}" "${v:-NONE}"
done
echo "check_version_unique: OK -- every wrapper VERSION is distinct"
