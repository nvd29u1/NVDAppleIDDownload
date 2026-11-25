#include "internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    der_item serial, issuer, validity, subject, spki, ext;
    bool has_ext;
} tbs_parts;

static int tbs_split(const uint8_t *cert, size_t len, tbs_parts *t) {
    memset(t, 0, sizeof *t);
    der_r r = { cert, len }, c, s;
    der_item it, tbs;
    if (der_next(&r, &it) || it.tag != 0x30) return -1;
    der_enter(&it, &c);
    if (der_next(&c, &tbs) || tbs.tag != 0x30) return -1;
    der_enter(&tbs, &s);
    if (der_next(&s, &it)) return -1;
    if (it.tag == 0xa0 && der_next(&s, &it)) return -1;
    t->serial = it;
    if (der_next(&s, &it)) return -1;
    if (der_next(&s, &t->issuer)) return -1;
    if (der_next(&s, &t->validity)) return -1;
    if (der_next(&s, &t->subject)) return -1;
    if (der_next(&s, &t->spki)) return -1;
    while (s.n) {
        if (der_next(&s, &it)) break;
        if (it.tag == 0xa3) { t->ext = it; t->has_ext = true; }
    }
    return 0;
}

static bool oid_eq(const der_item *it, const uint8_t *oid, size_t n) {
    return it->tag == 0x06 && it->len == n && !memcmp(it->val, oid, n);
}

static int64_t parse_time(const der_item *it) {
    char s[32];
    size_t n = it->len < 31 ? it->len : 31;
    memcpy(s, it->val, n);
    s[n] = 0;
    struct tm tm;
    memset(&tm, 0, sizeof tm);
    int y;
    const char *q = s;
    if (it->tag == 0x17) {
        y = (s[0] - '0') * 10 + (s[1] - '0');
        y += y < 50 ? 2000 : 1900;
        q = s + 2;
    } else {
        y = atoi((char[5]){ s[0], s[1], s[2], s[3], 0 });
        q = s + 4;
    }
    tm.tm_year = y - 1900;
    tm.tm_mon = (q[0] - '0') * 10 + (q[1] - '0') - 1;
    tm.tm_mday = (q[2] - '0') * 10 + (q[3] - '0');
    tm.tm_hour = (q[4] - '0') * 10 + (q[5] - '0');
    tm.tm_min = (q[6] - '0') * 10 + (q[7] - '0');
    tm.tm_sec = (q[8] - '0') * 10 + (q[9] - '0');
    return (int64_t)timegm(&tm);
}

static void name_attr(const der_item *name, const uint8_t *oid, size_t oidn, char *out, size_t cap) {
    out[0] = 0;
    der_r r, set, seq;
    der_item rdn, atv, o, v;
    der_enter(name, &r);
    while (r.n && !der_next(&r, &rdn)) {
        der_enter(&rdn, &set);
        while (set.n && !der_next(&set, &atv)) {
            der_enter(&atv, &seq);
            if (der_next(&seq, &o) || der_next(&seq, &v)) continue;
            if (oid_eq(&o, oid, oidn)) {
                size_t n = v.len < cap - 1 ? v.len : cap - 1;
                memcpy(out, v.val, n);
                out[n] = 0;
                return;
            }
        }
    }
}

static const uint8_t OID_CN[] = { 0x55, 0x04, 0x03 };
static const uint8_t OID_OU[] = { 0x55, 0x04, 0x0b };
static const uint8_t OID_O[] = { 0x55, 0x04, 0x0a };
static const uint8_t OID_AIA[] = { 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x01, 0x01 };
static const uint8_t OID_OCSP[] = { 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01 };


