/* PKCS#12 reader for the files Security.framework refuses.
 *
 * iOS's SecPKCS12Import answers errSecDecode (-26275) for .p12 files made by OpenSSL 3
 * with its defaults: PBES2 (PBKDF2 + AES-CBC) for the bags and an HMAC-SHA-256 MAC.
 * Most certificate sellers produce exactly those now. This reads them: it checks the MAC
 * (so a wrong password is reported as such), decrypts the bags and returns the
 * certificate and the RSA private key (PKCS#1) that belongs to it.
 *
 * Supported: MAC with SHA-1 or SHA-256; PBES2 with PBKDF2 (HMAC-SHA-1/SHA-256) and
 * AES-128/192/256-CBC; unencrypted bags. The legacy PKCS#12 PBE ciphers (3DES, RC2)
 * are not needed here because Security.framework reads those files itself.
 */
#include "internal.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    size_t out, block;
    void (*fn)(const void *, size_t, uint8_t *);
} p12_hash;

static void sha1_fn(const void *p, size_t n, uint8_t *o) { sayo_sha1(p, n, o); }
static void sha256_fn(const void *p, size_t n, uint8_t *o) { sayo_sha256(p, n, o); }
static const p12_hash H_SHA1 = { 20, 64, sha1_fn };
static const p12_hash H_SHA256 = { 32, 64, sha256_fn };

static const uint8_t OID_DATA[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01 };
static const uint8_t OID_ENCRYPTED_DATA[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x06 };
static const uint8_t OID_KEY_BAG[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x01 };
static const uint8_t OID_SHROUDED_KEY_BAG[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02 };
static const uint8_t OID_CERT_BAG[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03 };
static const uint8_t OID_X509_CERT[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x16, 0x01 };
static const uint8_t OID_LOCAL_KEY_ID[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x15 };
static const uint8_t OID_PBES2[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D };
static const uint8_t OID_PBKDF2[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C };
static const uint8_t OID_HMAC_SHA1[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x07 };
static const uint8_t OID_HMAC_SHA256[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09 };
static const uint8_t OID_AES128_CBC[] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x02 };
static const uint8_t OID_AES192_CBC[] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x16 };
static const uint8_t OID_AES256_CBC[] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A };
static const uint8_t OID_SHA1[] = { 0x2B, 0x0E, 0x03, 0x02, 0x1A };
static const uint8_t OID_SHA256[] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
static const uint8_t OID_RSA[] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };

#define OID_IS(it, oid) ((it).tag == 0x06 && (it).len == sizeof(oid) && !memcmp((it).val, oid, sizeof(oid)))

/* -2: wrong password. -1: malformed or unsupported (message set). */
#define BAD(...) do { sayo_set_error(__VA_ARGS__); rc = -1; goto out; } while (0)

static void hmac(const p12_hash *h, const uint8_t *key, size_t kl, const uint8_t *msg, size_t ml, uint8_t *out) {
    uint8_t k[64] = { 0 };
    if (kl > h->block) h->fn(key, kl, k);
    else memcpy(k, key, kl);
    uint8_t pad[64], inner[32];
    sayo_buf b;
    sayo_buf_init(&b);
    for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
    sayo_buf_append(&b, pad, 64);
    sayo_buf_append(&b, msg, ml);
    h->fn(b.data, b.len, inner);
    b.len = 0;
    for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5c;
    sayo_buf_append(&b, pad, 64);
    sayo_buf_append(&b, inner, h->out);
    h->fn(b.data, b.len, out);
    sayo_buf_free(&b);
}

static void pbkdf2(const p12_hash *h, const uint8_t *pw, size_t pl, const uint8_t *salt, size_t sl,
                   uint32_t iter, uint8_t *out, size_t ol) {
    uint8_t *s = malloc(sl + 4);
    memcpy(s, salt, sl);
    for (uint32_t blk = 1; ol; blk++) {
        s[sl] = (uint8_t)(blk >> 24); s[sl + 1] = (uint8_t)(blk >> 16);
        s[sl + 2] = (uint8_t)(blk >> 8); s[sl + 3] = (uint8_t)blk;
        uint8_t u[32], t[32];
        hmac(h, pw, pl, s, sl + 4, u);
        memcpy(t, u, h->out);
        for (uint32_t i = 1; i < iter; i++) {
            hmac(h, pw, pl, u, h->out, u);
            for (size_t k = 0; k < h->out; k++) t[k] ^= u[k];
        }
        size_t m = ol < h->out ? ol : h->out;
        memcpy(out, t, m);
        out += m;
        ol -= m;
    }
    free(s);
}

