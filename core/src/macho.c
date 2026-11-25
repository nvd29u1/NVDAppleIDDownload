#include "internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MH_MAGIC 0xfeedface
#define MH_MAGIC_64 0xfeedfacf
#define FAT_MAGIC 0xcafebabe
#define MH_EXECUTE 0x2
#define LC_SEGMENT 0x1
#define LC_SEGMENT_64 0x19
#define LC_CODE_SIGNATURE 0x1d
#define LC_LOAD_DYLIB 0xc
#define LC_ID_DYLIB 0xd
#define LC_LOAD_WEAK_DYLIB 0x80000018
#define LC_REEXPORT_DYLIB 0x8000001f
#define LC_LAZY_LOAD_DYLIB 0x20
#define LC_LOAD_UPWARD_DYLIB 0x80000023
#define LC_RPATH 0x8000001c
#define LC_ENCRYPTION_INFO 0x21
#define LC_ENCRYPTION_INFO_64 0x2c
#define CS_PAGE 4096

static uint32_t le32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t le64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void wle32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void wle64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static uint32_t rbe32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static void wbe32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

bool macho_is(const uint8_t *p, size_t n) {
    if (n < 4) return false;
    uint32_t m = le32(p);
    return m == MH_MAGIC || m == MH_MAGIC_64 || rbe32(p) == FAT_MAGIC;
}

typedef struct {
    sayo_buf data;
    uint32_t cputype, cpusubtype, align;
} slice;

typedef struct {
    slice *s;
    size_t n;
    bool fat;
} mfile;

static void mfile_free(mfile *f) {
    for (size_t i = 0; i < f->n; i++) sayo_buf_free(&f->s[i].data);
    free(f->s);
    f->s = NULL;
    f->n = 0;
}

static int mfile_load(const char *path, mfile *f) {
    sayo_buf b;
    memset(f, 0, sizeof *f);
    if (sayo_read_file(path, &b)) return -1;
    if (b.len >= 8 && rbe32(b.data) == FAT_MAGIC) {
        uint32_t n = rbe32(b.data + 4);
        if (n == 0 || n > 32 || 8 + (size_t)n * 20 > b.len) { sayo_buf_free(&b); sayo_set_error("bad fat header in %s", path); return -1; }
        f->fat = true;
        f->s = calloc(n, sizeof *f->s);
        f->n = n;
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *a = b.data + 8 + i * 20;
            uint32_t off = rbe32(a + 8), sz = rbe32(a + 12);
            if ((size_t)off + sz > b.len) { mfile_free(f); sayo_buf_free(&b); sayo_set_error("bad fat slice in %s", path); return -1; }
            f->s[i].cputype = rbe32(a);
            f->s[i].cpusubtype = rbe32(a + 4);
            f->s[i].align = rbe32(a + 16);
            sayo_buf_init(&f->s[i].data);
            sayo_buf_append(&f->s[i].data, b.data + off, sz);
        }
        sayo_buf_free(&b);
        return 0;
    }
    if (b.len < 28 || (le32(b.data) != MH_MAGIC && le32(b.data) != MH_MAGIC_64)) {
        sayo_buf_free(&b);
        sayo_set_error("not a Mach-O: %s", path);
        return -1;
    }
    f->s = calloc(1, sizeof *f->s);
    f->n = 1;
    f->s[0].data = b;
    f->s[0].cputype = le32(b.data + 4);
    f->s[0].cpusubtype = le32(b.data + 8);
    f->s[0].align = 14;
    return 0;
}