int sayo_cert_parse(const uint8_t *der, size_t len, sayo_cert_info *ci) {
    tbs_parts t;
    memset(ci, 0, sizeof *ci);
    if (tbs_split(der, len, &t)) { sayo_set_error("invalid certificate"); return -1; }
    name_attr(&t.subject, OID_CN, 3, ci->subject_cn, sizeof ci->subject_cn);
    name_attr(&t.subject, OID_OU, 3, ci->subject_ou, sizeof ci->subject_ou);
    name_attr(&t.subject, OID_O, 3, ci->subject_o, sizeof ci->subject_o);
    name_attr(&t.issuer, OID_CN, 3, ci->issuer_cn, sizeof ci->issuer_cn);
    name_attr(&t.issuer, OID_OU, 3, ci->issuer_ou, sizeof ci->issuer_ou);
    size_t k = 0;
    for (size_t i = 0; i < t.serial.len && k + 3 < sizeof ci->serial_hex; i++) {
        if (i == 0 && t.serial.val[0] == 0 && t.serial.len > 1) continue;
        k += (size_t)snprintf(ci->serial_hex + k, sizeof ci->serial_hex - k, "%02X", t.serial.val[i]);
    }
    der_r v;
    der_item a, b;
    der_enter(&t.validity, &v);
    if (!der_next(&v, &a) && !der_next(&v, &b)) {
        ci->not_before = parse_time(&a);
        ci->not_after = parse_time(&b);
    }
    return 0;
}

int sayo_cert_issued_by(const uint8_t *cert, size_t cl, const uint8_t *issuer, size_t il) {
    tbs_parts a, b;
    if (tbs_split(cert, cl, &a) || tbs_split(issuer, il, &b)) return 0;
    return a.issuer.raw_len == b.subject.raw_len && !memcmp(a.issuer.raw, b.subject.raw, a.issuer.raw_len);
}

static int ocsp_url(const tbs_parts *t, char *url, size_t cap) {
    if (!t->has_ext) return -1;
    der_r r, exts, e, aia, ad;
    der_item seq, ext, o, v, item, m, loc;
    der_enter(&t->ext, &r);
    if (der_next(&r, &seq)) return -1;
    der_enter(&seq, &exts);
    while (exts.n && !der_next(&exts, &ext)) {
        der_enter(&ext, &e);
        if (der_next(&e, &o)) continue;
        if (!oid_eq(&o, OID_AIA, sizeof OID_AIA)) continue;
        if (der_next(&e, &v)) continue;
        if (v.tag == 0x01 && der_next(&e, &v)) continue;
        der_r os = { v.val, v.len };
        der_item inner;
        if (der_next(&os, &inner)) continue;
        der_enter(&inner, &aia);
        while (aia.n && !der_next(&aia, &item)) {
            der_enter(&item, &ad);
            if (der_next(&ad, &m) || der_next(&ad, &loc)) continue;
            if (oid_eq(&m, OID_OCSP, sizeof OID_OCSP) && loc.tag == 0x86) {
                size_t n = loc.len < cap - 1 ? loc.len : cap - 1;
                memcpy(url, loc.val, n);
                url[n] = 0;
                return 0;
            }
        }
    }
    return -1;
}

int sayo_ocsp_request(const uint8_t *cert, size_t cl, const uint8_t *issuer, size_t il,
                      sayo_buf *req, char *url, size_t url_cap) {
    tbs_parts c, i;
    sayo_buf_init(req);
    if (tbs_split(cert, cl, &c) || tbs_split(issuer, il, &i)) { sayo_set_error("invalid certificate"); return -1; }
    if (ocsp_url(&c, url, url_cap)) snprintf(url, url_cap, "http://ocsp.apple.com/ocsp03-wwdrg3");
    uint8_t nh[20], kh[20];
    sayo_sha1(i.subject.raw, i.subject.raw_len, nh);
    der_r sp;
    der_item alg, bits;
    der_enter(&i.spki, &sp);
    if (der_next(&sp, &alg) || der_next(&sp, &bits) || bits.tag != 0x03 || bits.len < 1) { sayo_set_error("bad issuer key"); return -1; }
    sayo_sha1(bits.val + 1, bits.len - 1, kh);
    sayo_buf certid, a;
    sayo_buf_init(&certid);
    sayo_buf_init(&a);
    der_oid(&a, "1.3.14.3.2.26");
    der_null(&a);
    der_wrap(&certid, 0x30, &a);
    der_tlv(&certid, 0x04, nh, 20);
    der_tlv(&certid, 0x04, kh, 20);
    sayo_buf_append(&certid, c.serial.raw, c.serial.raw_len);
    sayo_buf one, list, tbs, outer;
    sayo_buf_init(&one);
    sayo_buf_init(&list);
    sayo_buf_init(&tbs);
    sayo_buf_init(&outer);
    der_wrap(&one, 0x30, &certid);
    der_wrap(&list, 0x30, &one);
    der_wrap(&tbs, 0x30, &list);
    der_wrap(&outer, 0x30, &tbs);
    return der_wrap(req, 0x30, &outer);
}

