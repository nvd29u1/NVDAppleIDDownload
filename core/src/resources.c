#include "internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static pl_node *rule(bool omit, bool optional, double weight) {
    pl_node *d = pl_new(PL_DICT);
    if (omit) { pl_node *b = pl_new(PL_BOOL); b->i = 1; pl_set(d, "omit", b); }
    if (optional) { pl_node *b = pl_new(PL_BOOL); b->i = 1; pl_set(d, "optional", b); }
    pl_node *w = pl_new(PL_REAL);
    w->r = weight;
    pl_set(d, "weight", w);
    return d;
}

static pl_node *ptrue(void) { pl_node *b = pl_new(PL_BOOL); b->i = 1; return b; }

static pl_node *data_node(const uint8_t *p, size_t n) {
    pl_node *d = pl_new(PL_DATA);
    d->data = malloc(n);
    memcpy(d->data, p, n);
    d->data_len = n;
    return d;
}

static bool has_lproj(const char *rel) {
    const char *p = rel;
    while ((p = strstr(p, ".lproj/"))) return true;
    return false;
}

static bool is_base_lproj(const char *rel) { return !strncmp(rel, "Base.lproj/", 11); }

static bool base_name_is(const char *rel, const char *name) {
    const char *s = strrchr(rel, '/');
    s = s ? s + 1 : rel;
    return !strcmp(s, name);
}

int code_resources(const char *bundle_dir, const char *main_exec_name,
                   const strlist *nested_rel, const uint8_t (*nested_cdhash)[20],
                   const char **nested_req, sayo_buf *xml) {
    (void)nested_rel;
    (void)nested_cdhash;
    (void)nested_req;
    strlist all = { 0 };
    if (list_tree(bundle_dir, "", &all, false)) return -1;
    sl_sort(&all);
    pl_node *files = pl_new(PL_DICT), *files2 = pl_new(PL_DICT);
    for (size_t i = 0; i < all.count; i++) {
        const char *rel = all.items[i];
        if (!strncmp(rel, "_CodeSignature/", 15)) continue;
        if (main_exec_name && !strcmp(rel, main_exec_name)) continue;
        if (base_name_is(rel, ".DS_Store")) continue;
        if (has_lproj(rel) && base_name_is(rel, "locversion.plist")) continue;
        char full[4096];
        path_join(full, sizeof full, bundle_dir, rel);
        struct stat st;
        if (lstat(full, &st)) continue;
        bool optional = has_lproj(rel) && !is_base_lproj(rel);
        if (S_ISLNK(st.st_mode)) {
            char target[4096];
            ssize_t n = readlink(full, target, sizeof target - 1);
            if (n < 0) continue;
            target[n] = 0;
            pl_node *e = pl_new(PL_DICT);
            pl_set(e, "symlink", pl_new_str(target));
            pl_set(files2, rel, e);
            continue;
        }
        sayo_buf b;
        if (sayo_read_file(full, &b)) { pl_free(files); pl_free(files2); sl_free(&all); return -1; }
        uint8_t h1[20], h2[32];
        sayo_sha1(b.data, b.len, h1);
        sayo_sha256(b.data, b.len, h2);
        sayo_buf_free(&b);
        if (optional) {
            pl_node *e = pl_new(PL_DICT);
            pl_set(e, "hash", data_node(h1, 20));
            pl_set(e, "optional", ptrue());
            pl_set(files, rel, e);
        } else {
            pl_set(files, rel, data_node(h1, 20));
        }
        if (!strcmp(rel, "Info.plist") || !strcmp(rel, "PkgInfo")) continue;
        pl_node *e2 = pl_new(PL_DICT);
        pl_set(e2, "hash", data_node(h1, 20));
        pl_set(e2, "hash2", data_node(h2, 32));
        if (optional) pl_set(e2, "optional", ptrue());
        pl_set(files2, rel, e2);
    }
    sl_free(&all);

    pl_node *rules = pl_new(PL_DICT);
    pl_set(rules, "^.*", ptrue());
    pl_set(rules, "^.*\\.lproj/", rule(false, true, 1000));
    pl_set(rules, "^.*\\.lproj/locversion.plist$", rule(true, false, 1100));
    pl_set(rules, "^Base\\.lproj/", rule(false, false, 1010));
    pl_set(rules, "^version.plist$", ptrue());

    pl_node *rules2 = pl_new(PL_DICT);
    pl_set(rules2, ".*\\.dSYM($|/)", rule(false, false, 11));
    pl_set(rules2, "^(.*/)?\\.DS_Store$", rule(true, false, 2000));
    pl_set(rules2, "^.*", ptrue());
    pl_set(rules2, "^.*\\.lproj/", rule(false, true, 1000));
    pl_set(rules2, "^.*\\.lproj/locversion.plist$", rule(true, false, 1100));
    pl_set(rules2, "^Base\\.lproj/", rule(false, false, 1010));
    pl_set(rules2, "^Info\\.plist$", rule(true, false, 20));
    pl_set(rules2, "^PkgInfo$", rule(true, false, 20));
    pl_set(rules2, "^embedded\\.provisionprofile$", rule(false, false, 20));
    pl_set(rules2, "^version\\.plist$", rule(false, false, 20));

    pl_node *root = pl_new(PL_DICT);
    pl_set(root, "files", files);
    pl_set(root, "files2", files2);
    pl_set(root, "rules", rules);
    pl_set(root, "rules2", rules2);
    pl_to_xml(root, xml);
    pl_free(root);
    return 0;
}
