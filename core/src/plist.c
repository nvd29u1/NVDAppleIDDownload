#include "internal.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

pl_node *pl_new(pl_type t) {
    pl_node *n = calloc(1, sizeof *n);
    if (n) n->type = t;
    return n;
}

pl_node *pl_new_str(const char *s) {
    pl_node *n = pl_new(PL_STRING);
    if (n) n->str = strdup(s ? s : "");
    return n;
}

void pl_free(pl_node *n) {
    if (!n) return;
    for (size_t i = 0; i < n->count; i++) pl_free(n->items[i]);
    free(n->items);
    free(n->key);
    free(n->str);
    free(n->data);
    free(n);
}

pl_node *pl_clone(const pl_node *n) {
    if (!n) return NULL;
    pl_node *c = pl_new(n->type);
    if (n->key) c->key = strdup(n->key);
    if (n->str) c->str = strdup(n->str);
    c->i = n->i;
    c->r = n->r;
    if (n->data_len) {
        c->data = malloc(n->data_len);
        memcpy(c->data, n->data, n->data_len);
        c->data_len = n->data_len;
    }
    for (size_t k = 0; k < n->count; k++) pl_push(c, pl_clone(n->items[k]));
    return c;
}

int pl_push(pl_node *arr, pl_node *val) {
    if (!val) return -1;
    pl_node **p = realloc(arr->items, (arr->count + 1) * sizeof *p);
    if (!p) return -1;
    arr->items = p;
    arr->items[arr->count++] = val;
    return 0;
}

pl_node *pl_get(const pl_node *dict, const char *key) {
    if (!dict || dict->type != PL_DICT) return NULL;
    for (size_t i = 0; i < dict->count; i++)
        if (dict->items[i]->key && !strcmp(dict->items[i]->key, key)) return dict->items[i];
    return NULL;
}

const char *pl_get_str(const pl_node *dict, const char *key) {
    pl_node *n = pl_get(dict, key);
    return n && n->type == PL_STRING ? n->str : NULL;
}

int pl_remove(pl_node *dict, const char *key) {
    for (size_t i = 0; i < dict->count; i++) {
        if (dict->items[i]->key && !strcmp(dict->items[i]->key, key)) {
            pl_free(dict->items[i]);
            memmove(dict->items + i, dict->items + i + 1, (dict->count - i - 1) * sizeof *dict->items);
            dict->count--;
            return 1;
        }
    }
    return 0;
}

int pl_set(pl_node *dict, const char *key, pl_node *val) {
    if (!val) return -1;
    free(val->key);
    val->key = strdup(key);
    for (size_t i = 0; i < dict->count; i++) {
        if (dict->items[i]->key && !strcmp(dict->items[i]->key, key)) {
            pl_free(dict->items[i]);
            dict->items[i] = val;
            return 0;
        }
    }
    return pl_push(dict, val);
}

typedef struct {
    const char *p;
    const char *end;
} xr;

static void xr_ws(xr *x) {
    for (;;) {
        while (x->p < x->end && isspace((unsigned char)*x->p)) x->p++;
        if (x->end - x->p >= 4 && !memcmp(x->p, "<!--", 4)) {
            const char *e = strstr(x->p, "-->");
            x->p = e ? e + 3 : x->end;
            continue;
        }
        if (x->end - x->p >= 2 && (!memcmp(x->p, "<?", 2) || !memcmp(x->p, "<!", 2))) {
            while (x->p < x->end && *x->p != '>') x->p++;
            if (x->p < x->end) x->p++;
            continue;
        }
        break;
    }
}

static int xr_tag(xr *x, char *name, size_t cap, int *closing, int *selfclose) {
    xr_ws(x);
    if (x->p >= x->end || *x->p != '<') return -1;
    x->p++;
    *closing = 0;
    *selfclose = 0;
    if (x->p < x->end && *x->p == '/') { *closing = 1; x->p++; }
    size_t k = 0;
    while (x->p < x->end && !isspace((unsigned char)*x->p) && *x->p != '>' && *x->p != '/') {
        if (k + 1 < cap) name[k++] = *x->p;
        x->p++;
    }
    name[k] = 0;
    while (x->p < x->end && *x->p != '>') {
        if (*x->p == '/') *selfclose = 1;
        x->p++;
    }
    if (x->p >= x->end) return -1;
    x->p++;
    return 0;
}

