#include "internal.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *SUBSTRATE_PATHS[] = {
    "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    "@rpath/CydiaSubstrate.framework/CydiaSubstrate",
    "/usr/lib/libsubstrate.dylib",
    "/var/jb/usr/lib/libsubstrate.dylib",
    "@rpath/libsubstrate.dylib",
    "/usr/lib/libsubstitute.dylib",
    "/usr/lib/libsubstitute.0.dylib",
    "/var/jb/usr/lib/libsubstitute.dylib",
    "/usr/lib/libhooker.dylib",
    "/var/jb/usr/lib/libhooker.dylib",
    "/usr/lib/libellekit.dylib",
    "/var/jb/usr/lib/libellekit.dylib",
    "@rpath/libellekit.dylib",
    "/usr/lib/libblackjack.dylib",
    "/var/jb/usr/lib/libblackjack.dylib",
    NULL
};

#define HOOK_LOAD "@rpath/CydiaSubstrate.framework/CydiaSubstrate"

typedef struct {
    pl_node *ents;
    const char *team;
    const sayo_identity *id;
    sayo_progress_fn progress;
    void *pctx;
    size_t done, total;
} sctx;

static int find_xml(const uint8_t *p, size_t n, const uint8_t **start, size_t *len) {
    const char *open = "<?xml", *close = "</plist>";
    const uint8_t *s = NULL;
    for (size_t i = 0; i + 5 <= n; i++) if (!memcmp(p + i, open, 5)) { s = p + i; break; }
    if (!s) return -1;
    for (const uint8_t *q = s; q + 8 <= p + n; q++) {
        if (!memcmp(q, close, 8)) {
            *start = s;
            *len = (size_t)(q + 8 - s);
            return 0;
        }
    }
    return -1;
}

int sayo_provision_plist_xml(const uint8_t *provision, size_t len, sayo_buf *xml) {
    const uint8_t *s;
    size_t n;
    sayo_buf_init(xml);
    if (find_xml(provision, len, &s, &n)) { sayo_set_error("invalid provisioning profile"); return -1; }
    return sayo_buf_append(xml, s, n);
}

int sayo_provision_entitlements_xml(const uint8_t *provision, size_t len, sayo_buf *xml) {
    sayo_buf p;
    if (sayo_provision_plist_xml(provision, len, &p)) return -1;
    pl_node *root = pl_parse(p.data, p.len);
    sayo_buf_free(&p);
    pl_node *e = pl_get(root, "Entitlements");
    if (!e) { pl_free(root); sayo_set_error("profile has no entitlements"); return -1; }
    pl_to_xml(e, xml);
    pl_free(root);
    return 0;
}

static bool ends_with(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && !strcmp(s + a - b, suf);
}

static bool is_code_bundle_dir(const char *name) {
    return ends_with(name, ".app") || ends_with(name, ".appex") || ends_with(name, ".framework") || ends_with(name, ".xctest");
}

static bool file_is_macho(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    uint8_t m[4];
    size_t n = fread(m, 1, 4, f);
    fclose(f);
    return n == 4 && macho_is(m, 4);
}

static void collect(const char *root, const char *rel, strlist *bundles, strlist *machos) {
    char full[4096];
    path_join(full, sizeof full, root, rel);
    DIR *d = opendir(full);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char sub[4096], subfull[4096];
        if (*rel) snprintf(sub, sizeof sub, "%s/%s", rel, e->d_name);
        else snprintf(sub, sizeof sub, "%s", e->d_name);
        path_join(subfull, sizeof subfull, root, sub);
        struct stat st;
        if (lstat(subfull, &st)) continue;
        if (S_ISDIR(st.st_mode)) {
            char ip[4096];
            path_join(ip, sizeof ip, subfull, "Info.plist");
            if (is_code_bundle_dir(e->d_name) && is_file(ip)) {
                sl_push(bundles, sub);
                continue;
            }
            if (!strcmp(e->d_name, "_CodeSignature")) continue;
            collect(root, sub, bundles, machos);
        } else if (S_ISREG(st.st_mode)) {
            if (file_is_macho(subfull)) sl_push(machos, sub);
        }
    }
    closedir(d);
}