static int mfile_save(const char *path, mfile *f) {
    if (!f->fat) return sayo_write_file(path, f->s[0].data.data, f->s[0].data.len);
    sayo_buf o;
    sayo_buf_init(&o);
    sayo_buf_be32(&o, FAT_MAGIC);
    sayo_buf_be32(&o, (uint32_t)f->n);
    size_t off = 8 + f->n * 20;
    size_t *offs = calloc(f->n, sizeof *offs);
    for (size_t i = 0; i < f->n; i++) {
        size_t al = (size_t)1 << f->s[i].align;
        off = (off + al - 1) & ~(al - 1);
        offs[i] = off;
        off += f->s[i].data.len;
    }
    for (size_t i = 0; i < f->n; i++) {
        sayo_buf_be32(&o, f->s[i].cputype);
        sayo_buf_be32(&o, f->s[i].cpusubtype);
        sayo_buf_be32(&o, (uint32_t)offs[i]);
        sayo_buf_be32(&o, (uint32_t)f->s[i].data.len);
        sayo_buf_be32(&o, f->s[i].align);
    }
    for (size_t i = 0; i < f->n; i++) {
        sayo_buf_fill(&o, 0, offs[i] - o.len);
        sayo_buf_append(&o, f->s[i].data.data, f->s[i].data.len);
    }
    free(offs);
    int rc = sayo_write_file(path, o.data, o.len);
    sayo_buf_free(&o);
    return rc;
}

typedef struct {
    bool is64;
    uint32_t hdr_size;
    uint32_t ncmds, sizeofcmds;
    uint32_t filetype;
    size_t first_section;
    uint8_t *linkedit;
    uint8_t *codesig;
    uint64_t text_off, text_size;
    bool encrypted;
} minfo;

static int macho_parse(sayo_buf *d, minfo *m) {
    memset(m, 0, sizeof *m);
    uint8_t *p = d->data;
    if (d->len < 28) return -1;
    uint32_t magic = le32(p);
    if (magic != MH_MAGIC && magic != MH_MAGIC_64) { sayo_set_error("bad Mach-O magic"); return -1; }
    m->is64 = magic == MH_MAGIC_64;
    m->hdr_size = m->is64 ? 32 : 28;
    m->filetype = le32(p + 12);
    m->ncmds = le32(p + 16);
    m->sizeofcmds = le32(p + 20);
    if ((size_t)m->hdr_size + m->sizeofcmds > d->len) { sayo_set_error("bad load commands"); return -1; }
    m->first_section = d->len;
    uint8_t *c = p + m->hdr_size;
    uint8_t *end = c + m->sizeofcmds;
    for (uint32_t i = 0; i < m->ncmds; i++) {
        if (c + 8 > end) { sayo_set_error("truncated load commands"); return -1; }
        uint32_t cmd = le32(c), sz = le32(c + 4);
        if (sz < 8 || c + sz > end) { sayo_set_error("bad load command size"); return -1; }
        if (cmd == LC_SEGMENT_64 || cmd == LC_SEGMENT) {
            bool s64 = cmd == LC_SEGMENT_64;
            const char *name = (const char *)c + 8;
            uint64_t fileoff = s64 ? le64(c + 40) : le32(c + 32);
            uint64_t filesize = s64 ? le64(c + 48) : le32(c + 36);
            uint32_t nsects = le32(c + (s64 ? 64 : 48));
            if (!strncmp(name, "__LINKEDIT", 16)) m->linkedit = c;
            if (!strncmp(name, "__TEXT", 16)) { m->text_off = fileoff; m->text_size = filesize; }
            uint8_t *sec = c + (s64 ? 72 : 56);
            for (uint32_t k = 0; k < nsects; k++) {
                if (sec + (s64 ? 80 : 68) > c + sz) break;
                uint32_t off = le32(sec + (s64 ? 48 : 40));
                uint32_t flags = le32(sec + (s64 ? 64 : 56));
                uint32_t type = flags & 0xff;
                if (off && type != 0x1 && type != 0xc && type != 0x12 && off < m->first_section) m->first_section = off;
                sec += s64 ? 80 : 68;
            }
            if (fileoff && filesize && fileoff < m->first_section && strncmp(name, "__TEXT", 16))
                m->first_section = fileoff;
        } else if (cmd == LC_CODE_SIGNATURE) {
            m->codesig = c;
        } else if (cmd == LC_ENCRYPTION_INFO || cmd == LC_ENCRYPTION_INFO_64) {
            if (le32(c + 16)) m->encrypted = true;
        }
        c += sz;
    }
    return 0;
}