int sayo_ocsp_parse(const uint8_t *resp, size_t len, int *status, int64_t *revoked_at) {
    *status = 2;
    *revoked_at = 0;
    der_r r = { resp, len }, s;
    der_item it, st, rb;
    if (der_next(&r, &it) || it.tag != 0x30) { sayo_set_error("bad OCSP response"); return -1; }
    der_enter(&it, &s);
    if (der_next(&s, &st) || st.tag != 0x0a) { sayo_set_error("bad OCSP response"); return -1; }
    if (st.len != 1 || st.val[0] != 0) { sayo_set_error("OCSP responder error %d", st.len ? st.val[0] : -1); return -1; }
    if (der_next(&s, &rb) || rb.tag != 0xa0) { sayo_set_error("OCSP response has no body"); return -1; }
    der_r q;
    der_item seq, type, oct, basic, tbsd, x, responses, single;
    der_enter(&rb, &q);
    if (der_next(&q, &seq)) return -1;
    der_enter(&seq, &q);
    if (der_next(&q, &type) || der_next(&q, &oct) || oct.tag != 0x04) return -1;
    q.p = oct.val;
    q.n = oct.len;
    if (der_next(&q, &basic)) return -1;
    der_enter(&basic, &q);
    if (der_next(&q, &tbsd)) return -1;
    der_enter(&tbsd, &q);
    if (der_next(&q, &x)) return -1;
    if (x.tag == 0xa0 && der_next(&q, &x)) return -1;
    if (der_next(&q, &x)) return -1;
    if (der_next(&q, &responses)) return -1;
    der_enter(&responses, &q);
    if (der_next(&q, &single)) return -1;
    der_enter(&single, &q);
    if (der_next(&q, &x) || der_next(&q, &x)) return -1;
    if (x.tag == 0x80) *status = 0;
    else if (x.tag == 0xa1) {
        *status = 1;
        der_r rv;
        der_item t;
        der_enter(&x, &rv);
        if (!der_next(&rv, &t)) *revoked_at = parse_time(&t);
    } else *status = 2;
    return 0;
}

int sayo_csr_info(const uint8_t *pub, size_t pl, const char *cn, sayo_buf *tbs) {
    sayo_buf_init(tbs);
    sayo_buf in, name, rdn, set, spki, alg, bits;
    sayo_buf_init(&in);
    der_int_u64(&in, 0);
    sayo_buf_init(&name);
    sayo_buf_init(&rdn);
    sayo_buf_init(&set);
    der_oid(&rdn, "2.5.4.6");
    der_tlv(&rdn, 0x13, (const uint8_t *)"US", 2);
    der_wrap(&set, 0x30, &rdn);
    der_wrap(&name, 0x31, &set);
    sayo_buf_init(&rdn);
    sayo_buf_init(&set);
    der_oid(&rdn, "2.5.4.3");
    der_utf8(&rdn, cn);
    der_wrap(&set, 0x30, &rdn);
    der_wrap(&name, 0x31, &set);
    der_wrap(&in, 0x30, &name);
    sayo_buf_init(&spki);
    sayo_buf_init(&alg);
    der_oid(&alg, "1.2.840.113549.1.1.1");
    der_null(&alg);
    der_wrap(&spki, 0x30, &alg);
    sayo_buf_init(&bits);
    sayo_buf_byte(&bits, 0);
    sayo_buf_append(&bits, pub, pl);
    der_wrap(&spki, 0x03, &bits);
    der_wrap(&in, 0x30, &spki);
    uint8_t attrs[2] = { 0xa0, 0x00 };
    sayo_buf_append(&in, attrs, 2);
    return der_wrap(tbs, 0x30, &in);
}