static void hash_file(const char *path, uint8_t out[32], bool *ok) {
    sayo_buf b;
    if (sayo_read_file(path, &b)) { *ok = false; return; }
    sayo_sha256(b.data, b.len, out);
    sayo_buf_free(&b);
    *ok = true;
}

static pl_node *bundle_ents(sctx *c, const char *bundle_id) {
    pl_node *e = pl_clone(c->ents);
    char appid[512];
    /* A wildcard profile (TEAM.*) becomes this bundle's ID. An explicit profile keeps its
     * own application-identifier: iOS checks the signature's entitlements against the
     * profile, not against CFBundleIdentifier, so apps keep their own bundle IDs. */
    const char *prof_appid = pl_get_str(c->ents, "application-identifier");
    if (prof_appid && !strchr(prof_appid, '*')) snprintf(appid, sizeof appid, "%s", prof_appid);
    else snprintf(appid, sizeof appid, "%s.%s", c->team, bundle_id);
    pl_set(e, "application-identifier", pl_new_str(appid));
    pl_node *g = pl_get(e, "com.apple.developer.team-identifier");
    if (!g) pl_set(e, "com.apple.developer.team-identifier", pl_new_str(c->team));
    pl_node *kag = pl_get(e, "keychain-access-groups");
    if (kag && kag->type == PL_ARRAY) {
        for (size_t i = 0; i < kag->count; i++) {
            pl_node *it = kag->items[i];
            if (it->type == PL_STRING && ends_with(it->str, ".*")) {
                free(it->str);
                it->str = strdup(appid);
            }
        }
    }
    return e;
}

static int sign_bundle(sctx *c, const char *dir, bool is_app) {
    char ip[4096];
    path_join(ip, sizeof ip, dir, "Info.plist");
    pl_node *info = pl_parse_file(ip);
    if (!info) return -1;
    const char *exe = pl_get_str(info, "CFBundleExecutable");
    const char *bid = pl_get_str(info, "CFBundleIdentifier");
    char exe_s[1024] = "", bid_s[1024] = "";
    if (exe) snprintf(exe_s, sizeof exe_s, "%s", exe);
    if (bid) snprintf(bid_s, sizeof bid_s, "%s", bid);
    pl_free(info);
    if (!*bid_s) {
        const char *b = strrchr(dir, '/');
        snprintf(bid_s, sizeof bid_s, "%s", b ? b + 1 : dir);
    }

    strlist bundles = { 0 }, machos = { 0 };
    collect(dir, "", &bundles, &machos);
    sl_sort(&bundles);
    sl_sort(&machos);
    for (size_t i = 0; i < bundles.count; i++) {
        char sub[4096];
        path_join(sub, sizeof sub, dir, bundles.items[i]);
        bool sub_app = ends_with(sub, ".appex") || ends_with(sub, ".app");
        if (sign_bundle(c, sub, sub_app)) { sl_free(&bundles); sl_free(&machos); return -1; }
    }
    for (size_t i = 0; i < machos.count; i++) {
        if (*exe_s && !strcmp(machos.items[i], exe_s)) continue;
        char mp[4096];
        path_join(mp, sizeof mp, dir, machos.items[i]);
        const char *base = strrchr(machos.items[i], '/');
        base = base ? base + 1 : machos.items[i];
        char ident[1024];
        snprintf(ident, sizeof ident, "%s", base);
        char *dot = strrchr(ident, '.');
        if (dot && dot != ident) *dot = 0;
        uint8_t cdh[20];
        if (macho_sign(mp, ident, c->team, NULL, 0, NULL, 0, NULL, false, NULL, false, false, false, c->id, cdh)) {
            sl_free(&bundles); sl_free(&machos); return -1;
        }
        c->done++;
        if (c->progress) c->progress(c->pctx, 0.3 + 0.6 * (double)c->done / (double)(c->total ? c->total : 1), "sign");
    }
    sl_free(&bundles);
    sl_free(&machos);

    char sigdir[4096], crp[4096];
    path_join(sigdir, sizeof sigdir, dir, "_CodeSignature");
    rmtree(sigdir);
    sayo_buf xml;
    if (code_resources(dir, *exe_s ? exe_s : NULL, NULL, NULL, NULL, &xml)) return -1;
    mkdirs(sigdir);
    path_join(crp, sizeof crp, sigdir, "CodeResources");
    int rc = sayo_write_file(crp, xml.data, xml.len);
    uint8_t res_hash[32];
    sayo_sha256(xml.data, xml.len, res_hash);
    sayo_buf_free(&xml);
    if (rc) return -1;
    if (!*exe_s) return 0;

    char ep[4096];
    path_join(ep, sizeof ep, dir, exe_s);
    if (!is_file(ep)) { sayo_set_error("missing executable %s", ep); return -1; }
    uint8_t info_hash[32];
    bool ok;
    hash_file(ip, info_hash, &ok);
    if (!ok) return -1;

    sayo_buf exml, eder;
    sayo_buf_init(&exml);
    sayo_buf_init(&eder);
    bool gta = false;
    if (is_app) {
        pl_node *e = bundle_ents(c, bid_s);
        pl_node *g = pl_get(e, "get-task-allow");
        gta = g && g->type == PL_BOOL && g->i;
        pl_to_xml(e, &exml);
        ent_to_der(e, &eder);
        pl_free(e);
    }
    uint8_t cdh[20];
    rc = macho_sign(ep, bid_s, c->team, exml.len ? exml.data : NULL, exml.len, eder.len ? eder.data : NULL, eder.len,
                    info_hash, true, res_hash, true, is_app, gta, c->id, cdh);
    sayo_buf_free(&exml);
    sayo_buf_free(&eder);
    c->done++;
    if (c->progress) c->progress(c->pctx, 0.3 + 0.6 * (double)c->done / (double)(c->total ? c->total : 1), "sign");
    return rc;
}