typedef struct {
    uint8_t **cmds;
    uint32_t *sizes;
    size_t n;
} cmdlist;

static void cl_free(cmdlist *l) {
    for (size_t i = 0; i < l->n; i++) free(l->cmds[i]);
    free(l->cmds);
    free(l->sizes);
    memset(l, 0, sizeof *l);
}

static void cl_add(cmdlist *l, const uint8_t *c, uint32_t sz) {
    l->cmds = realloc(l->cmds, (l->n + 1) * sizeof *l->cmds);
    l->sizes = realloc(l->sizes, (l->n + 1) * sizeof *l->sizes);
    l->cmds[l->n] = malloc(sz);
    memcpy(l->cmds[l->n], c, sz);
    l->sizes[l->n] = sz;
    l->n++;
}

static int cl_read(sayo_buf *d, minfo *m, cmdlist *l) {
    memset(l, 0, sizeof *l);
    uint8_t *c = d->data + m->hdr_size;
    for (uint32_t i = 0; i < m->ncmds; i++) {
        uint32_t sz = le32(c + 4);
        cl_add(l, c, sz);
        c += sz;
    }
    return 0;
}

static int cl_write(sayo_buf *d, minfo *m, cmdlist *l) {
    size_t total = 0;
    for (size_t i = 0; i < l->n; i++) total += l->sizes[i];
    if (m->hdr_size + total > m->first_section) {
        sayo_set_error("not enough space for load commands (need %zu, have %zu)", total, m->first_section - m->hdr_size);
        return -1;
    }
    uint8_t *c = d->data + m->hdr_size;
    size_t old = m->sizeofcmds;
    for (size_t i = 0; i < l->n; i++) {
        memcpy(c, l->cmds[i], l->sizes[i]);
        c += l->sizes[i];
    }
    if (old > total) memset(c, 0, old - total);
    wle32(d->data + 16, (uint32_t)l->n);
    wle32(d->data + 20, (uint32_t)total);
    return macho_parse(d, m);
}

static uint8_t *make_dylib_cmd(uint32_t cmd, const char *path, uint32_t *size_out, uint32_t ts, uint32_t cur, uint32_t compat) {
    size_t pl = strlen(path) + 1;
    uint32_t sz = (uint32_t)((24 + pl + 7) & ~(size_t)7);
    uint8_t *c = calloc(1, sz);
    wle32(c, cmd);
    wle32(c + 4, sz);
    wle32(c + 8, 24);
    wle32(c + 12, ts);
    wle32(c + 16, cur);
    wle32(c + 20, compat);
    memcpy(c + 24, path, pl);
    *size_out = sz;
    return c;
}

static bool is_dylib_cmd(uint32_t cmd) {
    return cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB ||
           cmd == LC_LAZY_LOAD_DYLIB || cmd == LC_LOAD_UPWARD_DYLIB || cmd == LC_ID_DYLIB;
}

static const char *cmd_str(const uint8_t *c, uint32_t sz, uint32_t off_at) {
    uint32_t off = le32(c + off_at);
    if (off >= sz) return "";
    return (const char *)c + off;
}

typedef int (*slice_edit_fn)(sayo_buf *d, minfo *m, cmdlist *l, void *ctx);

static int edit_all(const char *path, slice_edit_fn fn, void *ctx) {
    mfile f;
    if (mfile_load(path, &f)) return -1;
    for (size_t i = 0; i < f.n; i++) {
        minfo m;
        cmdlist l;
        if (macho_parse(&f.s[i].data, &m)) { mfile_free(&f); return -1; }
        cl_read(&f.s[i].data, &m, &l);
        int rc = fn(&f.s[i].data, &m, &l, ctx);
        if (rc > 0) rc = cl_write(&f.s[i].data, &m, &l);
        cl_free(&l);
        if (rc < 0) { mfile_free(&f); return -1; }
    }
    int rc = mfile_save(path, &f);
    mfile_free(&f);
    return rc;
}