/* RFC 7292 appendix B.2; pw is the BMPString password including its two zero bytes. */
static void pkcs12_kdf(const p12_hash *h, uint8_t id, const uint8_t *pw, size_t pl, const uint8_t *salt, size_t sl,
                       uint32_t iter, uint8_t *out, size_t ol) {
    size_t v = h->block, u = h->out;
    size_t slen = sl ? v * ((sl + v - 1) / v) : 0, plen = pl ? v * ((pl + v - 1) / v) : 0;
    size_t ilen = slen + plen;
    uint8_t *I = malloc(ilen ? ilen : 1), D[64], A[32], B[64];
    for (size_t i = 0; i < slen; i++) I[i] = salt[i % sl];
    for (size_t i = 0; i < plen; i++) I[slen + i] = pw[i % pl];
    memset(D, id, v);
    sayo_buf b;
    sayo_buf_init(&b);
    while (ol) {
        b.len = 0;
        sayo_buf_append(&b, D, v);
        sayo_buf_append(&b, I, ilen);
        h->fn(b.data, b.len, A);
        for (uint32_t r = 1; r < iter; r++) h->fn(A, u, A);
        size_t m = ol < u ? ol : u;
        memcpy(out, A, m);
        out += m;
        ol -= m;
        if (!ol) break;
        for (size_t i = 0; i < v; i++) B[i] = A[i % u];
        for (size_t j = 0; j < ilen; j += v) {
            unsigned carry = 1;
            for (size_t k = v; k-- > 0;) {
                carry += I[j + k] + B[k];
                I[j + k] = (uint8_t)carry;
                carry >>= 8;
            }
        }
    }
    sayo_buf_free(&b);
    free(I);
}

static int next_tag(der_r *r, uint8_t tag, der_item *it) {
    return der_next(r, it) == 0 && it->tag == tag ? 0 : -1;
}

static uint32_t small_int(const der_item *it) {
    uint32_t v = 0;
    for (size_t i = 0; i < it->len && i < 4; i++) v = (v << 8) | it->val[i];
    return v;
}

/* OCTET STRING contents, joining the pieces of a constructed (BER) one. */
static int octets(const der_item *it, sayo_buf *out) {
    if (it->tag == 0x04 || it->tag == 0x80) return sayo_buf_append(out, it->val, it->len);
    if (it->tag != 0x24 && it->tag != 0xA0) return -1;
    der_r r = { it->val, it->len };
    der_item part;
    while (r.n) {
        if (der_next(&r, &part) || octets(&part, out)) return -1;
    }
    return 0;
}