static size_t count_macho(const char *dir) {
    strlist all = { 0 };
    list_tree(dir, "", &all, false);
    size_t n = 0;
    for (size_t i = 0; i < all.count; i++) {
        char p[4096];
        path_join(p, sizeof p, dir, all.items[i]);
        if (is_file(p) && file_is_macho(p)) n++;
    }
    sl_free(&all);
    return n;
}

static void replace_prefix(pl_node *info, const char *old_main, const char *new_main) {
    const char *b = pl_get_str(info, "CFBundleIdentifier");
    if (!b) return;
    size_t ol = strlen(old_main);
    if (!strncmp(b, old_main, ol) && (b[ol] == '.' || b[ol] == 0)) {
        char nb[1024];
        snprintf(nb, sizeof nb, "%s%s", new_main, b + ol);
        pl_set(info, "CFBundleIdentifier", pl_new_str(nb));
    }
    pl_node *ext = pl_get(info, "NSExtension");
    pl_node *attrs = ext ? pl_get(ext, "NSExtensionAttributes") : NULL;
    const char *wk = attrs ? pl_get_str(attrs, "WKAppBundleIdentifier") : NULL;
    if (wk && !strncmp(wk, old_main, ol)) {
        char nb[1024];
        snprintf(nb, sizeof nb, "%s%s", new_main, wk + ol);
        pl_set(attrs, "WKAppBundleIdentifier", pl_new_str(nb));
    }
    const char *comp = pl_get_str(info, "WKCompanionAppBundleIdentifier");
    if (comp && !strncmp(comp, old_main, ol)) {
        char nb[1024];
        snprintf(nb, sizeof nb, "%s%s", new_main, comp + ol);
        pl_set(info, "WKCompanionAppBundleIdentifier", pl_new_str(nb));
    }
}

static void rename_nested(const char *dir, const char *old_main, const char *new_main) {
    strlist bundles = { 0 }, machos = { 0 };
    collect(dir, "", &bundles, &machos);
    for (size_t i = 0; i < bundles.count; i++) {
        char sub[4096], ip[4096];
        path_join(sub, sizeof sub, dir, bundles.items[i]);
        path_join(ip, sizeof ip, sub, "Info.plist");
        if (!ends_with(sub, ".framework")) {
            pl_node *info = pl_parse_file(ip);
            if (info) {
                replace_prefix(info, old_main, new_main);
                pl_write_file(info, ip);
                pl_free(info);
            }
        }
        rename_nested(sub, old_main, new_main);
    }
    sl_free(&bundles);
    sl_free(&machos);
}

