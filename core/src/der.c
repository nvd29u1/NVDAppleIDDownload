#include "internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int der_len(sayo_buf *out, size_t n) {
    if (n < 0x80) return sayo_buf_byte(out, (uint8_t)n);
    uint8_t t[8];
    int k = 0;
    while (n) { t[k++] = (uint8_t)n; n >>= 8; }
    if (sayo_buf_byte(out, 0x80 | k)) return -1;
    while (k) if (sayo_buf_byte(out, t[--k])) return -1;
    return 0;
}

int der_tlv(sayo_buf *out, uint8_t tag, const uint8_t *p, size_t n) {
    if (sayo_buf_byte(out, tag) || der_len(out, n)) return -1;
    return sayo_buf_append(out, p, n);
}

int der_wrap(sayo_buf *out, uint8_t tag, sayo_buf *inner) {
    int rc = der_tlv(out, tag, inner->data, inner->len);
    sayo_buf_free(inner);
    return rc;
}

int der_oid(sayo_buf *out, const char *dotted) {
    uint64_t arcs[32];
    int n = 0;
    const char *s = dotted;
    while (*s && n < 32) {
        arcs[n++] = strtoull(s, (char **)&s, 10);
        if (*s == '.') s++;
    }
    sayo_buf b;
    sayo_buf_init(&b);
    sayo_buf_byte(&b, (uint8_t)(arcs[0] * 40 + arcs[1]));
    for (int i = 2; i < n; i++) {
        uint8_t t[10];
        int k = 0;
        uint64_t v = arcs[i];
        do { t[k++] = v & 0x7f; v >>= 7; } while (v);
        while (k) {
            k--;
            sayo_buf_byte(&b, t[k] | (k ? 0x80 : 0));
        }
    }
    return der_wrap(out, 0x06, &b);
}

int der_int_u64(sayo_buf *out, uint64_t v) {
    uint8_t t[9];
    int k = 0;
    do { t[k++] = (uint8_t)v; v >>= 8; } while (v);
    if (t[k - 1] & 0x80) t[k++] = 0;
    uint8_t r[9];
    for (int i = 0; i < k; i++) r[i] = t[k - 1 - i];
    return der_tlv(out, 0x02, r, k);
}

int der_utf8(sayo_buf *out, const char *s) {
    return der_tlv(out, 0x0c, (const uint8_t *)s, strlen(s));
}

int der_null(sayo_buf *out) {
    uint8_t z[2] = { 0x05, 0x00 };
    return sayo_buf_append(out, z, 2);
}

int der_utctime(sayo_buf *out, int64_t unix_time) {
    time_t t = (time_t)unix_time;
    struct tm tm;
    gmtime_r(&t, &tm);
    char s[32];
    snprintf(s, sizeof s, "%02d%02d%02d%02d%02d%02dZ", tm.tm_year % 100, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec);
    return der_tlv(out, 0x17, (const uint8_t *)s, strlen(s));
}

int der_next(der_r *r, der_item *it) {
    if (r->n < 2) return -1;
    const uint8_t *start = r->p;
    uint8_t tag = r->p[0];
    size_t len, hl = 2;
    uint8_t l0 = r->p[1];
    if (l0 < 0x80) len = l0;
    else if (l0 == 0x80) return -1;
    else {
        int k = l0 & 0x7f;
        if (k > 8 || r->n < 2 + (size_t)k) return -1;
        len = 0;
        for (int i = 0; i < k; i++) len = (len << 8) | r->p[2 + i];
        hl += k;
    }
    if (len > r->n - hl) return -1;
    it->tag = tag;
    it->val = start + hl;
    it->len = len;
    it->raw = start;
    it->raw_len = hl + len;
    r->p += hl + len;
    r->n -= hl + len;
    return 0;
}

int der_enter(const der_item *it, der_r *r) {
    r->p = it->val;
    r->n = it->len;
    return 0;
}
