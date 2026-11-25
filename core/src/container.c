/* Prepares an app's main executable to be loaded inside SayoSign (LiveContainer-style):
 * MH_EXECUTE becomes MH_DYLIB so dlopen accepts it, and __PAGEZERO shrinks to one page at
 * 0xFFFFC000 so it does not collide with the host's own zero page. LC_MAIN stays, and the
 * host jumps to it after loading. Run this before signing: the signature covers the header. */
#include "internal.h"
#include <stdlib.h>
#include <string.h>

#define MH_MAGIC_64 0xfeedfacfu
#define FAT_MAGIC 0xcafebabeu
#define FAT_MAGIC_64 0xcafebabfu
#define MH_EXECUTE 2u
#define MH_DYLIB 6u
#define LC_SEGMENT_64 0x19u

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void wr32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
static void wr64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint64_t be64(const uint8_t *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }

/* Patches one thin 64-bit slice in place. 1 if patched, 0 if already a dylib, -1 on error. */
static int patch_slice(uint8_t *m, size_t len) {
    if (len < 32 || rd32(m) != MH_MAGIC_64) { sayo_set_error("not a 64-bit Mach-O"); return -1; }
    uint32_t filetype = rd32(m + 12);
    if (filetype == MH_DYLIB) return 0;
    if (filetype != MH_EXECUTE) { sayo_set_error("not an executable"); return -1; }
    uint32_t ncmds = rd32(m + 16), sizeofcmds = rd32(m + 20);
    if (32 + (size_t)sizeofcmds > len) { sayo_set_error("bad load commands"); return -1; }
    uint8_t *lc = m + 32, *end = m + 32 + sizeofcmds;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (lc + 8 > end) { sayo_set_error("bad load command"); return -1; }
        uint32_t cmd = rd32(lc), size = rd32(lc + 4);
        if (size < 8 || lc + size > end) { sayo_set_error("bad load command size"); return -1; }
        if (cmd == LC_SEGMENT_64 && size >= 72 && !strncmp((const char *)lc + 8, "__PAGEZERO", 16)) {
            wr64(lc + 24, 0xFFFFC000ull); /* vmaddr */
            wr64(lc + 32, 0x4000ull);     /* vmsize */
        }
        lc += size;
    }
    wr32(m + 12, MH_DYLIB);
    return 1;
}

int sayo_macho_make_dylib(const char *path) {
    sayo_buf b;
    if (sayo_read_file(path, &b)) return -1;
    int rc = 0, patched = 0;
    uint32_t magic = b.len >= 4 ? be32(b.data) : 0;
    if (magic == FAT_MAGIC || magic == FAT_MAGIC_64) {
        uint32_t n = be32(b.data + 4);
        size_t entry = magic == FAT_MAGIC ? 20 : 32;
        if (8 + (size_t)n * entry > b.len) { sayo_set_error("bad fat header"); rc = -1; goto out; }
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *a = b.data + 8 + i * entry;
            uint64_t off = magic == FAT_MAGIC ? be32(a + 8) : be64(a + 8);
            uint64_t size = magic == FAT_MAGIC ? be32(a + 12) : be64(a + 16);
            if (off + size > b.len) { sayo_set_error("bad fat slice"); rc = -1; goto out; }
            if (rd32(b.data + off) != MH_MAGIC_64) continue; /* 32-bit slices cannot run anyway */
            int r = patch_slice(b.data + off, (size_t)size);
            if (r < 0) { rc = -1; goto out; }
            patched |= r;
        }
    } else {
        int r = patch_slice(b.data, b.len);
        if (r < 0) { rc = -1; goto out; }
        patched = r;
    }
    if (patched) rc = sayo_write_file(path, b.data, b.len);
out:
    sayo_buf_free(&b);
    return rc;
}