static void copy_provision(const char *dir, const uint8_t *prov, size_t len) {
    char p[4096];
    path_join(p, sizeof p, dir, "embedded.mobileprovision");
    sayo_write_file(p, prov, len);
    strlist bundles = { 0 }, machos = { 0 };
    collect(dir, "", &bundles, &machos);
    for (size_t i = 0; i < bundles.count; i++) {
        if (!ends_with(bundles.items[i], ".appex") && !ends_with(bundles.items[i], ".app")) continue;
        char sub[4096];
        path_join(sub, sizeof sub, dir, bundles.items[i]);
        copy_provision(sub, prov, len);
    }
    sl_free(&bundles);
    sl_free(&machos);
}

static void fix_substrate_refs(const char *bin) {
    strlist deps = { 0 };
    if (macho_list_dylibs(bin, &deps)) return;
    for (size_t i = 0; i < deps.count; i++) {
        for (int k = 0; SUBSTRATE_PATHS[k]; k++) {
            if (!strcmp(deps.items[i], SUBSTRATE_PATHS[k]) && strcmp(deps.items[i], HOOK_LOAD)) {
                macho_change_dylib(bin, deps.items[i], HOOK_LOAD);
                break;
            }
        }
    }
    sl_free(&deps);
}

static bool needs_hook(const char *bin) {
    strlist deps = { 0 };
    bool need = false;
    if (macho_list_dylibs(bin, &deps)) return false;
    for (size_t i = 0; i < deps.count && !need; i++)
        if (!strcmp(deps.items[i], HOOK_LOAD)) need = true;
    sl_free(&deps);
    return need;
}

static int inject(const char *app, const char *exe_path, const sayo_sign_options *o) {
    char fw[4096];
    path_join(fw, sizeof fw, app, "Frameworks");
    mkdirs(fw);
    bool hook = false;
    for (size_t i = 0; i < o->inject_count; i++) {
        const char *src = o->inject_paths[i];
        const char *base = strrchr(src, '/');
        base = base ? base + 1 : src;
        char dst[4096], load[2048];
        path_join(dst, sizeof dst, fw, base);
        rmtree(dst);
        if (copy_tree(src, dst)) return -1;
        char bin[4096];
        if (ends_with(base, ".framework")) {
            char ip[4096];
            path_join(ip, sizeof ip, dst, "Info.plist");
            pl_node *info = pl_parse_file(ip);
            const char *ex = info ? pl_get_str(info, "CFBundleExecutable") : NULL;
            char exn[1024];
            snprintf(exn, sizeof exn, "%s", ex ? ex : base);
            if (!ex) { char *d = strrchr(exn, '.'); if (d) *d = 0; }
            pl_free(info);
            path_join(bin, sizeof bin, dst, exn);
            snprintf(load, sizeof load, "@rpath/%s/%s", base, exn);
        } else {
            snprintf(bin, sizeof bin, "%s", dst);
            snprintf(load, sizeof load, "@rpath/%s", base);
        }
        if (!file_is_macho(bin)) { sayo_set_error("%s is not a Mach-O library", base); return -1; }
        fix_substrate_refs(bin);
        if (needs_hook(bin)) hook = true;
        if (macho_add_dylib(exe_path, load, false)) return -1;
    }
    if (hook || (o->inject_count && o->hook_framework_path)) {
        if (o->hook_framework_path) {
            char dst[4096];
            path_join(dst, sizeof dst, fw, "CydiaSubstrate.framework");
            rmtree(dst);
            if (copy_tree(o->hook_framework_path, dst)) return -1;
        } else if (hook) {
            sayo_set_error("tweak needs a hooking framework but none is bundled");
            return -1;
        }
    }
    if (o->inject_count) macho_add_rpath(exe_path, "@executable_path/Frameworks");
    return 0;
}

static void set_icon(const char *app, pl_node *info, const char *png) {
    char p[4096];
    path_join(p, sizeof p, app, "SayoIcon60x60@2x.png");
    copy_file(png, p);
    path_join(p, sizeof p, app, "SayoIcon60x60@3x.png");
    copy_file(png, p);
    path_join(p, sizeof p, app, "SayoIcon76x76@2x~ipad.png");
    copy_file(png, p);
    const char *keys[] = { "CFBundleIcons", "CFBundleIcons~ipad" };
    for (int k = 0; k < 2; k++) {
        pl_node *icons = pl_new(PL_DICT);
        pl_node *prim = pl_new(PL_DICT);
        pl_node *files = pl_new(PL_ARRAY);
        pl_push(files, pl_new_str(k ? "SayoIcon76x76" : "SayoIcon60x60"));
        if (k) pl_push(files, pl_new_str("SayoIcon60x60"));
        pl_set(prim, "CFBundleIconFiles", files);
        pl_set(prim, "CFBundleIconName", pl_new_str(""));
        pl_remove(prim, "CFBundleIconName");
        pl_set(icons, "CFBundlePrimaryIcon", prim);
        pl_set(info, keys[k], icons);
    }
    pl_remove(info, "CFBundleIconFile");
    pl_remove(info, "CFBundleIconFiles");
}

