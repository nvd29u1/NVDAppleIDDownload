#include "internal.h"
#include <stdlib.h>
#include <string.h>

static const uint8_t SBOX[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
};

static uint8_t INV[256];
static int inv_ready;

static uint8_t xt(uint8_t x) { return (uint8_t)((x << 1) ^ ((x & 0x80) ? 0x1b : 0)); }

static uint8_t gmul(uint8_t a, uint8_t b) {
    uint8_t p = 0;
    while (b) {
        if (b & 1) p ^= a;
        a = xt(a);
        b >>= 1;
    }
    return p;
}

typedef struct {
    uint8_t rk[240];
    int rounds;
} aes_ctx;

static void aes_init(aes_ctx *c, const uint8_t *key, int keylen) {
    if (!inv_ready) {
        for (int i = 0; i < 256; i++) INV[SBOX[i]] = (uint8_t)i;
        inv_ready = 1;
    }
    int nk = keylen / 4;
    c->rounds = nk + 6;
    int total = 4 * (c->rounds + 1);
    memcpy(c->rk, key, (size_t)keylen);
    uint8_t rcon = 1;
    for (int i = nk; i < total; i++) {
        uint8_t t[4];
        memcpy(t, c->rk + 4 * (i - 1), 4);
        if (i % nk == 0) {
            uint8_t u = t[0];
            t[0] = SBOX[t[1]] ^ rcon;
            t[1] = SBOX[t[2]];
            t[2] = SBOX[t[3]];
            t[3] = SBOX[u];
            rcon = xt(rcon);
        } else if (nk > 6 && i % nk == 4) {
            for (int k = 0; k < 4; k++) t[k] = SBOX[t[k]];
        }
        for (int k = 0; k < 4; k++) c->rk[4 * i + k] = c->rk[4 * (i - nk) + k] ^ t[k];
    }
}

static void aes_enc(const aes_ctx *c, const uint8_t in[16], uint8_t out[16]) {
    uint8_t s[16];
    for (int i = 0; i < 16; i++) s[i] = in[i] ^ c->rk[i];
    for (int r = 1; r <= c->rounds; r++) {
        uint8_t t[16];
        for (int i = 0; i < 16; i++) t[i] = SBOX[s[i]];
        for (int col = 0; col < 4; col++)
            for (int row = 0; row < 4; row++) s[col * 4 + row] = t[((col + row) % 4) * 4 + row];
        if (r != c->rounds) {
            for (int col = 0; col < 4; col++) {
                uint8_t *a = s + col * 4;
                uint8_t a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3];
                a[0] = xt(a0) ^ (xt(a1) ^ a1) ^ a2 ^ a3;
                a[1] = a0 ^ xt(a1) ^ (xt(a2) ^ a2) ^ a3;
                a[2] = a0 ^ a1 ^ xt(a2) ^ (xt(a3) ^ a3);
                a[3] = (xt(a0) ^ a0) ^ a1 ^ a2 ^ xt(a3);
            }
        }
        for (int i = 0; i < 16; i++) s[i] ^= c->rk[16 * r + i];
    }
    memcpy(out, s, 16);
}

static void aes_dec(const aes_ctx *c, const uint8_t in[16], uint8_t out[16]) {
    uint8_t s[16];
    for (int i = 0; i < 16; i++) s[i] = in[i] ^ c->rk[16 * c->rounds + i];
    for (int r = c->rounds - 1; r >= 0; r--) {
        uint8_t t[16];
        for (int col = 0; col < 4; col++)
            for (int row = 0; row < 4; row++) t[((col + row) % 4) * 4 + row] = s[col * 4 + row];
        for (int i = 0; i < 16; i++) s[i] = INV[t[i]] ^ c->rk[16 * r + i];
        if (r != 0) {
            for (int col = 0; col < 4; col++) {
                uint8_t *a = s + col * 4;
                uint8_t a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3];
                a[0] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
                a[1] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
                a[2] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
                a[3] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
            }
        }
    }
    memcpy(out, s, 16);
}

