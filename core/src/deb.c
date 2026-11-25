#include "internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#ifdef __APPLE__
#include <compression.h>
#else
#include <lzma.h>
#include <zstd.h>
#endif

int sayo_zstd_decode(const uint8_t *p, size_t n, sayo_buf *out);

static int gunzip(const uint8_t *p, size_t n, sayo_buf *out) {
    z_stream zs;
    memset(&zs, 0, sizeof zs);
    if (inflateInit2(&zs, 15 + 32) != Z_OK) return -1;
    zs.next_in = (Bytef *)p;
    zs.avail_in = (uInt)n;
    int r;
    do {
        if (sayo_buf_reserve(out, 1 << 20)) { inflateEnd(&zs); return -1; }
        zs.next_out = out->data + out->len;
        zs.avail_out = (uInt)(out->cap - out->len);
        r = inflate(&zs, Z_NO_FLUSH);
        out->len = out->cap - zs.avail_out;
        if (r != Z_OK && r != Z_STREAM_END) { inflateEnd(&zs); sayo_set_error("gzip error"); return -1; }
    } while (r != Z_STREAM_END);
    inflateEnd(&zs);
    return 0;
}

#ifdef __APPLE__
static int unxz(const uint8_t *p, size_t n, sayo_buf *out) {
    compression_stream s;
    if (compression_stream_init(&s, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) != COMPRESSION_STATUS_OK) return -1;
    s.src_ptr = p;
    s.src_size = n;
    compression_status st;
    do {
        if (sayo_buf_reserve(out, 1 << 20)) { compression_stream_destroy(&s); return -1; }
        s.dst_ptr = out->data + out->len;
        s.dst_size = out->cap - out->len;
        size_t before = s.dst_size;
        st = compression_stream_process(&s, COMPRESSION_STREAM_FINALIZE);
        out->len += before - s.dst_size;
        if (st == COMPRESSION_STATUS_ERROR) { compression_stream_destroy(&s); sayo_set_error("xz error"); return -1; }
    } while (st == COMPRESSION_STATUS_OK);
    compression_stream_destroy(&s);
    return 0;
}
#else
static int unxz(const uint8_t *p, size_t n, sayo_buf *out) {
    lzma_stream s = LZMA_STREAM_INIT;
    if (lzma_auto_decoder(&s, UINT64_MAX, 0) != LZMA_OK) return -1;
    s.next_in = p;
    s.avail_in = n;
    lzma_ret r;
    do {
        if (sayo_buf_reserve(out, 1 << 20)) { lzma_end(&s); return -1; }
        s.next_out = out->data + out->len;
        s.avail_out = out->cap - out->len;
        size_t before = s.avail_out;
        r = lzma_code(&s, LZMA_FINISH);
        out->len += before - s.avail_out;
        if (r != LZMA_OK && r != LZMA_STREAM_END) { lzma_end(&s); sayo_set_error("xz error"); return -1; }
    } while (r != LZMA_STREAM_END);
    lzma_end(&s);
    return 0;
}
#endif

int decompress_any(const uint8_t *p, size_t n, sayo_buf *out) {
    sayo_buf_init(out);
    if (n >= 2 && p[0] == 0x1f && p[1] == 0x8b) return gunzip(p, n, out);
    if (n >= 6 && !memcmp(p, "\xfd" "7zXZ", 6)) return unxz(p, n, out);
    if (n >= 4 && p[0] == 0x28 && p[1] == 0xb5 && p[2] == 0x2f && p[3] == 0xfd) return sayo_zstd_decode(p, n, out);
    if (n >= 3 && p[0] == 0x5d && p[1] == 0x00 && p[2] == 0x00) return unxz(p, n, out);
    if (n >= 3 && !memcmp(p, "BZh", 3)) { sayo_set_error("bzip2 debs are not supported"); return -1; }
    return sayo_buf_append(out, p, n);
}

static uint64_t octal(const char *s, size_t n) {
    uint64_t v = 0;
    if ((uint8_t)s[0] & 0x80) {
        for (size_t i = 1; i < n; i++) v = (v << 8) | (uint8_t)s[i];
        return v;
    }
    for (size_t i = 0; i < n && s[i]; i++) {
        if (s[i] == ' ') continue;
        if (s[i] < '0' || s[i] > '7') break;
        v = v * 8 + (uint64_t)(s[i] - '0');
    }
    return v;
}

static int safe_rel(const char *n) {
    if (strstr(n, "../") || !strcmp(n, "..")) return 0;
    size_t l = strlen(n);
    if (l >= 3 && !strcmp(n + l - 3, "/..")) return 0;
    return 1;
}