int sayo_sign_app(const char *app, const uint8_t *provision, size_t provision_len,
                  const sayo_identity *id, const sayo_sign_options *o,
                  sayo_progress_fn progress, void *pctx) {
    static const sayo_sign_options none = { 0 };
    if (!o) o = &none;
    sayo_buf px;
    if (sayo_provision_plist_xml(provision, provision_len, &px)) return -1;
    pl_node *prof = pl_parse(px.data, px.len);
    sayo_buf_free(&px);
    if (!prof) { sayo_set_error("cannot parse provisioning profile"); return -1; }
    pl_node *ents = pl_clone(pl_get(prof, "Entitlements"));
    pl_node *teams = pl_get(prof, "TeamIdentifier");
    char team[64] = "";
    if (teams && teams->type == PL_ARRAY && teams->count && teams->items[0]->type == PL_STRING)
        snprintf(team, sizeof team, "%s", teams->items[0]->str);
    pl_free(prof);
    if (!ents || !*team) { pl_free(ents); sayo_set_error("profile is missing entitlements or team"); return -1; }
    if (o->entitlements_xml_path) {
        pl_node *extra = pl_parse_file(o->entitlements_xml_path);
        if (extra && extra->type == PL_DICT) {
            for (size_t i = 0; i < extra->count; i++) pl_set(ents, extra->items[i]->key, pl_clone(extra->items[i]));
        }
        pl_free(extra);
    }
    const char *appid = pl_get_str(ents, "application-identifier");
    char prof_bid[512] = "";
    bool wildcard = true;
    if (appid) {
        const char *dot = strchr(appid, '.');
        if (dot) snprintf(prof_bid, sizeof prof_bid, "%s", dot + 1);
        wildcard = strchr(prof_bid, '*') != NULL;
    }

    if (progress) progress(pctx, 0.2, "prepare");
    char ip[4096];
    path_join(ip, sizeof ip, app, "Info.plist");
    pl_node *info = pl_parse_file(ip);
    if (!info) { pl_free(ents); return -1; }
    const char *old = pl_get_str(info, "CFBundleIdentifier");
    char old_bid[512];
    snprintf(old_bid, sizeof old_bid, "%s", old ? old : "");
    char new_bid[512];
    if (o->bundle_id && *o->bundle_id) snprintf(new_bid, sizeof new_bid, "%s", o->bundle_id);
    else snprintf(new_bid, sizeof new_bid, "%s", old_bid);
    /* Explicit profile: use its bundle ID unless the caller asked for one (e.g. the app's own). */
    if (!wildcard && *prof_bid && !(o->bundle_id && *o->bundle_id)) snprintf(new_bid, sizeof new_bid, "%s", prof_bid);
    else if (wildcard && strlen(prof_bid) > 1) {
        size_t pl = strlen(prof_bid) - 1;
        if (strncmp(new_bid, prof_bid, pl)) {
            char nb[512];
            snprintf(nb, sizeof nb, "%.*s%s", (int)pl, prof_bid, new_bid);
            snprintf(new_bid, sizeof new_bid, "%s", nb);
        }
    }
    pl_set(info, "CFBundleIdentifier", pl_new_str(new_bid));
    if (o->display_name && *o->display_name) {
        pl_set(info, "CFBundleDisplayName", pl_new_str(o->display_name));
        pl_set(info, "CFBundleName", pl_new_str(o->display_name));
    }
    if (o->version && *o->version) pl_set(info, "CFBundleVersion", pl_new_str(o->version));
    if (o->short_version && *o->short_version) pl_set(info, "CFBundleShortVersionString", pl_new_str(o->short_version));
    if (o->file_sharing) {
        pl_node *t = pl_new(PL_BOOL); t->i = 1;
        pl_set(info, "UIFileSharingEnabled", t);
        t = pl_new(PL_BOOL); t->i = 1;
        pl_set(info, "LSSupportsOpeningDocumentsInPlace", t);
    }
    if (o->remove_url_schemes) pl_remove(info, "CFBundleURLTypes");
    if (o->min_ios && *o->min_ios) pl_set(info, "MinimumOSVersion", pl_new_str(o->min_ios));
    pl_remove(info, "UISupportedDevices");
    if (o->icon_png_path && *o->icon_png_path) set_icon(app, info, o->icon_png_path);
    const char *exe = pl_get_str(info, "CFBundleExecutable");
    char exe_path[4096];
    path_join(exe_path, sizeof exe_path, app, exe ? exe : "");
    if (pl_write_file(info, ip)) { pl_free(info); pl_free(ents); return -1; }
    pl_free(info);

    char pp[4096];
    path_join(pp, sizeof pp, app, "PlugIns");
    if (o->remove_plugins || (!wildcard && is_dir(pp))) {
        rmtree(pp);
        path_join(pp, sizeof pp, app, "Extensions");
        rmtree(pp);
    }
    if (o->remove_watch || !wildcard) {
        path_join(pp, sizeof pp, app, "Watch");
        rmtree(pp);
    }
    path_join(pp, sizeof pp, app, "SC_Info");
    rmtree(pp);
    if (strcmp(old_bid, new_bid)) rename_nested(app, old_bid, new_bid);

    if (o->inject_count || o->hook_framework_path) {
        if (progress) progress(pctx, 0.25, "inject");
        if (o->inject_count && inject(app, exe_path, o)) { pl_free(ents); return -1; }
    }

    copy_provision(app, provision, provision_len);
    sctx c = { ents, team, id, progress, pctx, 0, count_macho(app) };
    int rc = sign_bundle(&c, app, true);
    pl_free(ents);
    if (progress && rc == 0) progress(pctx, 0.9, "sign");
    return rc;
}