int sayo_aes_cbc_decrypt(const uint8_t *key, size_t keylen, const uint8_t iv[16], const uint8_t *in, size_t n, sayo_buf *out) {
    sayo_buf_init(out);
    if (n % 16 || !n) { sayo_set_error("bad CBC length"); return -1; }
    aes_ctx c;
    aes_init(&c, key, (int)keylen);
    uint8_t prev[16];
    memcpy(prev, iv, 16);
    sayo_buf_reserve(out, n);
    for (size_t i = 0; i < n; i += 16) {
        uint8_t b[16];
        aes_dec(&c, in + i, b);
        for (int k = 0; k < 16; k++) b[k] ^= prev[k];
        memcpy(prev, in + i, 16);
        sayo_buf_append(out, b, 16);
    }
    uint8_t pad = out->data[out->len - 1];
    if (pad == 0 || pad > 16 || pad > out->len) { sayo_set_error("bad padding"); return -1; }
    out->len -= pad;
    return 0;
}

int sayo_aes_cbc_encrypt(const uint8_t *key, size_t keylen, const uint8_t iv[16], const uint8_t *in, size_t n, sayo_buf *out) {
    sayo_buf_init(out);
    aes_ctx c;
    aes_init(&c, key, (int)keylen);
    uint8_t prev[16];
    memcpy(prev, iv, 16);
    size_t total = (n / 16 + 1) * 16;
    uint8_t pad = (uint8_t)(total - n);
    for (size_t i = 0; i < total; i += 16) {
        uint8_t b[16];
        for (int k = 0; k < 16; k++) {
            size_t idx = i + (size_t)k;
            b[k] = (idx < n ? in[idx] : pad) ^ prev[k];
        }
        aes_enc(&c, b, prev);
        sayo_buf_append(out, prev, 16);
    }
    return 0;
}

static void gf_mul(uint8_t x[16], const uint8_t y[16]) {
    uint8_t z[16] = { 0 }, v[16];
    memcpy(v, y, 16);
    for (int i = 0; i < 128; i++) {
        if (x[i / 8] & (0x80 >> (i % 8))) for (int k = 0; k < 16; k++) z[k] ^= v[k];
        int lsb = v[15] & 1;
        for (int k = 15; k > 0; k--) v[k] = (uint8_t)((v[k] >> 1) | (v[k - 1] << 7));
        v[0] >>= 1;
        if (lsb) v[0] ^= 0xe1;
    }
    memcpy(x, z, 16);
}

static void ghash(const uint8_t h[16], const uint8_t *aad, size_t al, const uint8_t *c, size_t cl, uint8_t out[16]) {
    uint8_t y[16] = { 0 };
    for (size_t i = 0; i < al; i += 16) {
        for (size_t k = 0; k < 16 && i + k < al; k++) y[k] ^= aad[i + k];
        gf_mul(y, h);
    }
    for (size_t i = 0; i < cl; i += 16) {
        for (size_t k = 0; k < 16 && i + k < cl; k++) y[k] ^= c[i + k];
        gf_mul(y, h);
    }
    uint8_t lens[16];
    uint64_t ab = (uint64_t)al * 8, cb = (uint64_t)cl * 8;
    for (int k = 0; k < 8; k++) { lens[k] = (uint8_t)(ab >> (56 - 8 * k)); lens[8 + k] = (uint8_t)(cb >> (56 - 8 * k)); }
    for (int k = 0; k < 16; k++) y[k] ^= lens[k];
    gf_mul(y, h);
    memcpy(out, y, 16);
}

static void inc32(uint8_t ctr[16]) {
    for (int k = 15; k >= 12; k--) if (++ctr[k]) break;
}

