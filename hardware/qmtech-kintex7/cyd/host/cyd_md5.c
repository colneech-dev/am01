/*
 * cyd_md5 -- RFC 1321 MD5. See cyd_md5.h for why it is here.
 *
 * Written to be obviously the standard algorithm rather than clever: the
 * round constants are the published table, the shift amounts are the
 * published table, and the four round functions are named as in the RFC.
 * sim/test_cyd_md5.c checks it against the RFC's own test vectors, which is
 * the only reason to believe any of it.
 */
#include "cyd_md5.h"

#include <string.h>

#define ROTL32(x, c) (((x) << (c)) | ((x) >> (32 - (c))))

/* T[i] = floor(2^32 * abs(sin(i+1))), the RFC's table. */
static const uint32_t T[64] = {
    0xd76aa478u, 0xe8c7b756u, 0x242070dbu, 0xc1bdceeeu,
    0xf57c0fafu, 0x4787c62au, 0xa8304613u, 0xfd469501u,
    0x698098d8u, 0x8b44f7afu, 0xffff5bb1u, 0x895cd7beu,
    0x6b901122u, 0xfd987193u, 0xa679438eu, 0x49b40821u,
    0xf61e2562u, 0xc040b340u, 0x265e5a51u, 0xe9b6c7aau,
    0xd62f105du, 0x02441453u, 0xd8a1e681u, 0xe7d3fbc8u,
    0x21e1cde6u, 0xc33707d6u, 0xf4d50d87u, 0x455a14edu,
    0xa9e3e905u, 0xfcefa3f8u, 0x676f02d9u, 0x8d2a4c8au,
    0xfffa3942u, 0x8771f681u, 0x6d9d6122u, 0xfde5380cu,
    0xa4beea44u, 0x4bdecfa9u, 0xf6bb4b60u, 0xbebfbc70u,
    0x289b7ec6u, 0xeaa127fau, 0xd4ef3085u, 0x04881d05u,
    0xd9d4d039u, 0xe6db99e5u, 0x1fa27cf8u, 0xc4ac5665u,
    0xf4292244u, 0x432aff97u, 0xab9423a7u, 0xfc93a039u,
    0x655b59c3u, 0x8f0ccc92u, 0xffeff47du, 0x85845dd1u,
    0x6fa87e4fu, 0xfe2ce6e0u, 0xa3014314u, 0x4e0811a1u,
    0xf7537e82u, 0xbd3af235u, 0x2ad7d2bbu, 0xeb86d391u
};

static const uint8_t S[64] = {
    7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,
    5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,
    4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,
    6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21
};

/* Little-endian load: MD5 is defined on little-endian words regardless of the
 * host, so this must not be a cast through a uint32_t pointer. */
static uint32_t ld32(const uint8_t *p)
{
    return (uint32_t)p[0]       | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void st32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v);
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void block(cyd_md5_t *c, const uint8_t *p)
{
    uint32_t m[16];
    for (int i = 0; i < 16; i++)
        m[i] = ld32(p + i * 4);

    uint32_t a = c->state[0], b = c->state[1];
    uint32_t d = c->state[3], cc = c->state[2];

    for (int i = 0; i < 64; i++) {
        uint32_t f;
        int      g;

        if (i < 16) {                       /* F */
            f = (b & cc) | (~b & d);
            g = i;
        } else if (i < 32) {                /* G */
            f = (d & b) | (~d & cc);
            g = (5 * i + 1) % 16;
        } else if (i < 48) {                /* H */
            f = b ^ cc ^ d;
            g = (3 * i + 5) % 16;
        } else {                            /* I */
            f = cc ^ (b | ~d);
            g = (7 * i) % 16;
        }

        uint32_t tmp = d;
        d  = cc;
        cc = b;
        b  = b + ROTL32(a + f + T[i] + m[g], S[i]);
        a  = tmp;
    }

    c->state[0] += a;
    c->state[1] += b;
    c->state[2] += cc;
    c->state[3] += d;
}

void cyd_md5_init(cyd_md5_t *c)
{
    c->state[0] = 0x67452301u;
    c->state[1] = 0xefcdab89u;
    c->state[2] = 0x98badcfeu;
    c->state[3] = 0x10325476u;
    c->bits     = 0;
    c->buflen   = 0;
}

void cyd_md5_update(cyd_md5_t *c, const void *data, size_t len)
{
    const uint8_t *p = (const uint8_t *)data;

    c->bits += (uint64_t)len * 8u;

    /* Top up a partial block first, then run whole blocks straight out of the
     * caller's buffer -- the image is read in 512-byte chunks, so this path
     * does the work and the copy above is the rare case. */
    if (c->buflen) {
        size_t need = 64 - c->buflen;
        size_t take = len < need ? len : need;
        memcpy(c->buf + c->buflen, p, take);
        c->buflen += take;
        p   += take;
        len -= take;
        if (c->buflen == 64) {
            block(c, c->buf);
            c->buflen = 0;
        }
    }

    while (len >= 64) {
        block(c, p);
        p   += 64;
        len -= 64;
    }

    if (len) {
        memcpy(c->buf, p, len);
        c->buflen = len;
    }
}

void cyd_md5_final(cyd_md5_t *c, uint8_t out[16])
{
    /* 0x80, then zeros, then the LENGTH IN BITS as a little-endian 64-bit
     * value. The length is captured before padding is appended -- padding is
     * not part of the message. */
    uint64_t bits = c->bits;

    uint8_t pad = 0x80;
    cyd_md5_update(c, &pad, 1);
    c->bits = bits;              /* update() counted the padding; undo that */

    uint8_t zero = 0x00;
    while (c->buflen != 56) {
        cyd_md5_update(c, &zero, 1);
        c->bits = bits;
    }

    uint8_t len_le[8];
    for (int i = 0; i < 8; i++)
        len_le[i] = (uint8_t)(bits >> (8 * i));
    cyd_md5_update(c, len_le, 8);

    for (int i = 0; i < 4; i++)
        st32(out + i * 4, c->state[i]);
}

void cyd_md5_hex(const uint8_t digest[16], char out[33])
{
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        out[i * 2]     = hex[(digest[i] >> 4) & 0xF];
        out[i * 2 + 1] = hex[digest[i] & 0xF];
    }
    out[32] = '\0';
}