static char *xr_text(xr *x, const char *tag) {
    char close[64];
    snprintf(close, sizeof close, "</%s>", tag);
    const char *start = x->p;
    const char *e = NULL;
    size_t cl = strlen(close);
    for (const char *q = start; q + cl <= x->end; q++) {
        if (!memcmp(q, close, cl)) { e = q; break; }
    }
    if (!e) return NULL;
    char *out = malloc((size_t)(e - start) + 1);
    size_t k = 0;
    for (const char *q = start; q < e;) {
        if (*q == '&') {
            if (!strncmp(q, "&amp;", 5)) { out[k++] = '&'; q += 5; continue; }
            if (!strncmp(q, "&lt;", 4)) { out[k++] = '<'; q += 4; continue; }
            if (!strncmp(q, "&gt;", 4)) { out[k++] = '>'; q += 4; continue; }
            if (!strncmp(q, "&quot;", 6)) { out[k++] = '"'; q += 6; continue; }
            if (!strncmp(q, "&apos;", 6)) { out[k++] = '\''; q += 6; continue; }
            if (q[1] == '#') {
                char *ep;
                unsigned long cp = q[2] == 'x' ? strtoul(q + 3, &ep, 16) : strtoul(q + 2, &ep, 10);
                if (*ep == ';') {
                    if (cp < 0x80) out[k++] = (char)cp;
                    else if (cp < 0x800) { out[k++] = 0xC0 | (cp >> 6); out[k++] = 0x80 | (cp & 0x3F); }
                    else if (cp < 0x10000) { out[k++] = 0xE0 | (cp >> 12); out[k++] = 0x80 | ((cp >> 6) & 0x3F); out[k++] = 0x80 | (cp & 0x3F); }
                    else { out[k++] = 0xF0 | (cp >> 18); out[k++] = 0x80 | ((cp >> 12) & 0x3F); out[k++] = 0x80 | ((cp >> 6) & 0x3F); out[k++] = 0x80 | (cp & 0x3F); }
                    q = ep + 1;
                    continue;
                }
            }
        }
        out[k++] = *q++;
    }
    out[k] = 0;
    x->p = e + cl;
    return out;
}

static int b64v(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+' || c == '-') return 62;
    if (c == '/' || c == '_') return 63;
    return -1;
}

static uint8_t *b64dec(const char *s, size_t *outlen) {
    size_t n = strlen(s);
    uint8_t *o = malloc(n * 3 / 4 + 4);
    uint32_t acc = 0;
    int bits = 0;
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        int v = b64v((unsigned char)s[i]);
        if (v < 0) continue;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) { bits -= 8; o[k++] = (uint8_t)(acc >> bits); }
    }
    *outlen = k;
    return o;
}

static pl_node *xr_value(xr *x, const char *tag, int selfclose);

static pl_node *xr_container(xr *x, int dict) {
    pl_node *n = pl_new(dict ? PL_DICT : PL_ARRAY);
    char name[64];
    int closing, sc;
    char *key = NULL;
    for (;;) {
        if (xr_tag(x, name, sizeof name, &closing, &sc)) { free(key); pl_free(n); return NULL; }
        if (closing) break;
        if (dict && !strcmp(name, "key")) {
            free(key);
            key = sc ? strdup("") : xr_text(x, "key");
            if (!key) { pl_free(n); return NULL; }
            continue;
        }
        pl_node *v = xr_value(x, name, sc);
        if (!v) { free(key); pl_free(n); return NULL; }
        if (dict) {
            v->key = key ? key : strdup("");
            key = NULL;
        }
        pl_push(n, v);
    }
    free(key);
    return n;
}

static pl_node *xr_value(xr *x, const char *tag, int sc) {
    if (!strcmp(tag, "dict")) return sc ? pl_new(PL_DICT) : xr_container(x, 1);
    if (!strcmp(tag, "array")) return sc ? pl_new(PL_ARRAY) : xr_container(x, 0);
    if (!strcmp(tag, "true") || !strcmp(tag, "false")) {
        pl_node *n = pl_new(PL_BOOL);
        n->i = tag[0] == 't';
        if (!sc) { char *t = xr_text(x, tag); free(t); }
        return n;
    }
    char *t = sc ? strdup("") : xr_text(x, tag);
    if (!t) return NULL;
    pl_node *n = NULL;
    if (!strcmp(tag, "string")) { n = pl_new(PL_STRING); n->str = t; return n; }
    if (!strcmp(tag, "integer")) { n = pl_new(PL_INT); n->i = strtoll(t, NULL, 10); }
    else if (!strcmp(tag, "real")) { n = pl_new(PL_REAL); n->r = strtod(t, NULL); }
    else if (!strcmp(tag, "date")) { n = pl_new(PL_DATE); n->str = t; return n; }
    else if (!strcmp(tag, "data")) { n = pl_new(PL_DATA); n->data = b64dec(t, &n->data_len); }
    free(t);
    return n;
}