int sayo_aes_gcm_decrypt(const uint8_t *key, size_t keylen, const uint8_t *iv, size_t ivlen,
                         const uint8_t *aad, size_t aadlen, const uint8_t *in, size_t n,
                         const uint8_t tag[16], sayo_buf *out) {
    sayo_buf_init(out);
    aes_ctx c;
    aes_init(&c, key, (int)keylen);
    uint8_t h[16] = { 0 }, j0[16];
    aes_enc(&c, h, h);
    if (ivlen == 12) {
        memcpy(j0, iv, 12);
        j0[12] = j0[13] = j0[14] = 0;
        j0[15] = 1;
    } else {
        ghash(h, NULL, 0, iv, ivlen, j0);
        uint8_t y[16] = { 0 };
        for (size_t i = 0; i < ivlen; i += 16) {
            for (size_t k = 0; k < 16 && i + k < ivlen; k++) y[k] ^= iv[i + k];
            gf_mul(y, h);
        }
        uint8_t lens[16] = { 0 };
        uint64_t ib = (uint64_t)ivlen * 8;
        for (int k = 0; k < 8; k++) lens[8 + k] = (uint8_t)(ib >> (56 - 8 * k));
        for (int k = 0; k < 16; k++) y[k] ^= lens[k];
        gf_mul(y, h);
        memcpy(j0, y, 16);
    }
    uint8_t s[16], ek[16];
    ghash(h, aad, aadlen, in, n, s);
    aes_enc(&c, j0, ek);
    uint8_t diff = 0;
    for (int k = 0; k < 16; k++) diff |= (uint8_t)((s[k] ^ ek[k]) ^ tag[k]);
    if (diff) { sayo_set_error("GCM tag mismatch"); return -1; }
    uint8_t ctr[16];
    memcpy(ctr, j0, 16);
    sayo_buf_reserve(out, n + 16);
    for (size_t i = 0; i < n; i += 16) {
        inc32(ctr);
        uint8_t ks[16];
        aes_enc(&c, ctr, ks);
        size_t m = n - i < 16 ? n - i : 16;
        for (size_t k = 0; k < m; k++) ks[k] ^= in[i + k];
        sayo_buf_append(out, ks, m);
    }
    return 0;
}

void sayo_hmac_sha256(const uint8_t *key, size_t kl, const uint8_t *msg, size_t ml, uint8_t out[32]) {
    uint8_t k[64] = { 0 };
    if (kl > 64) sayo_sha256(key, kl, k);
    else memcpy(k, key, kl);
    uint8_t ip[64], op[64];
    for (int i = 0; i < 64; i++) { ip[i] = k[i] ^ 0x36; op[i] = k[i] ^ 0x5c; }
    sayo_buf b;
    sayo_buf_init(&b);
    sayo_buf_append(&b, ip, 64);
    sayo_buf_append(&b, msg, ml);
    uint8_t ih[32];
    sayo_sha256(b.data, b.len, ih);
    b.len = 0;
    sayo_buf_append(&b, op, 64);
    sayo_buf_append(&b, ih, 32);
    sayo_sha256(b.data, b.len, out);
    sayo_buf_free(&b);
}

void sayo_pbkdf2_sha256(const uint8_t *pw, size_t pl, const uint8_t *salt, size_t sl, uint32_t iter, uint8_t *out, size_t ol) {
    uint8_t *s = malloc(sl + 4);
    memcpy(s, salt, sl);
    for (uint32_t blk = 1; ol; blk++) {
        s[sl] = (uint8_t)(blk >> 24); s[sl + 1] = (uint8_t)(blk >> 16); s[sl + 2] = (uint8_t)(blk >> 8); s[sl + 3] = (uint8_t)blk;
        uint8_t u[32], t[32];
        sayo_hmac_sha256(pw, pl, s, sl + 4, u);
        memcpy(t, u, 32);
        for (uint32_t i = 1; i < iter; i++) {
            sayo_hmac_sha256(pw, pl, u, 32, u);
            for (int k = 0; k < 32; k++) t[k] ^= u[k];
        }
        size_t m = ol < 32 ? ol : 32;
        memcpy(out, t, m);
        out += m;
        ol -= m;
    }
    free(s);
}

#define BN_WORDS 130

typedef struct {
    uint32_t w[BN_WORDS];
    int n;
} bn;

static void bn_norm(bn *a) { while (a->n > 0 && a->w[a->n - 1] == 0) a->n--; }

static void bn_from_bytes(bn *a, const uint8_t *p, size_t len) {
    memset(a, 0, sizeof *a);
    for (size_t i = 0; i < len; i++) {
        size_t bit = (len - 1 - i) * 8;
        a->w[bit / 32] |= (uint32_t)p[i] << (bit % 32);
    }
    a->n = (int)((len + 3) / 4);
    bn_norm(a);
}

static void bn_to_bytes(const bn *a, uint8_t *p, size_t len) {
    for (size_t i = 0; i < len; i++) {
        size_t bit = (len - 1 - i) * 8;
        size_t wi = bit / 32;
        p[i] = wi < BN_WORDS ? (uint8_t)(a->w[wi] >> (bit % 32)) : 0;
    }
}