int sayo_csr_finish(const uint8_t *tbs, size_t tl, const uint8_t *sig, size_t sl, sayo_buf *csr) {
    sayo_buf_init(csr);
    sayo_buf in, alg, bits;
    sayo_buf_init(&in);
    sayo_buf_append(&in, tbs, tl);
    sayo_buf_init(&alg);
    der_oid(&alg, "1.2.840.113549.1.1.11");
    der_null(&alg);
    der_wrap(&in, 0x30, &alg);
    sayo_buf_init(&bits);
    sayo_buf_byte(&bits, 0);
    sayo_buf_append(&bits, sig, sl);
    der_wrap(&in, 0x03, &bits);
    return der_wrap(csr, 0x30, &in);
}

extern const uint8_t *const SAYO_APPLE_CERTS[];
extern const size_t SAYO_APPLE_CERT_LENS[];

size_t sayo_apple_chain(const uint8_t *leaf, size_t leaf_len, const uint8_t **out, size_t *out_len, size_t cap) {
    size_t n = 0;
    const uint8_t *cur = leaf;
    size_t cl = leaf_len;
    while (n < cap) {
        int found = -1;
        for (int i = 0; SAYO_APPLE_CERTS[i]; i++) {
            if (SAYO_APPLE_CERTS[i] == cur) continue;
            if (sayo_cert_issued_by(cur, cl, SAYO_APPLE_CERTS[i], SAYO_APPLE_CERT_LENS[i])) { found = i; break; }
        }
        if (found < 0) break;
        out[n] = SAYO_APPLE_CERTS[found];
        out_len[n] = SAYO_APPLE_CERT_LENS[found];
        n++;
        if (sayo_cert_issued_by(SAYO_APPLE_CERTS[found], SAYO_APPLE_CERT_LENS[found], SAYO_APPLE_CERTS[found], SAYO_APPLE_CERT_LENS[found])) break;
        cur = SAYO_APPLE_CERTS[found];
        cl = SAYO_APPLE_CERT_LENS[found];
    }
    return n;
}

static void name_cn(sayo_buf *out, const char *cn, const char *org) {
    sayo_buf name, rdn, set;
    sayo_buf_init(&name);
    if (org && *org) {
        sayo_buf_init(&rdn);
        sayo_buf_init(&set);
        der_oid(&rdn, "2.5.4.10");
        der_utf8(&rdn, org);
        der_wrap(&set, 0x30, &rdn);
        der_wrap(&name, 0x31, &set);
    }
    sayo_buf_init(&rdn);
    sayo_buf_init(&set);
    der_oid(&rdn, "2.5.4.3");
    der_utf8(&rdn, cn);
    der_wrap(&set, 0x30, &rdn);
    der_wrap(&name, 0x31, &set);
    der_wrap(out, 0x30, &name);
}

