#include "sayo.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Thread_local char g_err[512];

const char *sayo_last_error(void) { return g_err; }

void sayo_set_error(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
}

void sayo_buf_init(sayo_buf *b) { b->data = NULL; b->len = 0; b->cap = 0; }

void sayo_buf_free(sayo_buf *b) { free(b->data); sayo_buf_init(b); }

int sayo_buf_reserve(sayo_buf *b, size_t extra) {
    if (b->len + extra <= b->cap) return 0;
    size_t nc = b->cap ? b->cap : 256;
    while (nc < b->len + extra) nc *= 2;
    uint8_t *p = realloc(b->data, nc);
    if (!p) { sayo_set_error("out of memory"); return -1; }
    b->data = p;
    b->cap = nc;
    return 0;
}

int sayo_buf_append(sayo_buf *b, const void *p, size_t n) {
    if (!n) return 0;
    if (sayo_buf_reserve(b, n)) return -1;
    memcpy(b->data + b->len, p, n);
    b->len += n;
    return 0;
}

int sayo_buf_byte(sayo_buf *b, uint8_t v) { return sayo_buf_append(b, &v, 1); }

int sayo_buf_be32(sayo_buf *b, uint32_t v) {
    uint8_t t[4] = { v >> 24, v >> 16, v >> 8, v };
    return sayo_buf_append(b, t, 4);
}

int sayo_buf_be64(sayo_buf *b, uint64_t v) {
    return sayo_buf_be32(b, (uint32_t)(v >> 32)) || sayo_buf_be32(b, (uint32_t)v);
}

int sayo_buf_str(sayo_buf *b, const char *s) { return sayo_buf_append(b, s, strlen(s)); }

int sayo_buf_fill(sayo_buf *b, uint8_t v, size_t n) {
    if (sayo_buf_reserve(b, n)) return -1;
    memset(b->data + b->len, v, n);
    b->len += n;
    return 0;
}

int sayo_read_file(const char *path, sayo_buf *out) {
    FILE *f = fopen(path, "rb");
    if (!f) { sayo_set_error("cannot open %s", path); return -1; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    sayo_buf_init(out);
    if (n < 0 || sayo_buf_reserve(out, (size_t)n + 1)) { fclose(f); return -1; }
    if (n && fread(out->data, 1, (size_t)n, f) != (size_t)n) {
        fclose(f);
        sayo_buf_free(out);
        sayo_set_error("cannot read %s", path);
        return -1;
    }
    out->len = (size_t)n;
    out->data[n] = 0;
    fclose(f);
    return 0;
}

int sayo_write_file(const char *path, const void *p, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) { sayo_set_error("cannot create %s", path); return -1; }
    if (n && fwrite(p, 1, n, f) != n) { fclose(f); sayo_set_error("cannot write %s", path); return -1; }
    fclose(f);
    return 0;
}
