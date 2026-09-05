/*
 * cyd_md5 -- MD5, for the panel OTA transfer and nothing else.
 *
 * Here rather than linked from a library because the CM4 image is Buildroot
 * with no guaranteed libcrypto, and because the alternative -- shelling out
 * to md5sum -- puts an operator-supplied path through a command line for no
 * gain. It is ~150 lines and there are published test vectors, so it can be
 * proved rather than trusted (see sim/test_cyd_md5.c).
 *
 * NOT FOR SECURITY. MD5 is broken against deliberate collisions and must not
 * be used to authenticate anything. Its job here is exactly the job it is
 * still good at: catching a corrupted 485KB transfer over a serial link. The
 * ESP32's Update library takes an MD5 and no other digest, which is what
 * settles the choice.
 */
#ifndef CYD_MD5_H
#define CYD_MD5_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t state[4];
    uint64_t bits;
    uint8_t  buf[64];
    size_t   buflen;
} cyd_md5_t;

void cyd_md5_init(cyd_md5_t *c);
void cyd_md5_update(cyd_md5_t *c, const void *data, size_t len);

/* Writes 16 raw bytes. */
void cyd_md5_final(cyd_md5_t *c, uint8_t out[16]);

/* Writes 32 lowercase hex characters plus a NUL, so `out` needs 33 bytes.
 * Lowercase because that is what the firmware normalises to. */
void cyd_md5_hex(const uint8_t digest[16], char out[33]);

#endif /* CYD_MD5_H */
