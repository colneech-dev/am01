#!/usr/bin/env python3
"""Find identifiers USED BEFORE THEY ARE DECLARED in a Verilog module.

WHY A CUSTOM CHECK
------------------
No tool here catches this. `ticket2moon_i` was consumed by a port connection
113 lines above its `reg` declaration, and:

  * yosys compiled it silently and bound it correctly
  * Verilator `--lint-only -Wall` reported ZERO IMPLICIT warnings on that exact
    file -- verified against the known-bad version, not assumed
  * adding `default_nettype none` changed nothing in EITHER tool

All three because both tools scan the whole module for declarations before
resolving identifiers, so no implicit net is ever created and there is nothing
for an IMPLICIT warning or `default_nettype none` to fire on.

That silence is the hazard. Strict Verilog creates an implicit 1-bit net at the
point of use, and a procedural assignment to something declared a wire is not
legal -- so the code is internally contradictory and every tool resolves the
ambiguity by its own rules. It has worked everywhere tried; it is not
guaranteed to, and the failure mode is a silently floating net rather than an
error.

WHAT IT REPORTS
---------------
For each module-scope declaration, the first line on which that identifier
appears. If the use precedes the declaration, it is reported. Comments and
string literals are stripped first so they cannot create false hits.

LIMITS, stated plainly: this is a regex pass, not a parser. It does not track
scopes (generate/task/function bodies), so a name declared inside a block and
also used earlier at module level may be misreported. Treat hits as things to
look at, not as proven defects -- which is the right posture anyway, since the
tools accept all of them.

Usage:  audit_decl_order.py <file.v> [more.v ...]
Exit:   1 if any use-before-declaration was found.
"""
import re
import sys

DECL = re.compile(
    r"^\s*(?:output\s+|input\s+|inout\s+)?"
    r"(reg|wire|integer|genvar|real|localparam|parameter)\b"
    r"(?:\s+signed)?"
    r"(?:\s*\[[^\]]*\])?"
    r"\s+(.+)$")

# Names in a declaration tail: "a, b = 1'b0, c [0:3]" -> a, b, c
NAME = re.compile(r"\b([A-Za-z_][A-Za-z0-9_$]*)\b")
WORD = re.compile(r"\b([A-Za-z_][A-Za-z0-9_$]*)\b")

KEYWORDS = {
    "reg", "wire", "integer", "genvar", "real", "localparam", "parameter",
    "signed", "input", "output", "inout", "begin", "end", "module",
    "endmodule", "always", "assign", "posedge", "negedge", "if", "else",
    "case", "endcase", "default", "for", "generate", "endgenerate",
}


def strip_comments(text):
    """Remove // and /* */ comments and string literals, preserving newlines."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            if j < 0:
                break
            out.append(" " * (j - i))
            i = j
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(" " * (min(j + 1, n) - i))
            i = min(j + 1, n)
        else:
            out.append(c)
            i += 1
    return "".join(out)


def audit_module(lines, base):
    """Audit one module body. `lines` are its lines, `base` the 1-based offset."""
    decls = {}
    for off, line in enumerate(lines):
        m = DECL.match(line)
        if not m:
            continue
        tail = m.group(2)
        tail = re.sub(r"=\s*[^,]+", "", tail)       # drop initialisers
        tail = re.sub(r"\[[^\]]*\]", "", tail)      # drop dimensions
        for nm in NAME.findall(tail):
            if nm not in KEYWORDS and nm not in decls:
                decls[nm] = base + off

    # The module header names ports without using them; Verilog-1995 style then
    # declares direction and type below, which is legal and must not be flagged.
    header = set()
    in_hdr = False
    for off, line in enumerate(lines):
        if not in_hdr and re.match(r"\s*module\b", line):
            in_hdr = True
        if in_hdr:
            header.add(base + off)
            if ";" in line:
                in_hdr = False

    first_use = {}
    for off, line in enumerate(lines):
        ln = base + off
        if DECL.match(line) or ln in header:
            continue
        for nm in WORD.findall(line):
            if nm in decls and nm not in first_use:
                first_use[nm] = ln

    return [(nm, first_use[nm], decls[nm])
            for nm in decls
            if nm in first_use and first_use[nm] < decls[nm]], len(decls)


def audit(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    lines = strip_comments(raw).split("\n")

    # Split into module bodies. Identifier scope in Verilog is the module, so
    # auditing a whole file as one namespace matches a name declared in one
    # module against the same name used in another -- 5 such false hits in
    # keccak800.v, which holds 12 modules.
    spans, cur, cur_base = [], None, 0
    for ln, line in enumerate(lines, 1):
        if re.match(r"\s*module\b", line):
            cur, cur_base = [], ln
        if cur is not None:
            cur.append(line)
            if re.match(r"\s*endmodule\b", line):
                spans.append((cur, cur_base))
                cur = None
    if cur:
        spans.append((cur, cur_base))

    hits, ndecl = [], 0
    for body, base in spans:
        h, n = audit_module(body, base)
        hits += h
        ndecl += n
    hits.sort(key=lambda h: h[1])
    return hits, ndecl


bad = 0
for p in sys.argv[1:]:
    hits, ndecl = audit(p)
    print("%s -- %d declarations across all modules" % (p, ndecl))
    if not hits:
        print("    no use-before-declaration found")
        continue
    bad = 1
    for nm, use, decl in hits:
        print("    %-28s used line %-6d declared line %-6d (%d lines later)"
              % (nm, use, decl, decl - use))
sys.exit(bad)
