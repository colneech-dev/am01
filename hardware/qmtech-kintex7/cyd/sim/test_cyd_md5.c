/*
 * test_cyd_md5 -- cyd_md5 against the RFC 1321 test vectors.
 *
 * The whole reason for hand-rolling MD5 in this tree is that it can be
 * checked against published vectors rather than trusted, so this is not
 * optional coverage. A wrong MD5 would not fail loudly: it would make every
 * OTA transfer fail verification on the panel and look like a bad link.
 *
 *   cc -o test_cyd_md5 test_cyd_md5.c ../host/cyd_md5.c && ./test_cyd_md5
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../host/cyd_md5.h"

static int checks, errors;

static void ok(int cond, const char *what)
{
    checks++;
    if (cond) {
        printf("  PASS  %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        errors++;
    }
}

static void hash_str(const char *s, char out[33])
{
    cyd_md5_t c;
    uint8_t   d[16];
    cyd_md5_init(&c);
    cyd_md5_update(&c, s, strlen(s));
    cyd_md5_final(&c, d);
    cyd_md5_hex(d, out);
}

static void vec(const char *in, const char *expect)
{
    char got[33];
    char label[96];
    hash_str(in, got);
    snprintf(label, sizeof label, "\"%.32s%s\" -> %s",
             in, strlen(in) > 32 ? "..." : "", expect);
    if (strcmp(got, expect) != 0)
        printf("        got %s\n", got);
    ok(strcmp(got, expect) == 0, label);
}

int main(void)
{
    printf("=== cyd_md5 vs RFC 1321 ===\n");

    vec("",    "d41d8cd98f00b204e9800998ecf8427e");
    vec("a",   "0cc175b9c0f1b6a831c399e269772661");
    vec("abc", "900150983cd24fb0d6963f7d28e17f72");
    vec("message digest", "f96b697d7cb7938d525a2f31aaf161d0");
    vec("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b");
    vec("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
        "d174ab98d277d9f5a5611c2c9f419d9f");
    vec("12345678901234567890123456789012345678901234567890"
        "123456789012345678901234567890",
        "57edf4a22be3c955ac49da2e2107b67a");

    /* THE BLOCK-BOUNDARY CASES. Padding is where MD5 implementations go
     * wrong, and every one of these lands the message length at or beside the
     * 56-byte point where the length field either does or does not force an
     * extra block. The vectors above happen to miss all of them. */
    {
        static const struct { int len; const char *md5; } edge[] = {
            { 55, "ef1772b6dff9a122358552954ad0df65" },
            { 56, "3b0c8ac703f828b04c6c197006d17218" },
            { 57, "652b906d60af96844ebd21b674f35e93" },
            { 63, "b06521f39153d618550606be297466d5" },
            { 64, "014842d480b571495a4a0363793f7367" },
            { 65, "c743a45e0d2e6a95cb859adae0248435" },
        };
        for (size_t i = 0; i < sizeof edge / sizeof edge[0]; i++) {
            char *s = malloc((size_t)edge[i].len + 1);
            memset(s, 'a', (size_t)edge[i].len);
            s[edge[i].len] = '\0';
            char got[33], label[64];
            hash_str(s, got);
            snprintf(label, sizeof label, "%d x 'a'", edge[i].len);
            if (strcmp(got, edge[i].md5) != 0)
                printf("        got %s want %s\n", got, edge[i].md5);
            ok(strcmp(got, edge[i].md5) == 0, label);
            free(s);
        }
    }

    /* Streaming must equal one-shot: the sender feeds the image in 512-byte
     * chunks, so an update() that mishandles a partial block would produce a
     * digest that only differs for real transfers. */
    {
        size_t   n = 100000;
        uint8_t *big = malloc(n);
        for (size_t i = 0; i < n; i++)
            big[i] = (uint8_t)(i * 31u + (i >> 8));

        cyd_md5_t a, b;
        uint8_t   da[16], db[16];

        cyd_md5_init(&a);
        cyd_md5_update(&a, big, n);
        cyd_md5_final(&a, da);

        cyd_md5_init(&b);
        for (size_t off = 0; off < n; off += 512) {
            size_t take = n - off < 512 ? n - off : 512;
            cyd_md5_update(&b, big + off, take);
        }
        cyd_md5_final(&b, db);

        ok(memcmp(da, db, 16) == 0, "100000 bytes: one-shot == 512-byte chunks");

        /* And odd chunk sizes, which straddle blocks differently again. */
        cyd_md5_init(&b);
        for (size_t off = 0; off < n; off += 7) {
            size_t take = n - off < 7 ? n - off : 7;
            cyd_md5_update(&b, big + off, take);
        }
        cyd_md5_final(&b, db);
        ok(memcmp(da, db, 16) == 0, "same, in 7-byte chunks");

        free(big);
    }

    printf("\n");
    if (!errors) {
        printf("=== ALL %d CHECKS PASSED ===\n", checks);
        return 0;
    }
    printf("=== %d of %d CHECK(S) FAILED ===\n", errors, checks);
    return 1;
}