static int utf8_to_bmp(const char *s, sayo_buf *out) {
    const uint8_t *p = (const uint8_t *)s;
    while (*p) {
        uint32_t c;
        if (*p < 0x80) c = *p++;
        else if ((*p & 0xE0) == 0xC0 && p[1]) { c = ((uint32_t)(p[0] & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
        else if ((*p & 0xF0) == 0xE0 && p[1] && p[2]) { c = ((uint32_t)(p[0] & 0x0F) << 12) | ((uint32_t)(p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
        else return -1; /* outside the BMP: not representable */
        sayo_buf_byte(out, (uint8_t)(c >> 8));
        sayo_buf_byte(out, (uint8_t)c);
    }
    sayo_buf_byte(out, 0);
    sayo_buf_byte(out, 0);
    return 0;
}

/* Decrypts with an AlgorithmIdentifier (PBES2 only). -2 means the password is wrong. */
static int pbe_decrypt(const der_item *alg, const uint8_t *ct, size_t ctl, const char *password, sayo_buf *out) {
    int rc = -1;
    der_r r = { alg->val, alg->len }, pr, kdf, kp, enc;
    der_item oid, params, kdf_alg, kdf_oid, kdf_params, salt, iter, x, enc_alg, enc_oid, iv;
    sayo_buf_init(out);
    if (next_tag(&r, 0x06, &oid)) BAD("bad p12 algorithm");
    if (!OID_IS(oid, OID_PBES2)) BAD("this .p12 uses an encryption this app cannot read");
    if (next_tag(&r, 0x30, &params)) BAD("bad PBES2 parameters");
    der_enter(&params, &pr);
    if (next_tag(&pr, 0x30, &kdf_alg) || next_tag(&pr, 0x30, &enc_alg)) BAD("bad PBES2 parameters");
    der_enter(&kdf_alg, &kdf);
    if (next_tag(&kdf, 0x06, &kdf_oid) || !OID_IS(kdf_oid, OID_PBKDF2) || next_tag(&kdf, 0x30, &kdf_params)) BAD("unsupported key derivation in .p12");
    der_enter(&kdf_params, &kp);
    if (next_tag(&kp, 0x04, &salt) || next_tag(&kp, 0x02, &iter)) BAD("bad PBKDF2 parameters");
    const p12_hash *prf = &H_SHA1;
    size_t keylen = 0;
    while (kp.n && der_next(&kp, &x) == 0) {
        if (x.tag == 0x02) keylen = small_int(&x);
        else if (x.tag == 0x30) {
            der_r a = { x.val, x.len };
            der_item po;
            if (next_tag(&a, 0x06, &po)) BAD("bad PBKDF2 PRF");
            if (OID_IS(po, OID_HMAC_SHA256)) prf = &H_SHA256;
            else if (!OID_IS(po, OID_HMAC_SHA1)) BAD("unsupported PBKDF2 PRF in .p12");
        }
    }
    der_enter(&enc_alg, &enc);
    if (next_tag(&enc, 0x06, &enc_oid) || next_tag(&enc, 0x04, &iv) || iv.len != 16) BAD("bad cipher parameters");
    size_t need = OID_IS(enc_oid, OID_AES128_CBC) ? 16 : OID_IS(enc_oid, OID_AES192_CBC) ? 24 : OID_IS(enc_oid, OID_AES256_CBC) ? 32 : 0;
    if (!need) BAD("unsupported cipher in .p12");
    if (keylen && keylen != need) BAD("bad key length in .p12");
    uint8_t key[32];
    pbkdf2(prf, (const uint8_t *)password, strlen(password), salt.val, salt.len, small_int(&iter), key, need);
    if (sayo_aes_cbc_decrypt(key, need, iv.val, ct, ctl, out)) { sayo_buf_free(out); return -2; }
    rc = 0;
out:
    return rc;
}

typedef struct {
    sayo_buf key;        /* PKCS#1 RSAPrivateKey */
    sayo_buf key_id;
    sayo_buf certs[16];
    sayo_buf cert_ids[16];
    int ncerts;
} p12_out;

static void local_key_id(der_r *rest, sayo_buf *id) {
    der_item set, attr, aoid, vals, v;
    if (der_next(rest, &set) || set.tag != 0x31) return;
    der_r s = { set.val, set.len };
    while (s.n && der_next(&s, &attr) == 0) {
        der_r a = { attr.val, attr.len };
        if (next_tag(&a, 0x06, &aoid) || !OID_IS(aoid, OID_LOCAL_KEY_ID) || next_tag(&a, 0x31, &vals)) continue;
        der_r vr = { vals.val, vals.len };
        if (next_tag(&vr, 0x04, &v) == 0) { id->len = 0; sayo_buf_append(id, v.val, v.len); }
    }
}

static int take_pkcs8(const uint8_t *p, size_t n, p12_out *o) {
    der_r r = { p, n }, s, alg;
    der_item seq, ver, algid, oid, pk;
    if (next_tag(&r, 0x30, &seq)) return -1;
    der_enter(&seq, &s);
    if (next_tag(&s, 0x02, &ver) || next_tag(&s, 0x30, &algid) || next_tag(&s, 0x04, &pk)) return -1;
    der_enter(&algid, &alg);
    if (next_tag(&alg, 0x06, &oid)) return -1;
    if (!OID_IS(oid, OID_RSA)) { sayo_set_error("the .p12 key is not an RSA key"); return -3; }
    o->key.len = 0;
    return sayo_buf_append(&o->key, pk.val, pk.len);
}

static int read_bags(const uint8_t *p, size_t n, const char *password, p12_out *o) {
    der_r r = { p, n }, bags, bag;
    der_item seq, b, oid, val, inner;
    if (next_tag(&r, 0x30, &seq)) { sayo_set_error("bad p12 bags"); return -1; }
    der_enter(&seq, &bags);
    while (bags.n) {
        if (next_tag(&bags, 0x30, &b)) { sayo_set_error("bad p12 bag"); return -1; }
        der_enter(&b, &bag);
        if (next_tag(&bag, 0x06, &oid) || next_tag(&bag, 0xA0, &val)) { sayo_set_error("bad p12 bag"); return -1; }
        der_r vr = { val.val, val.len };
        if (der_next(&vr, &inner)) { sayo_set_error("bad p12 bag"); return -1; }
        if (OID_IS(oid, OID_KEY_BAG) || OID_IS(oid, OID_SHROUDED_KEY_BAG)) {
            int rc;
            if (OID_IS(oid, OID_KEY_BAG)) {
                rc = take_pkcs8(inner.raw, inner.raw_len, o);
            } else {
                der_r e = { inner.val, inner.len };
                der_item alg, data;
                if (next_tag(&e, 0x30, &alg) || next_tag(&e, 0x04, &data)) { sayo_set_error("bad p12 key bag"); return -1; }
                sayo_buf plain;
                rc = pbe_decrypt(&alg, data.val, data.len, password, &plain);
                if (rc) return rc;
                rc = take_pkcs8(plain.data, plain.len, o);
                sayo_buf_free(&plain);
            }
            if (rc == -3) return -1;
            if (rc) { sayo_set_error("cannot read the .p12 private key"); return -2; }
            local_key_id(&bag, &o->key_id);
        } else if (OID_IS(oid, OID_CERT_BAG) && o->ncerts < 16) {
            der_r c = { inner.val, inner.len };
            der_item ctype, cval, cder;
            if (next_tag(&c, 0x06, &ctype) || !OID_IS(ctype, OID_X509_CERT) || next_tag(&c, 0xA0, &cval)) continue;
            der_r cr = { cval.val, cval.len };
            if (der_next(&cr, &cder)) continue;
            sayo_buf_init(&o->certs[o->ncerts]);
            sayo_buf_init(&o->cert_ids[o->ncerts]);
            if (octets(&cder, &o->certs[o->ncerts])) continue;
            local_key_id(&bag, &o->cert_ids[o->ncerts]);
            o->ncerts++;
        }
    }
    return 0;
}

int sayo_p12_parse(const uint8_t *p12, size_t n, const char *password, sayo_buf *cert_der, sayo_buf *rsa_key) {
    int rc = -1;
    p12_out o;
    memset(&o, 0, sizeof o);
    sayo_buf_init(&o.key);
    sayo_buf_init(&o.key_id);
    sayo_buf auth, bmp, mac_bmp_alt;
    sayo_buf_init(&auth);
    sayo_buf_init(&bmp);
    sayo_buf_init(&mac_bmp_alt);
    sayo_buf_init(cert_der);
    sayo_buf_init(rsa_key);
    if (!password) password = "";

    der_r r = { p12, n }, pfx, ci, safe;
    der_item top, ver, auth_ci, ctype, content, inner, mac;
    if (next_tag(&r, 0x30, &top)) BAD("this is not a .p12 file");
    der_enter(&top, &pfx);
    if (next_tag(&pfx, 0x02, &ver) || next_tag(&pfx, 0x30, &auth_ci)) BAD("this is not a .p12 file");
    der_enter(&auth_ci, &ci);
    if (next_tag(&ci, 0x06, &ctype) || !OID_IS(ctype, OID_DATA) || next_tag(&ci, 0xA0, &content)) BAD("unsupported .p12 layout");
    der_r cr = { content.val, content.len };
    if (der_next(&cr, &inner) || octets(&inner, &auth)) BAD("unsupported .p12 layout");

    if (utf8_to_bmp(password, &bmp)) BAD("the password has characters a .p12 cannot hold");
    if (pfx.n && next_tag(&pfx, 0x30, &mac) == 0) {
        der_r m = { mac.val, mac.len }, di, dalg;
        der_item digest_info, alg, hoid, digest, salt, iter;
        if (next_tag(&m, 0x30, &digest_info) || next_tag(&m, 0x04, &salt)) BAD("bad .p12 MAC");
        uint32_t iterations = 1;
        if (m.n && next_tag(&m, 0x02, &iter) == 0) iterations = small_int(&iter);
        der_enter(&digest_info, &di);
        if (next_tag(&di, 0x30, &alg) || next_tag(&di, 0x04, &digest)) BAD("bad .p12 MAC");
        der_enter(&alg, &dalg);
        if (next_tag(&dalg, 0x06, &hoid)) BAD("bad .p12 MAC");
        const p12_hash *h = OID_IS(hoid, OID_SHA256) ? &H_SHA256 : OID_IS(hoid, OID_SHA1) ? &H_SHA1 : NULL;
        if (!h) BAD("unsupported .p12 MAC");
        if (digest.len != h->out) BAD("bad .p12 MAC");
        uint8_t key[32], out_mac[32];
        int ok = 0;
        /* OpenSSL also accepts an empty password written as no bytes at all. */
        for (int attempt = 0; attempt < 2 && !ok; attempt++) {
            const sayo_buf *pw = attempt == 0 ? &bmp : &mac_bmp_alt;
            if (attempt == 1 && password[0]) break;
            pkcs12_kdf(h, 3, pw->data, pw->len, salt.val, salt.len, iterations, key, h->out);
            hmac(h, key, h->out, auth.data, auth.len, out_mac);
            ok = !memcmp(out_mac, digest.val, h->out);
        }
        if (!ok) { sayo_set_error("wrong .p12 password"); rc = -2; goto out; }
    }

    der_r ar = { auth.data, auth.len };
    der_item aseq, item;
    if (next_tag(&ar, 0x30, &aseq)) BAD("unsupported .p12 layout");
    der_enter(&aseq, &safe);
    while (safe.n) {
        der_r one;
        der_item oid, wrapped, body;
        if (next_tag(&safe, 0x30, &item)) BAD("unsupported .p12 layout");
        der_enter(&item, &one);
        if (next_tag(&one, 0x06, &oid) || next_tag(&one, 0xA0, &wrapped)) BAD("unsupported .p12 layout");
        der_r wr = { wrapped.val, wrapped.len };
        if (der_next(&wr, &body)) BAD("unsupported .p12 layout");
        int brc;
        if (OID_IS(oid, OID_DATA)) {
            sayo_buf bags;
            sayo_buf_init(&bags);
            if (octets(&body, &bags)) { sayo_buf_free(&bags); BAD("unsupported .p12 layout"); }
            brc = read_bags(bags.data, bags.len, password, &o);
            sayo_buf_free(&bags);
        } else if (OID_IS(oid, OID_ENCRYPTED_DATA)) {
            der_r ed, eci;
            der_item ever, einfo, etype, ealg, edata;
            der_enter(&body, &ed);
            if (next_tag(&ed, 0x02, &ever) || next_tag(&ed, 0x30, &einfo)) BAD("unsupported .p12 layout");
            der_enter(&einfo, &eci);
            if (next_tag(&eci, 0x06, &etype) || next_tag(&eci, 0x30, &ealg) || der_next(&eci, &edata)) BAD("unsupported .p12 layout");
            sayo_buf ct, plain;
            sayo_buf_init(&ct);
            if (octets(&edata, &ct)) { sayo_buf_free(&ct); BAD("unsupported .p12 layout"); }
            brc = pbe_decrypt(&ealg, ct.data, ct.len, password, &plain);
            sayo_buf_free(&ct);
            if (brc == 0) {
                brc = read_bags(plain.data, plain.len, password, &o);
                sayo_buf_free(&plain);
            }
        } else {
            continue;
        }
        if (brc == -2) { sayo_set_error("wrong .p12 password"); rc = -2; goto out; }
        if (brc) { rc = -1; goto out; }
    }
    if (!o.key.len) BAD("the .p12 has no private key");
    if (!o.ncerts) BAD("the .p12 has no certificate");
    int pick = 0;
    for (int i = 0; i < o.ncerts; i++) {
        if (o.key_id.len && o.cert_ids[i].len == o.key_id.len && !memcmp(o.cert_ids[i].data, o.key_id.data, o.key_id.len)) { pick = i; break; }
    }
    sayo_buf_append(cert_der, o.certs[pick].data, o.certs[pick].len);
    sayo_buf_append(rsa_key, o.key.data, o.key.len);
    rc = 0;
out:
    for (int i = 0; i < o.ncerts; i++) { sayo_buf_free(&o.certs[i]); sayo_buf_free(&o.cert_ids[i]); }
    if (o.key.data) memset(o.key.data, 0, o.key.len);
    sayo_buf_free(&o.key);
    sayo_buf_free(&o.key_id);
    sayo_buf_free(&auth);
    sayo_buf_free(&bmp);
    sayo_buf_free(&mac_bmp_alt);
    if (rc) { sayo_buf_free(cert_der); sayo_buf_free(rsa_key); }
    return rc;
}
