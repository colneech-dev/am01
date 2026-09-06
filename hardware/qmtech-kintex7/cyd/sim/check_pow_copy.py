#!/usr/bin/env python3
"""Fail if test_pow_math.c's copies have drifted from the shipping code.

test_pow_math.c does not link the real target_met() and hash_to_difficulty().
It cannot: both are `static` in miner_pipe_am01.c, and linking that would drag
in libgpiod, the stratum client and the whole miner. So it TRANSCRIBES them.

That is a reasonable trade only while the transcription is exact. A test that
verifies a copy passes for ever while the original drifts -- and these two
functions decide whether a share is valid and how much it is worth, so a
divergence would be invisible in the suite and expensive in production.

This compares the function bodies token by token, ignoring comments and
whitespace, and is wired into `make check`.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REAL = os.path.join(HERE, '..', '..', 'sw', 'miner_pipe_am01.c')
TEST = os.path.join(HERE, 'test_pow_math.c')

FUNCS = ('target_met', 'hash_to_difficulty')


def body(path, name):
    """The DEFINITION of `name`, or None. Skips forward declarations."""
    s = io.open(path, encoding='utf-8', newline='').read().replace('\r\n', '\n')
    for m in re.finditer(r'static\s+(?:int|double)\s+' + name + r'\s*\(', s):
        i = m.start()
        brace, semi = s.find('{', i), s.find(';', i)
        if brace < 0 or (0 <= semi < brace):
            continue                       # a declaration, not the definition
        depth = 0
        for k in range(brace, len(s)):
            if s[k] == '{':
                depth += 1
            elif s[k] == '}':
                depth -= 1
                if depth == 0:
                    return s[i:k + 1]
    return None


def tokens(text):
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'//[^\n]*', ' ', text)
    return re.split(r'\s+', text.strip())


def main():
    bad = 0
    for fn in FUNCS:
        real, copy = body(REAL, fn), body(TEST, fn)
        if real is None or copy is None:
            print('  %-20s CANNOT EXTRACT (real=%s test=%s)'
                  % (fn, real is not None, copy is not None))
            bad += 1
            continue
        a, b = tokens(real), tokens(copy)
        if a == b:
            print('  %-20s matches miner_pipe_am01.c' % fn)
            continue
        bad += 1
        print('  %-20s *** DIVERGED from miner_pipe_am01.c ***' % fn)
        for k in range(min(len(a), len(b))):
            if a[k] != b[k]:
                print('      real: ...%s' % ' '.join(a[max(0, k - 8):k + 8]))
                print('      copy: ...%s' % ' '.join(b[max(0, k - 8):k + 8]))
                break
        else:
            print('      one is a prefix of the other: %d vs %d tokens'
                  % (len(a), len(b)))
    if bad:
        print('\n  test_pow_math.c is testing something the miner no longer'
              ' does.\n  Re-copy the function(s) above, or make the test link'
              ' the real ones.')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