typedef struct { const char *path; bool weak; } add_ctx;

static int do_add(sayo_buf *d, minfo *m, cmdlist *l, void *vctx) {
    (void)d; (void)m;
    add_ctx *a = vctx;
    for (size_t i = 0; i < l->n; i++) {
        uint32_t cmd = le32(l->cmds[i]);
        if (is_dylib_cmd(cmd) && cmd != LC_ID_DYLIB && !strcmp(cmd_str(l->cmds[i], l->sizes[i], 8), a->path)) return 0;
    }
    uint32_t sz;
    uint8_t *c = make_dylib_cmd(a->weak ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB, a->path, &sz, 2, 0x10000, 0x10000);
    size_t pos = l->n;
    for (size_t i = 0; i < l->n; i++) if (le32(l->cmds[i]) == LC_CODE_SIGNATURE) { pos = i; break; }
    cl_add(l, c, sz);
    free(c);
    if (pos != l->n - 1) {
        uint8_t *nc = l->cmds[l->n - 1];
        uint32_t ns = l->sizes[l->n - 1];
        memmove(l->cmds + pos + 1, l->cmds + pos, (l->n - 1 - pos) * sizeof *l->cmds);
        memmove(l->sizes + pos + 1, l->sizes + pos, (l->n - 1 - pos) * sizeof *l->sizes);
        l->cmds[pos] = nc;
        l->sizes[pos] = ns;
    }
    return 1;
}

int macho_add_dylib(const char *path, const char *dylib_path, bool weak) {
    add_ctx a = { dylib_path, weak };
    return edit_all(path, do_add, &a);
}

typedef struct { const char *from, *to; } chg_ctx;

static int do_change(sayo_buf *d, minfo *m, cmdlist *l, void *vctx) {
    (void)d; (void)m;
    chg_ctx *a = vctx;
    int changed = 0;
    for (size_t i = 0; i < l->n; i++) {
        uint32_t cmd = le32(l->cmds[i]);
        if (!is_dylib_cmd(cmd)) continue;
        if (strcmp(cmd_str(l->cmds[i], l->sizes[i], 8), a->from)) continue;
        uint32_t sz;
        uint8_t *c = make_dylib_cmd(cmd, a->to, &sz, le32(l->cmds[i] + 12), le32(l->cmds[i] + 16), le32(l->cmds[i] + 20));
        free(l->cmds[i]);
        l->cmds[i] = c;
        l->sizes[i] = sz;
        changed = 1;
    }
    return changed;
}

int macho_change_dylib(const char *path, const char *from, const char *to) {
    chg_ctx a = { from, to };
    return edit_all(path, do_change, &a);
}

static int do_rpath(sayo_buf *d, minfo *m, cmdlist *l, void *vctx) {
    (void)d; (void)m;
    const char *rp = vctx;
    for (size_t i = 0; i < l->n; i++)
        if (le32(l->cmds[i]) == LC_RPATH && !strcmp(cmd_str(l->cmds[i], l->sizes[i], 8), rp)) return 0;
    size_t pl = strlen(rp) + 1;
    uint32_t sz = (uint32_t)((12 + pl + 7) & ~(size_t)7);
    uint8_t *c = calloc(1, sz);
    wle32(c, LC_RPATH);
    wle32(c + 4, sz);
    wle32(c + 8, 12);
    memcpy(c + 12, rp, pl);
    size_t pos = l->n;
    for (size_t i = 0; i < l->n; i++) if (le32(l->cmds[i]) == LC_CODE_SIGNATURE) { pos = i; break; }
    cl_add(l, c, sz);
    free(c);
    if (pos != l->n - 1) {
        uint8_t *nc = l->cmds[l->n - 1];
        uint32_t ns = l->sizes[l->n - 1];
        memmove(l->cmds + pos + 1, l->cmds + pos, (l->n - 1 - pos) * sizeof *l->cmds);
        memmove(l->sizes + pos + 1, l->sizes + pos, (l->n - 1 - pos) * sizeof *l->sizes);
        l->cmds[pos] = nc;
        l->sizes[pos] = ns;
    }
    return 1;
}