static int bn_cmp(const bn *a, const bn *b) {
    if (a->n != b->n) return a->n < b->n ? -1 : 1;
    for (int i = a->n - 1; i >= 0; i--) if (a->w[i] != b->w[i]) return a->w[i] < b->w[i] ? -1 : 1;
    return 0;
}

static void bn_sub(bn *r, const bn *a, const bn *b) {
    int64_t borrow = 0;
    bn t;
    memset(&t, 0, sizeof t);
    for (int i = 0; i < a->n; i++) {
        int64_t d = (int64_t)a->w[i] - (i < b->n ? b->w[i] : 0) - borrow;
        borrow = d < 0;
        t.w[i] = (uint32_t)(d + (borrow ? ((int64_t)1 << 32) : 0));
    }
    t.n = a->n;
    bn_norm(&t);
    *r = t;
}

static void bn_add(bn *r, const bn *a, const bn *b) {
    bn t;
    memset(&t, 0, sizeof t);
    int n = a->n > b->n ? a->n : b->n;
    uint64_t carry = 0;
    for (int i = 0; i < n; i++) {
        uint64_t s = (uint64_t)(i < a->n ? a->w[i] : 0) + (i < b->n ? b->w[i] : 0) + carry;
        t.w[i] = (uint32_t)s;
        carry = s >> 32;
    }
    t.n = n;
    if (carry && n < BN_WORDS) t.w[t.n++] = (uint32_t)carry;
    *r = t;
}

static void bn_mod(bn *r, const bn *a, const bn *m) {
    bn rem;
    memset(&rem, 0, sizeof rem);
    int bits = a->n * 32;
    for (int i = bits - 1; i >= 0; i--) {
        uint32_t carry = (a->w[i / 32] >> (i % 32)) & 1;
        for (int k = 0; k < rem.n; k++) {
            uint32_t nc = rem.w[k] >> 31;
            rem.w[k] = (rem.w[k] << 1) | carry;
            carry = nc;
        }
        if (carry && rem.n < BN_WORDS) rem.w[rem.n++] = carry;
        bn_norm(&rem);
        if (bn_cmp(&rem, m) >= 0) bn_sub(&rem, &rem, m);
    }
    *r = rem;
}

static void bn_mulmod(bn *r, const bn *a, const bn *b, const bn *m) {
    static uint32_t prod[2 * BN_WORDS];
    memset(prod, 0, sizeof prod);
    for (int i = 0; i < a->n; i++) {
        uint64_t carry = 0;
        for (int j = 0; j < b->n; j++) {
            uint64_t t = (uint64_t)a->w[i] * b->w[j] + prod[i + j] + carry;
            prod[i + j] = (uint32_t)t;
            carry = t >> 32;
        }
        int k = i + b->n;
        while (carry) {
            uint64_t t = (uint64_t)prod[k] + carry;
            prod[k++] = (uint32_t)t;
            carry = t >> 32;
        }
    }
    int pn = a->n + b->n;
    bn rem;
    memset(&rem, 0, sizeof rem);
    for (int i = pn * 32 - 1; i >= 0; i--) {
        uint32_t carry = (prod[i / 32] >> (i % 32)) & 1;
        for (int k = 0; k < rem.n; k++) {
            uint32_t nc = rem.w[k] >> 31;
            rem.w[k] = (rem.w[k] << 1) | carry;
            carry = nc;
        }
        if (carry) rem.w[rem.n++] = carry;
        bn_norm(&rem);
        if (bn_cmp(&rem, m) >= 0) bn_sub(&rem, &rem, m);
    }
    *r = rem;
}

static void bn_modexp(bn *r, const bn *base, const bn *exp, const bn *m) {
    bn result, b;
    memset(&result, 0, sizeof result);
    result.w[0] = 1;
    result.n = 1;
    bn_mod(&b, base, m);
    for (int i = exp->n * 32 - 1; i >= 0; i--) {
        bn_mulmod(&result, &result, &result, m);
        if ((exp->w[i / 32] >> (i % 32)) & 1) bn_mulmod(&result, &result, &b, m);
    }
    *r = result;
}