static void gentime(sayo_buf *out, int64_t t) {
    if (t < 2524608000LL) { der_utctime(out, t); return; }
    time_t tt = (time_t)t;
    struct tm tm;
    gmtime_r(&tt, &tm);
    char s[32];
    snprintf(s, sizeof s, "%04d%02d%02d%02d%02d%02dZ", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    der_tlv(out, 0x18, (const uint8_t *)s, strlen(s));
}

static void ext(sayo_buf *exts, const char *oid, bool critical, sayo_buf *value) {
    sayo_buf e;
    sayo_buf_init(&e);
    der_oid(&e, oid);
    if (critical) { uint8_t t[3] = { 0x01, 0x01, 0xff }; sayo_buf_append(&e, t, 3); }
    der_wrap(&e, 0x04, value);
    der_wrap(exts, 0x30, &e);
}

int sayo_x509_tbs(uint64_t serial, const char *issuer_cn, const char *subject_cn, const char *org,
                  int64_t not_before, int64_t not_after,
                  const uint8_t *pub, size_t pl, const uint8_t *issuer_pub, size_t ipl,
                  int is_ca, const char *dns, const char *ip, sayo_buf *tbs) {
    sayo_buf_init(tbs);
    sayo_buf in, v, alg, val, spki, bits, exts, x, wrap;
    sayo_buf_init(&in);
    sayo_buf_init(&v);
    der_int_u64(&v, 2);
    der_wrap(&in, 0xa0, &v);
    der_int_u64(&in, serial);
    sayo_buf_init(&alg);
    der_oid(&alg, "1.2.840.113549.1.1.11");
    der_null(&alg);
    der_wrap(&in, 0x30, &alg);
    name_cn(&in, issuer_cn, org);
    sayo_buf_init(&val);
    gentime(&val, not_before);
    gentime(&val, not_after);
    der_wrap(&in, 0x30, &val);
    name_cn(&in, subject_cn, org);
    sayo_buf_init(&spki);
    sayo_buf_init(&alg);
    der_oid(&alg, "1.2.840.113549.1.1.1");
    der_null(&alg);
    der_wrap(&spki, 0x30, &alg);
    sayo_buf_init(&bits);
    sayo_buf_byte(&bits, 0);
    sayo_buf_append(&bits, pub, pl);
    der_wrap(&spki, 0x03, &bits);
    der_wrap(&in, 0x30, &spki);

    sayo_buf_init(&exts);
    sayo_buf_init(&x);
    if (is_ca) {
        uint8_t t[3] = { 0x01, 0x01, 0xff };
        sayo_buf_append(&x, t, 3);
    }
    sayo_buf_init(&wrap);
    der_wrap(&wrap, 0x30, &x);
    ext(&exts, "2.5.29.19", true, &wrap);
    sayo_buf_init(&x);
    uint8_t ku_ca[2] = { 0x01, 0x06 }, ku_leaf[2] = { 0x05, 0xa0 };
    der_tlv(&x, 0x03, is_ca ? ku_ca : ku_leaf, 2);
    ext(&exts, "2.5.29.15", true, &x);
    uint8_t ski[20];
    sayo_sha1(pub, pl, ski);
    sayo_buf_init(&x);
    der_tlv(&x, 0x04, ski, 20);
    ext(&exts, "2.5.29.14", false, &x);
    if (issuer_pub && ipl) {
        uint8_t aki[20];
        sayo_sha1(issuer_pub, ipl, aki);
        sayo_buf_init(&x);
        sayo_buf_init(&wrap);
        der_tlv(&x, 0x80, aki, 20);
        der_wrap(&wrap, 0x30, &x);
        ext(&exts, "2.5.29.35", false, &wrap);
    }
    if (!is_ca) {
        sayo_buf_init(&x);
        sayo_buf_init(&wrap);
        der_oid(&x, "1.3.6.1.5.5.7.3.1");
        der_wrap(&wrap, 0x30, &x);
        ext(&exts, "2.5.29.37", false, &wrap);
        sayo_buf_init(&x);
        sayo_buf_init(&wrap);
        if (dns && *dns) {
            const char *p = dns;
            while (*p) {
                const char *c = strchr(p, ',');
                size_t n = c ? (size_t)(c - p) : strlen(p);
                der_tlv(&x, 0x82, (const uint8_t *)p, n);
                p += n;
                if (*p == ',') p++;
            }
        }
        if (ip && *ip) {
            unsigned a, b, c, d;
            if (sscanf(ip, "%u.%u.%u.%u", &a, &b, &c, &d) == 4) {
                uint8_t ipb[4] = { (uint8_t)a, (uint8_t)b, (uint8_t)c, (uint8_t)d };
                der_tlv(&x, 0x87, ipb, 4);
            }
        }
        der_wrap(&wrap, 0x30, &x);
        ext(&exts, "2.5.29.17", false, &wrap);
    }
    sayo_buf seq;
    sayo_buf_init(&seq);
    der_wrap(&seq, 0x30, &exts);
    der_wrap(&in, 0xa3, &seq);
    return der_wrap(tbs, 0x30, &in);
}

int sayo_x509_finish(const uint8_t *tbs, size_t tl, const uint8_t *sig, size_t sl, sayo_buf *cert) {
    return sayo_csr_finish(tbs, tl, sig, sl, cert);
}