int macho_add_rpath(const char *path, const char *rpath) {
    return edit_all(path, do_rpath, (void *)rpath);
}

int macho_list_dylibs(const char *path, strlist *out) {
    mfile f;
    if (mfile_load(path, &f)) return -1;
    minfo m;
    if (macho_parse(&f.s[0].data, &m)) { mfile_free(&f); return -1; }
    uint8_t *c = f.s[0].data.data + m.hdr_size;
    for (uint32_t i = 0; i < m.ncmds; i++) {
        uint32_t cmd = le32(c), sz = le32(c + 4);
        if (is_dylib_cmd(cmd) && cmd != LC_ID_DYLIB) sl_push(out, cmd_str(c, sz, 8));
        c += sz;
    }
    mfile_free(&f);
    return 0;
}

static void blob_hdr(sayo_buf *b, uint32_t magic, uint32_t len) {
    sayo_buf_be32(b, magic);
    sayo_buf_be32(b, len);
}

static int sign_slice(slice *s, const char *ident, const char *team,
                      const uint8_t *ent_xml, size_t ent_xml_len,
                      const uint8_t *ent_der, size_t ent_der_len,
                      const uint8_t info_hash[32], bool has_info,
                      const uint8_t res_hash[32], bool has_res,
                      bool main_exec, bool gta,
                      const sayo_identity *id, uint8_t cdhash_out[20]) {
    sayo_buf *d = &s->data;
    minfo m;
    if (macho_parse(d, &m)) return -1;
    if (m.encrypted) { sayo_set_error("binary is encrypted (FairPlay); decrypt the IPA first"); return -1; }
    if (!m.linkedit) { sayo_set_error("no __LINKEDIT segment"); return -1; }
    uint64_t le_off = m.is64 ? le64(m.linkedit + 40) : le32(m.linkedit + 32);
    uint64_t le_size = m.is64 ? le64(m.linkedit + 48) : le32(m.linkedit + 36);
    uint32_t dataoff;
    if (m.codesig) {
        dataoff = le32(m.codesig + 8);
    } else {
        cmdlist l;
        cl_read(d, &m, &l);
        uint8_t c[16] = { 0 };
        wle32(c, LC_CODE_SIGNATURE);
        wle32(c + 4, 16);
        cl_add(&l, c, 16);
        int rc = cl_write(d, &m, &l);
        cl_free(&l);
        if (rc) return -1;
        dataoff = (uint32_t)((le_off + le_size + 15) & ~(uint64_t)15);
        if (!m.codesig) { sayo_set_error("failed to add LC_CODE_SIGNATURE"); return -1; }
        le_off = m.is64 ? le64(m.linkedit + 40) : le32(m.linkedit + 32);
    }

    sayo_buf reqs, ents, dents;
    sayo_buf_init(&reqs);
    sayo_buf_init(&ents);
    sayo_buf_init(&dents);
    blob_hdr(&reqs, 0xfade0c01, 12);
    sayo_buf_be32(&reqs, 0);
    bool has_ent = ent_xml && ent_xml_len;
    bool has_dent = has_ent && ent_der && ent_der_len;
    if (has_ent) {
        blob_hdr(&ents, 0xfade7171, (uint32_t)(8 + ent_xml_len));
        sayo_buf_append(&ents, ent_xml, ent_xml_len);
    }
    if (has_dent) {
        blob_hdr(&dents, 0xfade7172, (uint32_t)(8 + ent_der_len));
        sayo_buf_append(&dents, ent_der, ent_der_len);
    }

    uint32_t nspecial = has_dent ? 7 : has_ent ? 5 : has_res ? 3 : 2;
    uint32_t ncode = (dataoff + CS_PAGE - 1) / CS_PAGE;
    size_t idlen = strlen(ident) + 1;
    size_t teamlen = team && *team ? strlen(team) + 1 : 0;
    uint32_t hdr = 88;
    uint32_t ident_off = hdr;
    uint32_t team_off = teamlen ? (uint32_t)(ident_off + idlen) : 0;
    uint32_t hash_off = (uint32_t)(ident_off + idlen + teamlen + nspecial * 32);
    uint32_t cd_len = hash_off + ncode * 32;

    size_t chain_total = id->cert_len;
    for (size_t i = 0; i < id->chain_count; i++) chain_total += id->chain_len[i];
    size_t cms_reserve = chain_total + 4096;
    size_t nblobs = 2 + (has_ent ? 1 : 0) + (has_dent ? 1 : 0) + 1;
    size_t sb_len = 12 + nblobs * 8 + cd_len + reqs.len + ents.len + dents.len + 8 + cms_reserve;
    uint32_t datasize = (uint32_t)((sb_len + 15) & ~(size_t)15);

    if (sayo_buf_reserve(d, (size_t)dataoff + datasize > d->len ? (size_t)dataoff + datasize - d->len : 0)) return -1;
    if (d->len < dataoff) sayo_buf_fill(d, 0, dataoff - d->len);
    d->len = dataoff;
    if (macho_parse(d, &m)) return -1;
    wle32(m.codesig + 8, dataoff);
    wle32(m.codesig + 12, datasize);
    uint64_t new_le_size = (uint64_t)dataoff + datasize - le_off;
    uint64_t vm = (new_le_size + 0x3fff) & ~(uint64_t)0x3fff;
    if (m.is64) {
        wle64(m.linkedit + 48, new_le_size);
        uint64_t oldvm = le64(m.linkedit + 32);
        if (vm > oldvm) wle64(m.linkedit + 32, vm);
    } else {
        wle32(m.linkedit + 36, (uint32_t)new_le_size);
        uint32_t oldvm = le32(m.linkedit + 28);
        if (vm > oldvm) wle32(m.linkedit + 28, (uint32_t)vm);
    }

    sayo_buf cd;
    sayo_buf_init(&cd);
    blob_hdr(&cd, 0xfade0c02, cd_len);
    sayo_buf_be32(&cd, 0x20400);
    sayo_buf_be32(&cd, 0);
    sayo_buf_be32(&cd, hash_off);
    sayo_buf_be32(&cd, ident_off);
    sayo_buf_be32(&cd, nspecial);
    sayo_buf_be32(&cd, ncode);
    sayo_buf_be32(&cd, dataoff);
    sayo_buf_byte(&cd, 32);
    sayo_buf_byte(&cd, 2);
    sayo_buf_byte(&cd, 0);
    sayo_buf_byte(&cd, 12);
    sayo_buf_be32(&cd, 0);
    sayo_buf_be32(&cd, 0);
    sayo_buf_be32(&cd, team_off);
    sayo_buf_be32(&cd, 0);
    sayo_buf_be64(&cd, 0);
    sayo_buf_be64(&cd, m.text_off);
    sayo_buf_be64(&cd, m.text_size);
    uint64_t esf = 0;
    if (main_exec && m.filetype == MH_EXECUTE) esf |= 1;
    if (main_exec && gta) esf |= 0x10;
    sayo_buf_be64(&cd, esf);
    sayo_buf_append(&cd, ident, idlen);
    if (teamlen) sayo_buf_append(&cd, team, teamlen);
    uint8_t special[7][32];
    memset(special, 0, sizeof special);
    if (has_info) memcpy(special[0], info_hash, 32);
    sayo_sha256(reqs.data, reqs.len, special[1]);
    if (has_res) memcpy(special[2], res_hash, 32);
    if (has_ent) sayo_sha256(ents.data, ents.len, special[4]);
    if (has_dent) sayo_sha256(dents.data, dents.len, special[6]);
    for (int i = (int)nspecial; i >= 1; i--) sayo_buf_append(&cd, special[i - 1], 32);
    for (uint32_t i = 0; i < ncode; i++) {
        size_t off = (size_t)i * CS_PAGE;
        size_t n = dataoff - off < CS_PAGE ? dataoff - off : CS_PAGE;
        uint8_t h[32];
        sayo_sha256(d->data + off, n, h);
        sayo_buf_append(&cd, h, 32);
    }

    uint8_t cdh[32];
    sayo_sha256(cd.data, cd.len, cdh);
    memcpy(cdhash_out, cdh, 20);

    sayo_buf cms;
    if (cms_sign(id, cd.data, cd.len, cdh, &cms)) {
        sayo_buf_free(&cd); sayo_buf_free(&reqs); sayo_buf_free(&ents); sayo_buf_free(&dents);
        return -1;
    }
    if (cms.len > cms_reserve) {
        sayo_set_error("signature larger than reserved space");
        sayo_buf_free(&cms); sayo_buf_free(&cd); sayo_buf_free(&reqs); sayo_buf_free(&ents); sayo_buf_free(&dents);
        return -1;
    }

    sayo_buf sb;
    sayo_buf_init(&sb);
    uint32_t real_len = (uint32_t)(12 + nblobs * 8 + cd.len + reqs.len + ents.len + dents.len + 8 + cms.len);
    blob_hdr(&sb, 0xfade0cc0, real_len);
    sayo_buf_be32(&sb, (uint32_t)nblobs);
    uint32_t off = (uint32_t)(12 + nblobs * 8);
    sayo_buf_be32(&sb, 0); sayo_buf_be32(&sb, off); off += (uint32_t)cd.len;
    sayo_buf_be32(&sb, 2); sayo_buf_be32(&sb, off); off += (uint32_t)reqs.len;
    if (has_ent) { sayo_buf_be32(&sb, 5); sayo_buf_be32(&sb, off); off += (uint32_t)ents.len; }
    if (has_dent) { sayo_buf_be32(&sb, 7); sayo_buf_be32(&sb, off); off += (uint32_t)dents.len; }
    sayo_buf_be32(&sb, 0x10000); sayo_buf_be32(&sb, off);
    sayo_buf_append(&sb, cd.data, cd.len);
    sayo_buf_append(&sb, reqs.data, reqs.len);
    if (has_ent) sayo_buf_append(&sb, ents.data, ents.len);
    if (has_dent) sayo_buf_append(&sb, dents.data, dents.len);
    blob_hdr(&sb, 0xfade0b01, (uint32_t)(8 + cms.len));
    sayo_buf_append(&sb, cms.data, cms.len);
    sayo_buf_fill(&sb, 0, datasize - sb.len);

    sayo_buf_append(d, sb.data, sb.len);
    sayo_buf_free(&sb);
    sayo_buf_free(&cms);
    sayo_buf_free(&cd);
    sayo_buf_free(&reqs);
    sayo_buf_free(&ents);
    sayo_buf_free(&dents);
    return 0;
}

int macho_sign(const char *path, const char *ident, const char *team_id,
               const uint8_t *ent_xml, size_t ent_xml_len,
               const uint8_t *ent_der, size_t ent_der_len,
               const uint8_t info_hash[32], bool has_info,
               const uint8_t res_hash[32], bool has_res,
               bool main_exec, bool gta,
               const sayo_identity *id, uint8_t cdhash_out[20]) {
    mfile f;
    if (mfile_load(path, &f)) return -1;
    uint8_t first[20] = { 0 };
    for (size_t i = 0; i < f.n; i++) {
        uint8_t h[20];
        if (sign_slice(&f.s[i], ident, team_id, ent_xml, ent_xml_len, ent_der, ent_der_len,
                       info_hash, has_info, res_hash, has_res, main_exec, gta, id, h)) {
            char msg[600];
            snprintf(msg, sizeof msg, "%s: %s", path, sayo_last_error());
            sayo_set_error("%s", msg);
            mfile_free(&f);
            return -1;
        }
        if (i == 0 || f.s[i].cputype == 0x0100000c) memcpy(first, h, 20);
    }
    memcpy(cdhash_out, first, 20);
    int rc = mfile_save(path, &f);
    mfile_free(&f);
    return rc;
}