static pl_node *xml_parse(const uint8_t *p, size_t len) {
    xr x = { (const char *)p, (const char *)p + len };
    char name[64];
    int closing, sc;
    for (;;) {
        if (xr_tag(&x, name, sizeof name, &closing, &sc)) return NULL;
        if (!strcmp(name, "plist")) continue;
        return xr_value(&x, name, sc);
    }
}

typedef struct {
    const uint8_t *p;
    size_t n;
    int osz, rsz;
    uint64_t nobj, top, otab;
    int depth;
} bp;

static uint64_t bp_uint(const uint8_t *p, int sz) {
    uint64_t v = 0;
    for (int i = 0; i < sz; i++) v = (v << 8) | p[i];
    return v;
}

static pl_node *bp_obj(bp *b, uint64_t idx);

static int bp_count(bp *b, const uint8_t **cur, uint8_t marker, uint64_t *count) {
    uint8_t lo = marker & 0x0f;
    if (lo != 0x0f) { *count = lo; return 0; }
    const uint8_t *q = *cur;
    if (q >= b->p + b->n) return -1;
    if ((q[0] & 0xf0) != 0x10) return -1;
    int sz = 1 << (q[0] & 0x0f);
    if (q + 1 + sz > b->p + b->n) return -1;
    *count = bp_uint(q + 1, sz);
    *cur = q + 1 + sz;
    return 0;
}

static pl_node *bp_obj(bp *b, uint64_t idx) {
    if (idx >= b->nobj || b->depth > 64) return NULL;
    size_t ooff = b->otab + idx * b->osz;
    if (ooff + b->osz > b->n) return NULL;
    uint64_t off = bp_uint(b->p + ooff, b->osz);
    if (off >= b->n) return NULL;
    const uint8_t *q = b->p + off;
    const uint8_t *end = b->p + b->n;
    uint8_t m = *q++;
    uint8_t hi = m >> 4;
    pl_node *n = NULL;
    uint64_t cnt;
    switch (hi) {
    case 0x0:
        n = pl_new(PL_BOOL);
        n->i = m == 0x09;
        return n;
    case 0x1: {
        int sz = 1 << (m & 0xf);
        if (q + sz > end) return NULL;
        n = pl_new(PL_INT);
        n->i = (int64_t)bp_uint(q, sz);
        return n;
    }
    case 0x2: {
        int sz = 1 << (m & 0xf);
        if (q + sz > end) return NULL;
        n = pl_new(PL_REAL);
        uint64_t v = bp_uint(q, sz);
        if (sz == 4) { uint32_t w = (uint32_t)v; float f; memcpy(&f, &w, 4); n->r = f; }
        else { double d; memcpy(&d, &v, 8); n->r = d; }
        return n;
    }
    case 0x3: {
        if (q + 8 > end) return NULL;
        uint64_t v = bp_uint(q, 8);
        double d;
        memcpy(&d, &v, 8);
        n = pl_new(PL_DATE);
        n->str = malloc(32);
        snprintf(n->str, 32, "%.0f", d);
        return n;
    }
    case 0x4:
        if (bp_count(b, &q, m, &cnt) || q + cnt > end) return NULL;
        n = pl_new(PL_DATA);
        n->data = malloc(cnt ? cnt : 1);
        memcpy(n->data, q, cnt);
        n->data_len = cnt;
        return n;
    case 0x5:
        if (bp_count(b, &q, m, &cnt) || q + cnt > end) return NULL;
        n = pl_new(PL_STRING);
        n->str = malloc(cnt + 1);
        memcpy(n->str, q, cnt);
        n->str[cnt] = 0;
        return n;
    case 0x6: {
        if (bp_count(b, &q, m, &cnt) || q + cnt * 2 > end) return NULL;
        n = pl_new(PL_STRING);
        n->str = malloc(cnt * 4 + 1);
        size_t k = 0;
        for (uint64_t i = 0; i < cnt; i++) {
            uint32_t c = ((uint32_t)q[2 * i] << 8) | q[2 * i + 1];
            if (c >= 0xD800 && c < 0xDC00 && i + 1 < cnt) {
                uint32_t c2 = ((uint32_t)q[2 * i + 2] << 8) | q[2 * i + 3];
                c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                i++;
            }
            if (c < 0x80) n->str[k++] = (char)c;
            else if (c < 0x800) { n->str[k++] = 0xC0 | (c >> 6); n->str[k++] = 0x80 | (c & 0x3F); }
            else if (c < 0x10000) { n->str[k++] = 0xE0 | (c >> 12); n->str[k++] = 0x80 | ((c >> 6) & 0x3F); n->str[k++] = 0x80 | (c & 0x3F); }
            else { n->str[k++] = 0xF0 | (c >> 18); n->str[k++] = 0x80 | ((c >> 12) & 0x3F); n->str[k++] = 0x80 | ((c >> 6) & 0x3F); n->str[k++] = 0x80 | (c & 0x3F); }
        }
        n->str[k] = 0;
        return n;
    }
    case 0x8: {
        int sz = (m & 0xf) + 1;
        n = pl_new(PL_INT);
        n->i = (int64_t)bp_uint(q, sz);
        return n;
    }
    case 0xA:
    case 0xD: {
        if (bp_count(b, &q, m, &cnt)) return NULL;
        int dict = hi == 0xD;
        if (q + cnt * b->rsz * (dict ? 2 : 1) > end) return NULL;
        n = pl_new(dict ? PL_DICT : PL_ARRAY);
        b->depth++;
        for (uint64_t i = 0; i < cnt; i++) {
            pl_node *v;
            if (dict) {
                pl_node *k = bp_obj(b, bp_uint(q + i * b->rsz, b->rsz));
                v = bp_obj(b, bp_uint(q + (cnt + i) * b->rsz, b->rsz));
                if (!k || !v || k->type != PL_STRING) { pl_free(k); pl_free(v); pl_free(n); b->depth--; return NULL; }
                v->key = k->str;
                k->str = NULL;
                pl_free(k);
            } else {
                v = bp_obj(b, bp_uint(q + i * b->rsz, b->rsz));
                if (!v) { pl_free(n); b->depth--; return NULL; }
            }
            pl_push(n, v);
        }
        b->depth--;
        return n;
    }
    }
    return NULL;
}

