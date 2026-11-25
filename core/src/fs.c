#include "internal.h"
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int path_join(char *out, size_t cap, const char *a, const char *b) {
    size_t la = strlen(a);
    int n;
    if (!b || !*b) n = snprintf(out, cap, "%s", a);
    else if (la && a[la - 1] == '/') n = snprintf(out, cap, "%s%s", a, b);
    else n = snprintf(out, cap, "%s/%s", a, b);
    if (n < 0 || (size_t)n >= cap) { sayo_set_error("path too long"); return -1; }
    return 0;
}

bool is_dir(const char *path) {
    struct stat st;
    return lstat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

bool is_file(const char *path) {
    struct stat st;
    return lstat(path, &st) == 0 && S_ISREG(st.st_mode);
}

int mkdirs(const char *path) {
    char tmp[4096];
    if (snprintf(tmp, sizeof tmp, "%s", path) >= (int)sizeof tmp) return -1;
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(tmp, 0755) && errno != EEXIST) { sayo_set_error("mkdir %s failed", tmp); return -1; }
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) && errno != EEXIST) { sayo_set_error("mkdir %s failed", tmp); return -1; }
    return 0;
}

int rmtree(const char *path) {
    struct stat st;
    if (lstat(path, &st)) return 0;
    if (!S_ISDIR(st.st_mode)) return unlink(path);
    DIR *d = opendir(path);
    if (!d) return -1;
    struct dirent *e;
    char sub[4096];
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (path_join(sub, sizeof sub, path, e->d_name)) { closedir(d); return -1; }
        rmtree(sub);
    }
    closedir(d);
    return rmdir(path);
}

int copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) { sayo_set_error("cannot open %s", src); return -1; }
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); sayo_set_error("cannot create %s", dst); return -1; }
    char buf[65536];
    size_t n;
    int rc = 0;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) { rc = -1; break; }
    }
    fclose(in);
    fclose(out);
    struct stat st;
    if (!stat(src, &st)) chmod(dst, st.st_mode & 0777);
    return rc;
}

int copy_tree(const char *src, const char *dst) {
    struct stat st;
    if (lstat(src, &st)) { sayo_set_error("missing %s", src); return -1; }
    if (S_ISLNK(st.st_mode)) {
        char target[4096];
        ssize_t n = readlink(src, target, sizeof target - 1);
        if (n < 0) return -1;
        target[n] = 0;
        unlink(dst);
        return symlink(target, dst);
    }
    if (!S_ISDIR(st.st_mode)) return copy_file(src, dst);
    if (mkdirs(dst)) return -1;
    DIR *d = opendir(src);
    if (!d) return -1;
    struct dirent *e;
    char a[4096], b[4096];
    int rc = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (path_join(a, sizeof a, src, e->d_name) || path_join(b, sizeof b, dst, e->d_name)) { rc = -1; break; }
        if (copy_tree(a, b)) { rc = -1; break; }
    }
    closedir(d);
    return rc;
}

void sl_push(strlist *l, const char *s) {
    if (l->count == l->cap) {
        size_t nc = l->cap ? l->cap * 2 : 32;
        char **p = realloc(l->items, nc * sizeof *p);
        if (!p) return;
        l->items = p;
        l->cap = nc;
    }
    l->items[l->count++] = strdup(s);
}

void sl_free(strlist *l) {
    for (size_t i = 0; i < l->count; i++) free(l->items[i]);
    free(l->items);
    l->items = NULL;
    l->count = l->cap = 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

void sl_sort(strlist *l) {
    if (l->count) qsort(l->items, l->count, sizeof *l->items, cmp_str);
}

int list_tree(const char *root, const char *rel, strlist *out, bool include_dirs) {
    char full[4096];
    if (path_join(full, sizeof full, root, rel)) return -1;
    DIR *d = opendir(full);
    if (!d) { sayo_set_error("cannot open dir %s", full); return -1; }
    struct dirent *e;
    char sub[4096], subfull[4096];
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (*rel) snprintf(sub, sizeof sub, "%s/%s", rel, e->d_name);
        else snprintf(sub, sizeof sub, "%s", e->d_name);
        path_join(subfull, sizeof subfull, root, sub);
        struct stat st;
        if (lstat(subfull, &st)) continue;
        if (S_ISDIR(st.st_mode)) {
            if (include_dirs) {
                char withslash[4100];
                snprintf(withslash, sizeof withslash, "%s/", sub);
                sl_push(out, withslash);
            }
            if (list_tree(root, sub, out, include_dirs)) { closedir(d); return -1; }
        } else {
            sl_push(out, sub);
        }
    }
    closedir(d);
    return 0;
}
