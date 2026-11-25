#include "internal.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int cert_issuer_serial(const uint8_t *cert, size_t len, der_item *issuer, der_item *serial) {
    der_r r = { cert, len }, c, t;
    der_item it, tbs;
    if (der_next(&r, &it) || it.tag != 0x30) return -1;
    der_enter(&it, &c);
    if (der_next(&c, &tbs) || tbs.tag != 0x30) return -1;
    der_enter(&tbs, &t);
    if (der_next(&t, &it)) return -1;
    if (it.tag == 0xa0 && der_next(&t, &it)) return -1;
    *serial = it;
    if (der_next(&t, &it)) return -1;
    if (der_next(&t, issuer)) return -1;
    return 0;
}

static int alg_sha256(sayo_buf *o) {
    sayo_buf a;
    sayo_buf_init(&a);
    der_oid(&a, "2.16.840.1.101.3.4.2.1");
    der_null(&a);
    return der_wrap(o, 0x30, &a);
}

static int attr(sayo_buf *set_items, const char *oid, sayo_buf *value_der) {
    sayo_buf a, s;
    sayo_buf_init(&a);
    sayo_buf_init(&s);
    der_oid(&a, oid);
    der_wrap(&s, 0x31, value_der);
    sayo_buf_append(&a, s.data, s.len);
    sayo_buf_free(&s);
    return der_wrap(set_items, 0x30, &a);
}

typedef struct {
    uint8_t *p;
    size_t n;
} span;

static int span_cmp(const void *a, const void *b) {
    const span *x = a, *y = b;
    size_t m = x->n < y->n ? x->n : y->n;
    int c = memcmp(x->p, y->p, m);
    if (c) return c;
    return x->n < y->n ? -1 : x->n > y->n;
}

static int sorted_set(const sayo_buf *items, sayo_buf *out) {
    span sp[16];
    size_t k = 0;
    der_r r = { items->data, items->len };
    der_item it;
    while (r.n && k < 16) {
        if (der_next(&r, &it)) return -1;
        sp[k].p = (uint8_t *)it.raw;
        sp[k].n = it.raw_len;
        k++;
    }
    qsort(sp, k, sizeof *sp, span_cmp);
    sayo_buf inner;
    sayo_buf_init(&inner);
    for (size_t i = 0; i < k; i++) sayo_buf_append(&inner, sp[i].p, sp[i].n);
    return der_wrap(out, 0x31, &inner);
}

int cms_sign(const sayo_identity *id, const uint8_t *cd, size_t cd_len,
             const uint8_t cd_hash256[32], sayo_buf *out) {
    (void)cd;
    (void)cd_len;
    sayo_buf_init(out);
    der_item issuer, serial;
    if (cert_issuer_serial(id->cert_der, id->cert_len, &issuer, &serial)) {
        sayo_set_error("cannot parse signing certificate");
        return -1;
    }
    sayo_buf items, v;
    sayo_buf_init(&items);

    sayo_buf_init(&v);
    der_oid(&v, "1.2.840.113549.1.7.1");
    attr(&items, "1.2.840.113549.1.9.3", &v);

    sayo_buf_init(&v);
    der_utctime(&v, (int64_t)time(NULL));
    attr(&items, "1.2.840.113549.1.9.5", &v);

    sayo_buf_init(&v);
    der_tlv(&v, 0x04, cd_hash256, 32);
    attr(&items, "1.2.840.113549.1.9.4", &v);

    sayo_buf pl;
    sayo_buf_init(&pl);
    pl_node *root = pl_new(PL_DICT);
    pl_node *arr = pl_new(PL_ARRAY);
    pl_node *h = pl_new(PL_DATA);
    h->data = malloc(20);
    memcpy(h->data, cd_hash256, 20);
    h->data_len = 20;
    pl_push(arr, h);
    pl_set(root, "cdhashes", arr);
    pl_to_xml(root, &pl);
    pl_free(root);
    sayo_buf_init(&v);
    der_tlv(&v, 0x04, pl.data, pl.len);
    sayo_buf_free(&pl);
    attr(&items, "1.2.840.113635.100.9.1", &v);

    sayo_buf_init(&v);
    sayo_buf seq;
    sayo_buf_init(&seq);
    der_oid(&seq, "2.16.840.1.101.3.4.2.1");
    der_tlv(&seq, 0x04, cd_hash256, 32);
    der_wrap(&v, 0x30, &seq);
    attr(&items, "1.2.840.113635.100.9.2", &v);

    sayo_buf signed_set;
    sayo_buf_init(&signed_set);
    if (sorted_set(&items, &signed_set)) { sayo_buf_free(&items); return -1; }
    sayo_buf_free(&items);

    sayo_buf sig;
    sayo_buf_init(&sig);
    if (id->sign(id->sign_ctx, signed_set.data, signed_set.len, &sig)) {
        if (!*sayo_last_error()) sayo_set_error("RSA signing failed");
        sayo_buf_free(&signed_set);
        return -1;
    }

    sayo_buf si, ias;
    sayo_buf_init(&si);
    sayo_buf_init(&ias);
    der_int_u64(&si, 1);
    sayo_buf_append(&ias, issuer.raw, issuer.raw_len);
    sayo_buf_append(&ias, serial.raw, serial.raw_len);
    der_wrap(&si, 0x30, &ias);
    alg_sha256(&si);
    signed_set.data[0] = 0xa0;
    sayo_buf_append(&si, signed_set.data, signed_set.len);
    sayo_buf_free(&signed_set);
    sayo_buf ra;
    sayo_buf_init(&ra);
    der_oid(&ra, "1.2.840.113549.1.1.1");
    der_null(&ra);
    der_wrap(&si, 0x30, &ra);
    der_tlv(&si, 0x04, sig.data, sig.len);
    sayo_buf_free(&sig);

    sayo_buf sd, tmp;
    sayo_buf_init(&sd);
    der_int_u64(&sd, 1);
    sayo_buf_init(&tmp);
    alg_sha256(&tmp);
    der_wrap(&sd, 0x31, &tmp);
    sayo_buf_init(&tmp);
    der_oid(&tmp, "1.2.840.113549.1.7.1");
    der_wrap(&sd, 0x30, &tmp);
    sayo_buf_init(&tmp);
    for (size_t i = 0; i < id->chain_count; i++) sayo_buf_append(&tmp, id->chain_der[i], id->chain_len[i]);
    sayo_buf_append(&tmp, id->cert_der, id->cert_len);
    der_wrap(&sd, 0xa0, &tmp);
    sayo_buf sis;
    sayo_buf_init(&sis);
    der_wrap(&sis, 0x30, &si);
    der_wrap(&sd, 0x31, &sis);

    sayo_buf ci, ex;
    sayo_buf_init(&ci);
    sayo_buf_init(&ex);
    der_oid(&ci, "1.2.840.113549.1.7.2");
    der_wrap(&ex, 0x30, &sd);
    der_wrap(&ci, 0xa0, &ex);
    return der_wrap(out, 0x30, &ci);
}