static pl_node *bplist_parse(const uint8_t *p, size_t n) {
    if (n < 40) return NULL;
    const uint8_t *t = p + n - 32;
    bp b = { p, n, t[6], t[7], bp_uint(t + 8, 8), bp_uint(t + 16, 8), bp_uint(t + 24, 8), 0 };
    if (!b.osz || !b.rsz || b.otab >= n) return NULL;
    return bp_obj(&b, b.top);
}

pl_node *pl_parse(const uint8_t *p, size_t n) {
    if (n >= 8 && !memcmp(p, "bplist00", 8)) return bplist_parse(p, n);
    return xml_parse(p, n);
}

pl_node *pl_parse_file(const char *path) {
    sayo_buf b;
    if (sayo_read_file(path, &b)) return NULL;
    pl_node *n = pl_parse(b.data, b.len);
    sayo_buf_free(&b);
    if (!n) sayo_set_error("cannot parse plist %s", path);
    return n;
}

static void xesc(sayo_buf *o, const char *s) {
    for (; *s; s++) {
        if (*s == '&') sayo_buf_str(o, "&amp;");
        else if (*s == '<') sayo_buf_str(o, "&lt;");
        else if (*s == '>') sayo_buf_str(o, "&gt;");
        else sayo_buf_byte(o, (uint8_t)*s);
    }
}

static void tabs(sayo_buf *o, int d) {
    for (int i = 0; i < d; i++) sayo_buf_byte(o, '\t');
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void b64enc(sayo_buf *o, const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)p[i] << 16;
        if (i + 1 < n) v |= (uint32_t)p[i + 1] << 8;
        if (i + 2 < n) v |= p[i + 2];
        sayo_buf_byte(o, B64[(v >> 18) & 63]);
        sayo_buf_byte(o, B64[(v >> 12) & 63]);
        sayo_buf_byte(o, i + 1 < n ? B64[(v >> 6) & 63] : '=');
        sayo_buf_byte(o, i + 2 < n ? B64[v & 63] : '=');
    }
}

static void xw(const pl_node *n, sayo_buf *o, int d) {
    char t[64];
    tabs(o, d);
    switch (n->type) {
    case PL_DICT:
        if (!n->count) { sayo_buf_str(o, "<dict/>\n"); return; }
        sayo_buf_str(o, "<dict>\n");
        for (size_t i = 0; i < n->count; i++) {
            tabs(o, d + 1);
            sayo_buf_str(o, "<key>");
            xesc(o, n->items[i]->key ? n->items[i]->key : "");
            sayo_buf_str(o, "</key>\n");
            xw(n->items[i], o, d + 1);
        }
        tabs(o, d);
        sayo_buf_str(o, "</dict>\n");
        return;
    case PL_ARRAY:
        if (!n->count) { sayo_buf_str(o, "<array/>\n"); return; }
        sayo_buf_str(o, "<array>\n");
        for (size_t i = 0; i < n->count; i++) xw(n->items[i], o, d + 1);
        tabs(o, d);
        sayo_buf_str(o, "</array>\n");
        return;
    case PL_STRING:
        sayo_buf_str(o, "<string>");
        xesc(o, n->str ? n->str : "");
        sayo_buf_str(o, "</string>\n");
        return;
    case PL_INT:
        snprintf(t, sizeof t, "<integer>%lld</integer>\n", (long long)n->i);
        sayo_buf_str(o, t);
        return;
    case PL_REAL:
        snprintf(t, sizeof t, "<real>%.17g</real>\n", n->r);
        sayo_buf_str(o, t);
        return;
    case PL_BOOL:
        sayo_buf_str(o, n->i ? "<true/>\n" : "<false/>\n");
        return;
    case PL_DATE:
        sayo_buf_str(o, "<date>");
        xesc(o, n->str ? n->str : "");
        sayo_buf_str(o, "</date>\n");
        return;
    case PL_DATA:
        sayo_buf_str(o, "<data>\n");
        tabs(o, d);
        b64enc(o, n->data, n->data_len);
        sayo_buf_str(o, "\n");
        tabs(o, d);
        sayo_buf_str(o, "</data>\n");
        return;
    }
}

int pl_to_xml(const pl_node *n, sayo_buf *out) {
    sayo_buf_init(out);
    sayo_buf_str(out, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                      "<plist version=\"1.0\">\n");
    xw(n, out, 0);
    sayo_buf_str(out, "</plist>\n");
    return 0;
}

int pl_write_file(const pl_node *n, const char *path) {
    sayo_buf b;
    pl_to_xml(n, &b);
    int rc = sayo_write_file(path, b.data, b.len);
    sayo_buf_free(&b);
    return rc;
}

static int cmp_key(const void *a, const void *b) {
    const pl_node *x = *(pl_node *const *)a, *y = *(pl_node *const *)b;
    return strcmp(x->key ? x->key : "", y->key ? y->key : "");
}

static int ent_value(const pl_node *n, sayo_buf *out) {
    sayo_buf in;
    sayo_buf_init(&in);
    switch (n->type) {
    case PL_BOOL: {
        uint8_t v[3] = { 0x01, 0x01, n->i ? 0xff : 0x00 };
        return sayo_buf_append(out, v, 3);
    }
    case PL_STRING:
        return der_utf8(out, n->str ? n->str : "");
    case PL_INT:
        return der_int_u64(out, (uint64_t)n->i);
    case PL_ARRAY:
        for (size_t i = 0; i < n->count; i++)
            if (ent_value(n->items[i], &in)) { sayo_buf_free(&in); return -1; }
        return der_wrap(out, 0x30, &in);
    case PL_DICT: {
        pl_node **sorted = malloc((n->count ? n->count : 1) * sizeof *sorted);
        memcpy(sorted, n->items, n->count * sizeof *sorted);
        qsort(sorted, n->count, sizeof *sorted, cmp_key);
        for (size_t i = 0; i < n->count; i++) {
            sayo_buf kv;
            sayo_buf_init(&kv);
            der_utf8(&kv, sorted[i]->key ? sorted[i]->key : "");
            if (ent_value(sorted[i], &kv)) { sayo_buf_free(&kv); free(sorted); sayo_buf_free(&in); return -1; }
            der_wrap(&in, 0x30, &kv);
        }
        free(sorted);
        return der_wrap(out, 0xb0, &in);
    }
    case PL_DATA:
        return der_tlv(out, 0x04, n->data, n->data_len);
    default:
        return der_utf8(out, n->str ? n->str : "");
    }
}

int ent_to_der(const pl_node *dict, sayo_buf *out) {
    sayo_buf inner, ctx;
    sayo_buf_init(&inner);
    sayo_buf_init(&ctx);
    sayo_buf_init(out);
    der_int_u64(&inner, 1);
    if (ent_value(dict, &ctx)) { sayo_buf_free(&ctx); sayo_buf_free(&inner); return -1; }
    sayo_buf_append(&inner, ctx.data, ctx.len);
    sayo_buf_free(&ctx);
    return der_wrap(out, 0x70, &inner);
}