static const uint8_t N2048[256] = {
    0xAC, 0x6B, 0xDB, 0x41, 0x32, 0x4A, 0x9A, 0x9B, 0xF1, 0x66, 0xDE, 0x5E, 0x13, 0x89, 0x58, 0x2F,
    0xAF, 0x72, 0xB6, 0x65, 0x19, 0x87, 0xEE, 0x07, 0xFC, 0x31, 0x92, 0x94, 0x3D, 0xB5, 0x60, 0x50,
    0xA3, 0x73, 0x29, 0xCB, 0xB4, 0xA0, 0x99, 0xED, 0x81, 0x93, 0xE0, 0x75, 0x77, 0x67, 0xA1, 0x3D,
    0xD5, 0x23, 0x12, 0xAB, 0x4B, 0x03, 0x31, 0x0D, 0xCD, 0x7F, 0x48, 0xA9, 0xDA, 0x04, 0xFD, 0x50,
    0xE8, 0x08, 0x39, 0x69, 0xED, 0xB7, 0x67, 0xB0, 0xCF, 0x60, 0x95, 0x17, 0x9A, 0x16, 0x3A, 0xB3,
    0x66, 0x1A, 0x05, 0xFB, 0xD5, 0xFA, 0xAA, 0xE8, 0x29, 0x18, 0xA9, 0x96, 0x2F, 0x0B, 0x93, 0xB8,
    0x55, 0xF9, 0x79, 0x93, 0xEC, 0x97, 0x5E, 0xEA, 0xA8, 0x0D, 0x74, 0x0A, 0xDB, 0xF4, 0xFF, 0x74,
    0x73, 0x59, 0xD0, 0x41, 0xD5, 0xC3, 0x3E, 0xA7, 0x1D, 0x28, 0x1E, 0x44, 0x6B, 0x14, 0x77, 0x3B,
    0xCA, 0x97, 0xB4, 0x3A, 0x23, 0xFB, 0x80, 0x16, 0x76, 0xBD, 0x20, 0x7A, 0x43, 0x6C, 0x64, 0x81,
    0xF1, 0xD2, 0xB9, 0x07, 0x87, 0x17, 0x46, 0x1A, 0x5B, 0x9D, 0x32, 0xE6, 0x88, 0xF8, 0x77, 0x48,
    0x54, 0x45, 0x23, 0xB5, 0x24, 0xB0, 0xD5, 0x7D, 0x5E, 0xA7, 0x7A, 0x27, 0x75, 0xD2, 0xEC, 0xFA,
    0x03, 0x2C, 0xFB, 0xDB, 0xF5, 0x2F, 0xB3, 0x78, 0x61, 0x60, 0x27, 0x90, 0x04, 0xE5, 0x7A, 0xE6,
    0xAF, 0x87, 0x4E, 0x73, 0x03, 0xCE, 0x53, 0x29, 0x9C, 0xCC, 0x04, 0x1C, 0x7B, 0xC3, 0x08, 0xD8,
    0x2A, 0x56, 0x98, 0xF3, 0xA8, 0xD0, 0xC3, 0x82, 0x71, 0xAE, 0x35, 0xF8, 0xE9, 0xDB, 0xFB, 0xB6,
    0x94, 0xB5, 0xC8, 0x03, 0xD8, 0x9F, 0x7A, 0xE4, 0x35, 0xDE, 0x23, 0x6D, 0x52, 0x5F, 0x54, 0x75,
    0x9B, 0x65, 0xE3, 0x72, 0xFC, 0xD6, 0x8E, 0xF2, 0x0F, 0xA7, 0x11, 0x1F, 0x9E, 0x4A, 0xFF, 0x73
};

static void H(sayo_buf *b, uint8_t out[32]) { sayo_sha256(b->data, b->len, out); b->len = 0; }

int sayo_srp_init(sayo_srp *s, const uint8_t random32[32]) {
    memcpy(s->a, random32, 32);
    bn N, g, a, A;
    bn_from_bytes(&N, N2048, 256);
    memset(&g, 0, sizeof g);
    g.w[0] = 2;
    g.n = 1;
    bn_from_bytes(&a, s->a, 32);
    bn_modexp(&A, &g, &a, &N);
    bn_to_bytes(&A, s->A, 256);
    return 0;
}

