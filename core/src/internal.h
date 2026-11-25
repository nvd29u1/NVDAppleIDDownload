#ifndef SAYO_INTERNAL_H
#define SAYO_INTERNAL_H

#include "sayo.h"
#include "compat.h"
#include <stdbool.h>

typedef enum {
    PL_DICT, PL_ARRAY, PL_STRING, PL_INT, PL_REAL, PL_BOOL, PL_DATA, PL_DATE
} pl_type;

typedef struct pl_node {
    pl_type type;
    char *key;
    char *str;
    int64_t i;
    double r;
    uint8_t *data;
    size_t data_len;
    struct pl_node **items;
    size_t count;
} pl_node;

pl_node *pl_parse(const uint8_t *p, size_t n);
pl_node *pl_parse_file(const char *path);
void pl_free(pl_node *n);
pl_node *pl_get(const pl_node *dict, const char *key);
const char *pl_get_str(const pl_node *dict, const char *key);
pl_node *pl_new(pl_type t);
pl_node *pl_new_str(const char *s);
int pl_set(pl_node *dict, const char *key, pl_node *val);
int pl_remove(pl_node *dict, const char *key);
int pl_push(pl_node *arr, pl_node *val);
int pl_to_xml(const pl_node *n, sayo_buf *out);
int pl_write_file(const pl_node *n, const char *path);
pl_node *pl_clone(const pl_node *n);

typedef struct {
    sayo_buf b;
} der_w;

int der_tlv(sayo_buf *out, uint8_t tag, const uint8_t *p, size_t n);
int der_len(sayo_buf *out, size_t n);
int der_wrap(sayo_buf *out, uint8_t tag, sayo_buf *inner);
int der_oid(sayo_buf *out, const char *dotted);
int der_int_u64(sayo_buf *out, uint64_t v);
int der_utf8(sayo_buf *out, const char *s);
int der_null(sayo_buf *out);
int der_utctime(sayo_buf *out, int64_t unix_time);

typedef struct {
    const uint8_t *p;
    size_t n;
} der_r;

typedef struct {
    uint8_t tag;
    const uint8_t *val;
    size_t len;
    const uint8_t *raw;
    size_t raw_len;
} der_item;

int der_next(der_r *r, der_item *it);
int der_enter(const der_item *it, der_r *r);

int ent_to_der(const pl_node *dict, sayo_buf *out);

int path_join(char *out, size_t cap, const char *a, const char *b);
int mkdirs(const char *path);
int rmtree(const char *path);
int copy_file(const char *src, const char *dst);
int copy_tree(const char *src, const char *dst);
bool is_dir(const char *path);
bool is_file(const char *path);

typedef struct {
    char **items;
    size_t count;
    size_t cap;
} strlist;

void sl_push(strlist *l, const char *s);
void sl_free(strlist *l);
void sl_sort(strlist *l);
int list_tree(const char *root, const char *rel, strlist *out, bool include_dirs);

bool macho_is(const uint8_t *p, size_t n);
int macho_sign(const char *path, const char *ident, const char *team_id,
               const uint8_t *ent_xml, size_t ent_xml_len,
               const uint8_t *ent_der, size_t ent_der_len,
               const uint8_t info_hash[32], bool has_info,
               const uint8_t res_hash[32], bool has_res,
               bool main_exec, bool get_task_allow,
               const sayo_identity *id, uint8_t cdhash_out[20]);
int macho_add_dylib(const char *path, const char *dylib_path, bool weak);
int macho_change_dylib(const char *path, const char *from, const char *to);
int macho_list_dylibs(const char *path, strlist *out);
int macho_add_rpath(const char *path, const char *rpath);

int cms_sign(const sayo_identity *id, const uint8_t *cd, size_t cd_len,
             const uint8_t cd_hash256[32], sayo_buf *out);

int code_resources(const char *bundle_dir, const char *main_exec_name,
                   const strlist *nested_rel, const uint8_t (*nested_cdhash)[20],
                   const char **nested_req, sayo_buf *xml);

int tar_extract(const uint8_t *p, size_t n, const char *dest);
int decompress_any(const uint8_t *p, size_t n, sayo_buf *out);

#endif