int tar_extract(const uint8_t *p, size_t n, const char *dest) {
    size_t off = 0;
    char longname[4096] = "", longlink[4096] = "";
    while (off + 512 <= n) {
        const char *h = (const char *)p + off;
        int zero = 1;
        for (int i = 0; i < 512; i++) if (h[i]) { zero = 0; break; }
        if (zero) break;
        uint64_t size = octal(h + 124, 12);
        char type = h[156];
        char name[4096];
        if (*longname) {
            snprintf(name, sizeof name, "%s", longname);
            longname[0] = 0;
        } else if (!memcmp(h + 257, "ustar", 5) && h[345]) {
            snprintf(name, sizeof name, "%.155s/%.100s", h + 345, h);
        } else {
            snprintf(name, sizeof name, "%.100s", h);
        }
        char link[4096];
        if (*longlink) { snprintf(link, sizeof link, "%s", longlink); longlink[0] = 0; }
        else snprintf(link, sizeof link, "%.100s", h + 157);
        const uint8_t *data = p + off + 512;
        if (off + 512 + size > n) { sayo_set_error("truncated tar"); return -1; }
        off += 512 + ((size + 511) & ~(uint64_t)511);
        if (type == 'L') { snprintf(longname, sizeof longname, "%.*s", (int)size, data); continue; }
        if (type == 'K') { snprintf(longlink, sizeof longlink, "%.*s", (int)size, data); continue; }
        if (type == 'x') {
            const char *q = (const char *)data, *e = q + size;
            while (q < e) {
                char *sp;
                long rl = strtol(q, &sp, 10);
                if (rl <= 0 || q + rl > e) break;
                const char *kv = sp + 1;
                if (!strncmp(kv, "path=", 5)) snprintf(longname, sizeof longname, "%.*s", (int)(q + rl - kv - 6), kv + 5);
                if (!strncmp(kv, "linkpath=", 9)) snprintf(longlink, sizeof longlink, "%.*s", (int)(q + rl - kv - 10), kv + 9);
                q += rl;
            }
            continue;
        }
        if (type == 'g') continue;
        char *nm = name;
        while (nm[0] == '.' && nm[1] == '/') nm += 2;
        while (*nm == '/') nm++;
        if (!*nm || !safe_rel(nm)) continue;
        char full[4096];
        path_join(full, sizeof full, dest, nm);
        size_t fl = strlen(full);
        if (fl && full[fl - 1] == '/') full[fl - 1] = 0;
        char parent[4096];
        snprintf(parent, sizeof parent, "%s", full);
        char *slash = strrchr(parent, '/');
        if (slash) { *slash = 0; mkdirs(parent); }
        if (type == '5') { mkdirs(full); continue; }
        if (type == '2') { unlink(full); if (symlink(link, full)) {} continue; }
        if (type == '0' || type == '\0' || type == '7') {
            unlink(full);
            if (sayo_write_file(full, data, (size_t)size)) return -1;
            chmod(full, (mode_t)(octal(h + 100, 8) & 0777) | 0600);
        }
    }
    return 0;
}

int sayo_extract_deb(const char *deb_path, const char *dest) {
    sayo_buf b;
    if (sayo_read_file(deb_path, &b)) return -1;
    if (b.len < 8 || memcmp(b.data, "!<arch>\n", 8)) { sayo_buf_free(&b); sayo_set_error("not a .deb file"); return -1; }
    size_t off = 8;
    int found = 0, rc = 0;
    while (off + 60 <= b.len) {
        const char *h = (const char *)b.data + off;
        char name[17];
        memcpy(name, h, 16);
        name[16] = 0;
        for (int i = 15; i >= 0 && (name[i] == ' ' || name[i] == '/'); i--) name[i] = 0;
        size_t size = (size_t)strtoull(h + 48, NULL, 10);
        const uint8_t *data = b.data + off + 60;
        if (off + 60 + size > b.len) break;
        if (!strncmp(name, "data.tar", 8)) {
            sayo_buf tar;
            if (decompress_any(data, size, &tar)) { rc = -1; break; }
            mkdirs(dest);
            rc = tar_extract(tar.data, tar.len, dest);
            sayo_buf_free(&tar);
            found = 1;
            break;
        }
        off += 60 + size + (size & 1);
    }
    sayo_buf_free(&b);
    if (!found && rc == 0) { sayo_set_error("deb has no data archive"); return -1; }
    return rc;
}

static bool ends(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && !strcmp(s + a - b, suf);
}

int sayo_collect_tweak_dylibs(const char *root, char ***out_paths, size_t *out_count) {
    strlist all = { 0 }, res = { 0 };
    if (list_tree(root, "", &all, true)) return -1;
    sl_sort(&all);
    for (size_t i = 0; i < all.count; i++) {
        const char *r = all.items[i];
        char full[4096];
        path_join(full, sizeof full, root, r);
        size_t rl = strlen(r);
        if (rl && r[rl - 1] == '/') {
            char t[4096];
            snprintf(t, sizeof t, "%.*s", (int)(rl - 1), r);
            if (ends(t, ".framework") && strstr(t, "Library/Frameworks/") && !strstr(t, "CydiaSubstrate") && !strstr(t, ".framework/")) {
                char fp[4096];
                path_join(fp, sizeof fp, root, t);
                sl_push(&res, fp);
            }
            continue;
        }
        if (!ends(r, ".dylib")) continue;
        if (strstr(r, ".framework/")) continue;
        if (strstr(r, "MobileSubstrate/DynamicLibraries/") || strstr(r, "TweakInject/") || strstr(r, "usr/lib/") || !strchr(r, '/')) {
            if (strstr(r, "libsubstrate") || strstr(r, "libhooker") || strstr(r, "libsubstitute") || strstr(r, "libellekit")) continue;
            struct stat st;
            if (lstat(full, &st) || !S_ISREG(st.st_mode)) continue;
            sl_push(&res, full);
        }
    }
    sl_free(&all);
    *out_paths = res.items;
    *out_count = res.count;
    return 0;
}

void sayo_free_paths(char **paths, size_t count) {
    for (size_t i = 0; i < count; i++) free(paths[i]);
    free(paths);
}