int sayo_srp_process(sayo_srp *s, const char *username, const uint8_t *pass_key, size_t pkl,
                     const uint8_t *salt, size_t sl, const uint8_t *B, size_t bl) {
    bn N, g, Bn, a, k, u, x, v, t, S, base, exp, zero;
    bn_from_bytes(&N, N2048, 256);
    memset(&g, 0, sizeof g);
    g.w[0] = 2;
    g.n = 1;
    memset(&zero, 0, sizeof zero);
    if (bl > 256) { sayo_set_error("bad SRP B"); return -1; }
    uint8_t Bp[256] = { 0 };
    memcpy(Bp + 256 - bl, B, bl);
    bn_from_bytes(&Bn, Bp, 256);
    bn_mod(&t, &Bn, &N);
    if (t.n == 0) { sayo_set_error("bad SRP B"); return -1; }
    bn_from_bytes(&a, s->a, 32);
    sayo_buf b;
    sayo_buf_init(&b);
    uint8_t h[32], gp[256] = { 0 };
    gp[255] = 2;
    sayo_buf_append(&b, N2048, 256);
    sayo_buf_append(&b, gp, 256);
    H(&b, h);
    bn_from_bytes(&k, h, 32);
    sayo_buf_append(&b, s->A, 256);
    sayo_buf_append(&b, Bp, 256);
    H(&b, h);
    bn_from_bytes(&u, h, 32);
    uint8_t inner[32];
    sayo_buf_byte(&b, ':');
    sayo_buf_append(&b, pass_key, pkl);
    H(&b, inner);
    sayo_buf_append(&b, salt, sl);
    sayo_buf_append(&b, inner, 32);
    H(&b, h);
    bn_from_bytes(&x, h, 32);
    bn_modexp(&v, &g, &x, &N);
    bn_mulmod(&t, &k, &v, &N);
    if (bn_cmp(&Bn, &t) >= 0) bn_sub(&base, &Bn, &t);
    else { bn tmp; bn_add(&tmp, &Bn, &N); bn_sub(&base, &tmp, &t); }
    bn_mod(&base, &base, &N);
    bn ux;
    bn big;
    memset(&big, 0, sizeof big);
    {
        uint32_t prod[BN_WORDS];
        memset(prod, 0, sizeof prod);
        for (int i = 0; i < u.n; i++) {
            uint64_t carry = 0;
            for (int j = 0; j < x.n; j++) {
                uint64_t tt = (uint64_t)u.w[i] * x.w[j] + prod[i + j] + carry;
                prod[i + j] = (uint32_t)tt;
                carry = tt >> 32;
            }
            prod[i + x.n] += (uint32_t)carry;
        }
        memcpy(ux.w, prod, sizeof prod);
        ux.n = u.n + x.n;
        bn_norm(&ux);
    }
    bn_add(&exp, &a, &ux);
    bn_modexp(&S, &base, &exp, &N);
    (void)zero;
    uint8_t Sb[256];
    bn_to_bytes(&S, Sb, 256);
    size_t sk = 0;
    while (sk < 255 && Sb[sk] == 0) sk++;
    sayo_buf_append(&b, Sb + sk, 256 - sk);
    H(&b, s->K);
    uint8_t hn[32], hg[32], hu[32];
    sayo_buf_append(&b, N2048, 256);
    H(&b, hn);
    /* RFC 5054 / corecrypto: g is padded to the length of N before hashing.
     * Hashing the single byte 0x02 gives a wrong M1 and Apple answers -22406. */
    sayo_buf_append(&b, gp, 256);
    H(&b, hg);
    for (int i = 0; i < 32; i++) hn[i] ^= hg[i];
    sayo_buf_str(&b, username);
    H(&b, hu);
    sayo_buf_append(&b, hn, 32);
    sayo_buf_append(&b, hu, 32);
    sayo_buf_append(&b, salt, sl);
    /* In M1 and M2, A and B are hashed without leading zero bytes (unlike in u).
     * Padding them gives a wrong proof (-22406) whenever A or B starts with 0x00. */
    size_t az = 0, bz = 0;
    while (az < 255 && s->A[az] == 0) az++;
    while (bz < 255 && Bp[bz] == 0) bz++;
    sayo_buf_append(&b, s->A + az, 256 - az);
    sayo_buf_append(&b, Bp + bz, 256 - bz);
    sayo_buf_append(&b, s->K, 32);
    H(&b, s->M1);
    sayo_buf_append(&b, s->A + az, 256 - az);
    sayo_buf_append(&b, s->M1, 32);
    sayo_buf_append(&b, s->K, 32);
    H(&b, s->M2);
    sayo_buf_free(&b);
    (void)big;
    return 0;
}
