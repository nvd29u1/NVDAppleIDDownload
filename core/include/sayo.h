#ifndef SAYO_H
#define SAYO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} sayo_buf;

void sayo_buf_init(sayo_buf *b);
void sayo_buf_free(sayo_buf *b);
int sayo_buf_reserve(sayo_buf *b, size_t extra);
int sayo_buf_append(sayo_buf *b, const void *p, size_t n);
int sayo_buf_byte(sayo_buf *b, uint8_t v);
int sayo_buf_be32(sayo_buf *b, uint32_t v);
int sayo_buf_be64(sayo_buf *b, uint64_t v);
int sayo_buf_str(sayo_buf *b, const char *s);
int sayo_buf_fill(sayo_buf *b, uint8_t v, size_t n);
int sayo_read_file(const char *path, sayo_buf *out);
int sayo_write_file(const char *path, const void *p, size_t n);

void sayo_sha1(const void *p, size_t n, uint8_t out[20]);
void sayo_sha256(const void *p, size_t n, uint8_t out[32]);

typedef int (*sayo_rsa_sign_fn)(void *ctx, const uint8_t *msg, size_t msg_len, sayo_buf *sig);

typedef struct {
    const uint8_t *cert_der;
    size_t cert_len;
    const uint8_t **chain_der;
    const size_t *chain_len;
    size_t chain_count;
    sayo_rsa_sign_fn sign;
    void *sign_ctx;
} sayo_identity;

typedef struct {
    const char *bundle_id;
    const char *display_name;
    const char *version;
    const char *short_version;
    const char *icon_png_path;
    const char *entitlements_xml_path;
    const char **inject_paths;
    size_t inject_count;
    const char *hook_framework_path;
    int remove_plugins;
    int remove_watch;
    int remove_url_schemes;
    int file_sharing;
    int min_ios_override;
    const char *min_ios;
    int compression_level;
} sayo_sign_options;

typedef void (*sayo_progress_fn)(void *ctx, double fraction, const char *stage);

int sayo_unzip(const char *zip_path, const char *dest_dir, sayo_progress_fn progress, void *ctx);
int sayo_zip_dir(const char *src_dir, const char *zip_path, int level, sayo_progress_fn progress, void *ctx);

int sayo_sign_app(const char *app_dir,
                  const uint8_t *provision, size_t provision_len,
                  const sayo_identity *identity,
                  const sayo_sign_options *opts,
                  sayo_progress_fn progress, void *ctx);

int sayo_sign_ipa(const char *ipa_in, const char *ipa_out, const char *work_dir,
                  const uint8_t *provision, size_t provision_len,
                  const sayo_identity *identity,
                  const sayo_sign_options *opts,
                  sayo_progress_fn progress, void *ctx);

int sayo_extract_deb(const char *deb_path, const char *dest_dir);
int sayo_collect_tweak_dylibs(const char *root, char ***out_paths, size_t *out_count);
void sayo_free_paths(char **paths, size_t count);

int sayo_provision_entitlements_xml(const uint8_t *provision, size_t len, sayo_buf *xml);
int sayo_provision_plist_xml(const uint8_t *provision, size_t len, sayo_buf *xml);

int sayo_ocsp_request(const uint8_t *cert_der, size_t cert_len,
                      const uint8_t *issuer_der, size_t issuer_len,
                      sayo_buf *req, char *url, size_t url_cap);
int sayo_ocsp_parse(const uint8_t *resp, size_t len, int *status, int64_t *revoked_at);

int sayo_csr_info(const uint8_t *pubkey_pkcs1, size_t pub_len, const char *cn, sayo_buf *tbs);
int sayo_csr_finish(const uint8_t *tbs, size_t tbs_len, const uint8_t *sig, size_t sig_len, sayo_buf *csr);

typedef struct {
    char subject_cn[256];
    char subject_ou[128];
    char subject_o[256];
    char issuer_cn[256];
    char issuer_ou[128];
    char serial_hex[80];
    int64_t not_before;
    int64_t not_after;
} sayo_cert_info;

int sayo_cert_parse(const uint8_t *der, size_t len, sayo_cert_info *ci);
int sayo_cert_issued_by(const uint8_t *cert, size_t cl, const uint8_t *issuer, size_t il);
size_t sayo_apple_chain(const uint8_t *leaf, size_t leaf_len, const uint8_t **out, size_t *out_len, size_t cap);
int sayo_macho_inject(const char *binary, const char *load_path, int weak);
int sayo_zstd_decode(const uint8_t *p, size_t n, sayo_buf *out);

int sayo_x509_tbs(uint64_t serial, const char *issuer_cn, const char *subject_cn, const char *org,
                  int64_t not_before, int64_t not_after,
                  const uint8_t *pub, size_t pl, const uint8_t *issuer_pub, size_t ipl,
                  int is_ca, const char *dns, const char *ip, sayo_buf *tbs);
int sayo_x509_finish(const uint8_t *tbs, size_t tl, const uint8_t *sig, size_t sl, sayo_buf *cert);

typedef struct {
    uint8_t a[32];
    uint8_t A[256];
    uint8_t K[32];
    uint8_t M1[32];
    uint8_t M2[32];
} sayo_srp;

int sayo_srp_init(sayo_srp *s, const uint8_t random32[32]);
int sayo_srp_process(sayo_srp *s, const char *username, const uint8_t *pass_key, size_t pkl,
                     const uint8_t *salt, size_t sl, const uint8_t *B, size_t bl);
int sayo_aes_cbc_decrypt(const uint8_t *key, size_t keylen, const uint8_t iv[16], const uint8_t *in, size_t n, sayo_buf *out);
int sayo_aes_cbc_encrypt(const uint8_t *key, size_t keylen, const uint8_t iv[16], const uint8_t *in, size_t n, sayo_buf *out);
int sayo_aes_gcm_decrypt(const uint8_t *key, size_t keylen, const uint8_t *iv, size_t ivlen,
                         const uint8_t *aad, size_t aadlen, const uint8_t *in, size_t n,
                         const uint8_t tag[16], sayo_buf *out);
void sayo_hmac_sha256(const uint8_t *key, size_t kl, const uint8_t *msg, size_t ml, uint8_t out[32]);
void sayo_pbkdf2_sha256(const uint8_t *pw, size_t pl, const uint8_t *salt, size_t sl, uint32_t iter, uint8_t *out, size_t ol);

/* Reads a .p12 (PBES2/AES or unencrypted bags, SHA-1/SHA-256 MAC) into the certificate DER
 * and the RSA private key (PKCS#1 DER). Returns 0, -2 for a wrong password, -1 otherwise. */
int sayo_p12_parse(const uint8_t *p12, size_t n, const char *password, sayo_buf *cert_der, sayo_buf *rsa_key);

/* LiveContainer-style: turns an app's main executable (thin or fat) into a loadable dylib in
 * place (MH_EXECUTE -> MH_DYLIB, __PAGEZERO moved to 0xFFFFC000/0x4000). Call before signing. */
int sayo_macho_make_dylib(const char *path);

const char *sayo_last_error(void);
void sayo_set_error(const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif
