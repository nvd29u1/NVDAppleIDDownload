#include "internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define CHUNK 262144

static uint16_t r16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t r32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t r64(const uint8_t *p) { return (uint64_t)r32(p) | ((uint64_t)r32(p + 4) << 32); }

static int safe_name(const char *n) {
    if (!*n || n[0] == '/') return 0;
    const char *p = n;
    while (*p) {
        const char *s = strchr(p, '/');
        size_t len = s ? (size_t)(s - p) : strlen(p);
        if (len == 2 && p[0] == '.' && p[1] == '.') return 0;
        if (!s) break;
        p = s + 1;
    }
    return 1;
}

static int parent_dirs(const char *path) {
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s", path);
    char *s = strrchr(tmp, '/');
    if (!s) return 0;
    *s = 0;
    return mkdirs(tmp);
}

int sayo_unzip(const char *zip_path, const char *dest_dir, sayo_progress_fn progress, void *ctx) {
    FILE *f = fopen(zip_path, "rb");
    if (!f) { sayo_set_error("cannot open %s", zip_path); return -1; }
    fseeko(f, 0, SEEK_END);
    off_t fsize = ftello(f);
    size_t tail = fsize < 65557 + 20 ? (size_t)fsize : 65557 + 20;
    uint8_t *t = malloc(tail);
    fseeko(f, fsize - (off_t)tail, SEEK_SET);
    if (fread(t, 1, tail, f) != tail) { free(t); fclose(f); sayo_set_error("read error"); return -1; }
    long eocd = -1;
    for (long i = (long)tail - 22; i >= 0; i--) {
        if (r32(t + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) { free(t); fclose(f); sayo_set_error("not a zip file"); return -1; }
    uint64_t entries = r16(t + eocd + 10);
    uint64_t cd_size = r32(t + eocd + 12);
    uint64_t cd_off = r32(t + eocd + 16);
    if (eocd >= 20 && r32(t + eocd - 20) == 0x07064b50) {
        uint64_t z64 = r64(t + eocd - 20 + 8);
        uint8_t z[56];
        fseeko(f, (off_t)z64, SEEK_SET);
        if (fread(z, 1, 56, f) == 56 && r32(z) == 0x06064b50) {
            entries = r64(z + 32);
            cd_size = r64(z + 40);
            cd_off = r64(z + 48);
        }
    }
    free(t);
    if (cd_off + cd_size > (uint64_t)fsize) { fclose(f); sayo_set_error("corrupt zip directory"); return -1; }
    uint8_t *cd = malloc(cd_size + 1);
    fseeko(f, (off_t)cd_off, SEEK_SET);
    if (fread(cd, 1, cd_size, f) != cd_size) { free(cd); fclose(f); sayo_set_error("read error"); return -1; }
    mkdirs(dest_dir);
    uint8_t *in = malloc(CHUNK), *out = malloc(CHUNK);
    size_t pos = 0;
    int rc = 0;
    for (uint64_t e = 0; e < entries && rc == 0; e++) {
        if (pos + 46 > cd_size || r32(cd + pos) != 0x02014b50) { rc = -1; sayo_set_error("corrupt zip entry"); break; }
        uint8_t *h = cd + pos;
        uint16_t method = r16(h + 10);
        uint64_t csize = r32(h + 20), usize = r32(h + 24);
        uint16_t nlen = r16(h + 28), xlen = r16(h + 30), clen = r16(h + 32);
        uint32_t ext = r32(h + 38);
        uint64_t loff = r32(h + 42);
        if (pos + 46 + nlen + xlen + clen > cd_size) { rc = -1; sayo_set_error("corrupt zip entry"); break; }
        char name[4096];
        size_t nl = nlen < sizeof name - 1 ? nlen : sizeof name - 1;
        memcpy(name, h + 46, nl);
        name[nl] = 0;
        uint8_t *x = h + 46 + nlen, *xe = x + xlen;
        while (x + 4 <= xe) {
            uint16_t id = r16(x), sz = r16(x + 2);
            if (id == 1) {
                uint8_t *q = x + 4;
                if (usize == 0xffffffff && q + 8 <= x + 4 + sz) { usize = r64(q); q += 8; }
                if (csize == 0xffffffff && q + 8 <= x + 4 + sz) { csize = r64(q); q += 8; }
                if (loff == 0xffffffff && q + 8 <= x + 4 + sz) { loff = r64(q); q += 8; }
            }
            x += 4 + sz;
        }
        pos += 46 + nlen + xlen + clen;
        if (progress && (e % 32 == 0)) progress(ctx, (double)e / (double)entries, "unzip");
        if (!strncmp(name, "__MACOSX/", 9)) continue;
        if (!safe_name(name)) continue;
        char full[4096];
        if (path_join(full, sizeof full, dest_dir, name)) { rc = -1; break; }
        if (nl && name[nl - 1] == '/') { mkdirs(full); continue; }
        uint8_t lh[30];
        fseeko(f, (off_t)loff, SEEK_SET);
        if (fread(lh, 1, 30, f) != 30 || r32(lh) != 0x04034b50) { rc = -1; sayo_set_error("bad local header for %s", name); break; }
        fseeko(f, (off_t)(loff + 30 + r16(lh + 26) + r16(lh + 28)), SEEK_SET);
        parent_dirs(full);
        uint32_t mode = ext >> 16;
        bool link = (mode & 0170000) == 0120000;
        sayo_buf linkbuf;
        sayo_buf_init(&linkbuf);
        FILE *o = NULL;
        if (!link) {
            unlink(full);
            o = fopen(full, "wb");
            if (!o) { rc = -1; sayo_set_error("cannot create %s", full); break; }
        }
        uint64_t left = csize;
        if (method == 0) {
            while (left) {
                size_t n = left < CHUNK ? (size_t)left : CHUNK;
                if (fread(in, 1, n, f) != n) { rc = -1; sayo_set_error("truncated zip"); break; }
                if (link) sayo_buf_append(&linkbuf, in, n);
                else if (fwrite(in, 1, n, o) != n) { rc = -1; sayo_set_error("write failed (disk full?)"); break; }
                left -= n;
            }
        } else if (method == 8) {
            z_stream zs;
            memset(&zs, 0, sizeof zs);
            inflateInit2(&zs, -MAX_WBITS);
            int zr = Z_OK;
            while (zr != Z_STREAM_END && rc == 0) {
                if (zs.avail_in == 0) {
                    if (!left) { rc = -1; sayo_set_error("truncated deflate stream in %s", name); break; }
                    size_t n = left < CHUNK ? (size_t)left : CHUNK;
                    if (fread(in, 1, n, f) != n) { rc = -1; sayo_set_error("truncated zip"); break; }
                    left -= n;
                    zs.next_in = in;
                    zs.avail_in = (uInt)n;
                }
                zs.next_out = out;
                zs.avail_out = CHUNK;
                zr = inflate(&zs, Z_NO_FLUSH);
                if (zr != Z_OK && zr != Z_STREAM_END && zr != Z_BUF_ERROR) { rc = -1; sayo_set_error("inflate error in %s", name); break; }
                size_t got = CHUNK - zs.avail_out;
                if (link) sayo_buf_append(&linkbuf, out, got);
                else if (got && fwrite(out, 1, got, o) != got) { rc = -1; sayo_set_error("write failed (disk full?)"); break; }
            }
            inflateEnd(&zs);
        } else {
            rc = -1;
            sayo_set_error("unsupported zip method %d", method);
        }
        (void)usize;
        if (o) fclose(o);
        if (link && rc == 0) {
            sayo_buf_byte(&linkbuf, 0);
            unlink(full);
            if (symlink((char *)linkbuf.data, full)) { rc = -1; sayo_set_error("symlink failed %s", full); }
        } else if (rc == 0 && mode) {
            chmod(full, (mode & 0777) | 0600);
        }
        sayo_buf_free(&linkbuf);
    }
    free(in);
    free(out);
    free(cd);
    fclose(f);
    if (progress && rc == 0) progress(ctx, 1.0, "unzip");
    return rc;
}

static void w16(sayo_buf *b, uint16_t v) { uint8_t t[2] = { v, v >> 8 }; sayo_buf_append(b, t, 2); }
static void w32(sayo_buf *b, uint32_t v) { uint8_t t[4] = { v, v >> 8, v >> 16, v >> 24 }; sayo_buf_append(b, t, 4); }
static void w64(sayo_buf *b, uint64_t v) { w32(b, (uint32_t)v); w32(b, (uint32_t)(v >> 32)); }

static void fw16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static void fw32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

int sayo_zip_dir(const char *src_dir, const char *zip_path, int level, sayo_progress_fn progress, void *ctx) {
    strlist files = { 0 };
    if (list_tree(src_dir, "", &files, true)) return -1;
    sl_sort(&files);
    FILE *o = fopen(zip_path, "wb");
    if (!o) { sl_free(&files); sayo_set_error("cannot create %s", zip_path); return -1; }
    sayo_buf cd;
    sayo_buf_init(&cd);
    uint8_t *in = malloc(CHUNK), *out = malloc(CHUNK);
    int rc = 0;
    uint64_t count = 0;
    for (size_t i = 0; i < files.count && rc == 0; i++) {
        const char *name = files.items[i];
        char full[4096];
        path_join(full, sizeof full, src_dir, name);
        struct stat st;
        if (lstat(full, &st)) continue;
        bool dir = S_ISDIR(st.st_mode);
        bool link = S_ISLNK(st.st_mode);
        if (progress && (i % 32 == 0)) progress(ctx, (double)i / (double)files.count, "zip");
        uint64_t loff = (uint64_t)ftello(o);
        size_t nlen = strlen(name);
        int method = (dir || link || level == 0) ? 0 : 8;
        uint8_t lh[30] = { 0 };
        fw32(lh, 0x04034b50);
        fw16(lh + 4, 45);
        fw16(lh + 6, 0x0800);
        fw16(lh + 8, (uint16_t)method);
        fw16(lh + 10, 0);
        fw16(lh + 12, 0x21);
        fw16(lh + 26, (uint16_t)nlen);
        fw16(lh + 28, 20);
        fwrite(lh, 1, 30, o);
        fwrite(name, 1, nlen, o);
        uint8_t z64x[20] = { 0 };
        fw16(z64x, 1);
        fw16(z64x + 2, 16);
        fwrite(z64x, 1, 20, o);
        uint32_t crc = (uint32_t)crc32(0, Z_NULL, 0);
        uint64_t usize = 0, csize = 0;
        if (link) {
            char target[4096];
            ssize_t n = readlink(full, target, sizeof target);
            if (n < 0) { rc = -1; break; }
            crc = (uint32_t)crc32(crc, (const Bytef *)target, (uInt)n);
            fwrite(target, 1, (size_t)n, o);
            usize = csize = (uint64_t)n;
        } else if (!dir) {
            FILE *f = fopen(full, "rb");
            if (!f) { rc = -1; sayo_set_error("cannot read %s", full); break; }
            z_stream zs;
            memset(&zs, 0, sizeof zs);
            if (method == 8) deflateInit2(&zs, level < 0 ? Z_DEFAULT_COMPRESSION : level, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
            size_t n;
            int eof = 0;
            while (!eof && rc == 0) {
                n = fread(in, 1, CHUNK, f);
                if (n < CHUNK) eof = 1;
                crc = (uint32_t)crc32(crc, in, (uInt)n);
                usize += n;
                if (method == 0) {
                    if (n && fwrite(in, 1, n, o) != n) { rc = -1; sayo_set_error("write failed"); }
                    csize += n;
                    continue;
                }
                zs.next_in = in;
                zs.avail_in = (uInt)n;
                do {
                    zs.next_out = out;
                    zs.avail_out = CHUNK;
                    deflate(&zs, eof ? Z_FINISH : Z_NO_FLUSH);
                    size_t got = CHUNK - zs.avail_out;
                    if (got && fwrite(out, 1, got, o) != got) { rc = -1; sayo_set_error("write failed"); break; }
                    csize += got;
                } while (zs.avail_out == 0);
            }
            if (method == 8) deflateEnd(&zs);
            fclose(f);
        }
        off_t endpos = ftello(o);
        uint8_t fix[12];
        fw32(fix, crc);
        fw32(fix + 4, 0xffffffff);
        fw32(fix + 8, 0xffffffff);
        fseeko(o, (off_t)loff + 14, SEEK_SET);
        fwrite(fix, 1, 12, o);
        uint8_t sizes[16];
        for (int k = 0; k < 8; k++) { sizes[k] = (uint8_t)(usize >> (8 * k)); sizes[8 + k] = (uint8_t)(csize >> (8 * k)); }
        fseeko(o, (off_t)(loff + 30 + nlen + 4), SEEK_SET);
        fwrite(sizes, 1, 16, o);
        fseeko(o, endpos, SEEK_SET);

        uint32_t mode = (uint32_t)st.st_mode;
        if (!dir && !link) mode = (mode & 0111) ? 0100755 : 0100644;
        if (dir) mode = 040755;
        w32(&cd, 0x02014b50);
        w16(&cd, 0x032d);
        w16(&cd, 45);
        w16(&cd, 0x0800);
        w16(&cd, (uint16_t)method);
        w16(&cd, 0);
        w16(&cd, 0x21);
        w32(&cd, crc);
        w32(&cd, 0xffffffff);
        w32(&cd, 0xffffffff);
        w16(&cd, (uint16_t)nlen);
        w16(&cd, 28);
        w16(&cd, 0);
        w16(&cd, 0);
        w16(&cd, 0);
        w32(&cd, (mode << 16) | (dir ? 0x10 : 0));
        w32(&cd, 0xffffffff);
        sayo_buf_append(&cd, name, nlen);
        w16(&cd, 1);
        w16(&cd, 24);
        w64(&cd, usize);
        w64(&cd, csize);
        w64(&cd, loff);
        count++;
    }
    uint64_t cd_off = (uint64_t)ftello(o);
    fwrite(cd.data, 1, cd.len, o);
    uint64_t z64_off = (uint64_t)ftello(o);
    sayo_buf e;
    sayo_buf_init(&e);
    w32(&e, 0x06064b50);
    w64(&e, 44);
    w16(&e, 0x032d);
    w16(&e, 45);
    w32(&e, 0);
    w32(&e, 0);
    w64(&e, count);
    w64(&e, count);
    w64(&e, cd.len);
    w64(&e, cd_off);
    w32(&e, 0x07064b50);
    w32(&e, 0);
    w64(&e, z64_off);
    w32(&e, 1);
    w32(&e, 0x06054b50);
    w16(&e, 0);
    w16(&e, 0);
    w16(&e, count > 0xffff ? 0xffff : (uint16_t)count);
    w16(&e, count > 0xffff ? 0xffff : (uint16_t)count);
    w32(&e, cd.len > 0xffffffffu ? 0xffffffffu : (uint32_t)cd.len);
    w32(&e, cd_off > 0xffffffffu ? 0xffffffffu : (uint32_t)cd_off);
    w16(&e, 0);
    fwrite(e.data, 1, e.len, o);
    sayo_buf_free(&e);
    sayo_buf_free(&cd);
    free(in);
    free(out);
    if (fclose(o)) rc = -1;
    sl_free(&files);
    if (progress && rc == 0) progress(ctx, 1.0, "zip");
    return rc;
}