static int find_app(const char *payload, char *out, size_t cap) {
    DIR *d = opendir(payload);
    if (!d) { sayo_set_error("IPA has no Payload folder"); return -1; }
    struct dirent *e;
    int rc = -1;
    while ((e = readdir(d))) {
        if (ends_with(e->d_name, ".app")) {
            path_join(out, cap, payload, e->d_name);
            rc = 0;
            break;
        }
    }
    closedir(d);
    if (rc) sayo_set_error("no .app inside Payload");
    return rc;
}

typedef struct {
    sayo_progress_fn fn;
    void *ctx;
    double base, span;
} sub_progress;

static void sub_cb(void *v, double f, const char *stage) {
    sub_progress *s = v;
    if (s->fn) s->fn(s->ctx, s->base + s->span * f, stage);
}

int sayo_sign_ipa(const char *ipa_in, const char *ipa_out, const char *work,
                  const uint8_t *provision, size_t provision_len,
                  const sayo_identity *id, const sayo_sign_options *o,
                  sayo_progress_fn progress, void *pctx) {
    rmtree(work);
    if (mkdirs(work)) return -1;
    sub_progress sp = { progress, pctx, 0.0, 0.2 };
    if (sayo_unzip(ipa_in, work, sub_cb, &sp)) return -1;
    char payload[4096], app[4096];
    path_join(payload, sizeof payload, work, "Payload");
    if (find_app(payload, app, sizeof app)) return -1;
    if (sayo_sign_app(app, provision, provision_len, id, o, progress, pctx)) return -1;
    char pk[4096];
    snprintf(pk, sizeof pk, "%s.pack", work);
    rmtree(pk);
    mkdirs(pk);
    char dst[4096];
    path_join(dst, sizeof dst, pk, "Payload");
    if (rename(payload, dst)) { sayo_set_error("cannot move Payload"); return -1; }
    sub_progress zp = { progress, pctx, 0.9, 0.1 };
    int level = o ? o->compression_level : 6;
    if (level < 0 || level > 9) level = 6;
    int rc = sayo_zip_dir(pk, ipa_out, level, sub_cb, &zp);
    rmtree(pk);
    rmtree(work);
    return rc;
}

int sayo_macho_inject(const char *binary, const char *load_path, int weak) {
    return macho_add_dylib(binary, load_path, weak != 0);
}
