#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>

#define EXPORT __attribute__((visibility("default")))

typedef const void *MSImageRef;

typedef struct {
    void *target;
    void *replacement;
    char name[256];
} rebind_entry;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static rebind_entry *g_rebinds;
static size_t g_rebind_count;
static bool g_dyld_registered;

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000

static bool can_patch_text(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags) != 0) return false;
    return (flags & CS_DEBUGGED) != 0;
}


static bool make_writable(void *addr, size_t len) {
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(PAGE_SIZE - 1);
    vm_size_t size = ((vm_address_t)addr + len) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, size, false, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) kr = vm_protect(mach_task_self(), page, size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return kr == KERN_SUCCESS;
}

static void rebind_image(const struct mach_header_64 *mh, intptr_t slide, const rebind_entry *entries, size_t count, void **orig_out) {
    if (mh->magic != MH_MAGIC_64) return;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const uint8_t *cmd = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT)) linkedit = (const struct segment_command_64 *)lc;
        else if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)lc;
        cmd += lc->cmdsize;
    }
    uintptr_t le_base = linkedit ? (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff : 0;
    const struct nlist_64 *syms = symtab && linkedit ? (const struct nlist_64 *)(le_base + symtab->symoff) : NULL;
    const char *strs = symtab && linkedit ? (const char *)(le_base + symtab->stroff) : NULL;
    const uint32_t *indirect = dysymtab && linkedit ? (const uint32_t *)(le_base + dysymtab->indirectsymoff) : NULL;

    cmd = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        cmd += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strncmp(seg->segname, "__DATA", 6) && strncmp(seg->segname, "__AUTH", 6)) continue;
        const struct section_64 *sec = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sec++) {
            uint32_t type = sec->flags & SECTION_TYPE;
            bool ptrsec = type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS ||
                          !strncmp(sec->sectname, "__got", 16) || !strncmp(sec->sectname, "__auth_got", 16) ||
                          !strncmp(sec->sectname, "__la_symbol_ptr", 16);
            if (!ptrsec) continue;
            void **ptrs = (void **)((uintptr_t)slide + sec->addr);
            size_t n = sec->size / sizeof(void *);
            for (size_t k = 0; k < n; k++) {
                const char *sname = NULL;
                if (indirect && syms && strs && (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)) {
                    uint32_t idx = indirect[sec->reserved1 + k];
                    if (!(idx & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL))) {
                        uint32_t sx = syms[idx].n_un.n_strx;
                        sname = strs + sx;
                    }
                }
                void *cur = ptrs[k];
                for (size_t e = 0; e < count; e++) {
                    bool hit = cur == entries[e].target && cur;
                    if (!hit && sname && entries[e].name[0] && sname[0] == '_' && !strcmp(sname + 1, entries[e].name)) hit = true;
                    if (!hit || cur == entries[e].replacement) continue;
                    if (orig_out && !orig_out[e] && cur != entries[e].target) orig_out[e] = entries[e].target;
                    if (make_writable(&ptrs[k], sizeof(void *))) ptrs[k] = entries[e].replacement;
                }
            }
        }
    }
}

static void on_add_image(const struct mach_header *mh, intptr_t slide) {
    pthread_mutex_lock(&g_lock);
    if (g_rebind_count) rebind_image((const struct mach_header_64 *)mh, slide, g_rebinds, g_rebind_count, NULL);
    pthread_mutex_unlock(&g_lock);
}

static bool rebind_hook(void *target, void *replacement) {
    Dl_info info;
    char name[256] = "";
    if (dladdr(target, &info) && info.dli_sname && info.dli_saddr == target) {
        strncpy(name, info.dli_sname, sizeof name - 1);
    }
    pthread_mutex_lock(&g_lock);
    rebind_entry *n = realloc(g_rebinds, (g_rebind_count + 1) * sizeof *n);
    if (!n) { pthread_mutex_unlock(&g_lock); return false; }
    g_rebinds = n;
    rebind_entry *e = &g_rebinds[g_rebind_count++];
    e->target = target;
    e->replacement = replacement;
    memcpy(e->name, name, sizeof e->name);
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++)
        rebind_image((const struct mach_header_64 *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), e, 1, NULL);
    bool reg = !g_dyld_registered;
    g_dyld_registered = true;
    pthread_mutex_unlock(&g_lock);
    if (reg) _dyld_register_func_for_add_image(on_add_image);
    return true;
}

#if defined(__arm64__) || defined(__aarch64__)

static uint32_t *emit_abs_load(uint32_t *p, int reg, uint64_t value) {
    *p++ = 0x58000040 | (uint32_t)reg;
    *p++ = 0x14000003;
    memcpy(p, &value, 8);
    return p + 2;
}

static uint32_t *emit_abs_jump(uint32_t *p, uint64_t target, bool link) {
    p = emit_abs_load(p, 17, target);
    *p++ = link ? 0xd63f0220 : 0xd61f0220;
    return p;
}

static int64_t sext(uint64_t v, int bits) {
    uint64_t m = 1ull << (bits - 1);
    return (int64_t)((v ^ m) - m);
}

static uint32_t *relocate(uint32_t *out, uint32_t ins, uint64_t pc) {
    if ((ins & 0x7c000000) == 0x14000000) {
        uint64_t t = pc + (uint64_t)(sext(ins & 0x3ffffff, 26) << 2);
        return emit_abs_jump(out, t, (ins & 0x80000000) != 0);
    }
    if ((ins & 0xff000010) == 0x54000000) {
        uint64_t t = pc + (uint64_t)(sext((ins >> 5) & 0x7ffff, 19) << 2);
        *out++ = (ins & 0xff00001f) | (2 << 5);
        *out++ = 0x14000005;
        return emit_abs_jump(out, t, false);
    }
    if ((ins & 0x7e000000) == 0x34000000) {
        uint64_t t = pc + (uint64_t)(sext((ins >> 5) & 0x7ffff, 19) << 2);
        *out++ = (ins & 0xff00001f) | (2 << 5);
        *out++ = 0x14000005;
        return emit_abs_jump(out, t, false);
    }
    if ((ins & 0x7e000000) == 0x36000000) {
        uint64_t t = pc + (uint64_t)(sext((ins >> 5) & 0x3fff, 14) << 2);
        *out++ = (ins & 0xfff8001f) | (2 << 5);
        *out++ = 0x14000005;
        return emit_abs_jump(out, t, false);
    }
    if ((ins & 0x9f000000) == 0x10000000) {
        int rd = ins & 0x1f;
        uint64_t imm = ((uint64_t)((ins >> 5) & 0x7ffff) << 2) | ((ins >> 29) & 3);
        return emit_abs_load(out, rd, pc + (uint64_t)sext(imm, 21));
    }
    if ((ins & 0x9f000000) == 0x90000000) {
        int rd = ins & 0x1f;
        uint64_t imm = ((uint64_t)((ins >> 5) & 0x7ffff) << 2) | ((ins >> 29) & 3);
        return emit_abs_load(out, rd, (pc & ~0xfffull) + (uint64_t)(sext(imm, 21) << 12));
    }
    if ((ins & 0x3b000000) == 0x18000000) {
        uint64_t addr = pc + (uint64_t)(sext((ins >> 5) & 0x7ffff, 19) << 2);
        int rt = ins & 0x1f;
        uint32_t opc = ins >> 30;
        bool simd = (ins >> 26) & 1;
        out = emit_abs_load(out, 17, addr);
        if (!simd) {
            if (opc == 0) *out++ = 0xb9400220 | (uint32_t)rt;
            else if (opc == 1) *out++ = 0xf9400220 | (uint32_t)rt;
            else if (opc == 2) *out++ = 0xb9800220 | (uint32_t)rt;
            else *out++ = 0xd503201f;
        } else {
            if (opc == 0) *out++ = 0xbd400220 | (uint32_t)rt;
            else if (opc == 1) *out++ = 0xfd400220 | (uint32_t)rt;
            else *out++ = 0x3dc00220 | (uint32_t)rt;
        }
        return out;
    }
    *out++ = ins;
    return out;
}

static bool inline_hook(void *target, void *replacement, void **orig) {
    uint32_t *code = (uint32_t *)target;
    size_t tramp_size = 4 * 64;
    void *tramp = mmap(NULL, tramp_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (tramp == MAP_FAILED) return false;
    uint32_t *t = tramp;
    for (int i = 0; i < 4; i++) t = relocate(t, code[i], (uint64_t)(uintptr_t)(code + i));
    t = emit_abs_jump(t, (uint64_t)(uintptr_t)(code + 4), false);
    if (mprotect(tramp, tramp_size, PROT_READ | PROT_EXEC)) { munmap(tramp, tramp_size); return false; }
    sys_icache_invalidate(tramp, tramp_size);
    uint32_t patch[4];
    patch[0] = 0x58000051;
    patch[1] = 0xd61f0220;
    uint64_t dst = (uint64_t)(uintptr_t)replacement;
    memcpy(&patch[2], &dst, 8);
    vm_address_t page = (vm_address_t)target & ~(vm_address_t)(PAGE_SIZE - 1);
    vm_size_t len = (vm_address_t)target + sizeof patch - page;
    if (vm_protect(mach_task_self(), page, len, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        munmap(tramp, tramp_size);
        return false;
    }
    memcpy(target, patch, sizeof patch);
    vm_protect(mach_task_self(), page, len, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(target, sizeof patch);
    if (orig) *orig = tramp;
    return true;
}
#else
static bool inline_hook(void *target, void *replacement, void **orig) { return false; }
#endif

static bool hook_function(void *symbol, void *replace, void **result) {
    if (!symbol || !replace) return false;
    if (result) *result = symbol;
    if (can_patch_text() && inline_hook(symbol, replace, result)) return true;
    return rebind_hook(symbol, replace);
}

EXPORT void MSHookFunction(void *symbol, void *replace, void **result) {
    hook_function(symbol, replace, result);
}

EXPORT void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result) {
    if (!cls || !sel || !imp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        if (result) *result = NULL;
        return;
    }
    unsigned int n = 0;
    Method *own = class_copyMethodList(cls, &n);
    bool direct = false;
    for (unsigned int i = 0; i < n; i++) if (own[i] == m) { direct = true; break; }
    free(own);
    if (direct) {
        IMP old = method_setImplementation(m, imp);
        if (result) *result = old;
    } else {
        IMP super_imp = method_getImplementation(m);
        if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) {
            IMP old = class_replaceMethod(cls, sel, imp, method_getTypeEncoding(m));
            if (result) *result = old ? old : super_imp;
            return;
        }
        if (result) *result = super_imp;
    }
}

EXPORT void MSHookMessage(Class cls, SEL sel, IMP imp, const char *prefix) {
    MSHookMessageEx(cls, sel, imp, NULL);
}

EXPORT MSImageRef MSGetImageByName(const char *file) {
    if (!file) return NULL;
    uint32_t n = _dyld_image_count();
    const char *base = strrchr(file, '/');
    base = base ? base + 1 : file;
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (!strcmp(name, file)) return _dyld_get_image_header(i);
    }
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *b = strrchr(name, '/');
        b = b ? b + 1 : name;
        if (!strcmp(b, base)) return _dyld_get_image_header(i);
    }
    void *h = dlopen(file, RTLD_LAZY | RTLD_NOLOAD);
    if (!h) return NULL;
    n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, base)) return _dyld_get_image_header(i);
    }
    return NULL;
}

static void *find_in_image(const struct mach_header_64 *mh, intptr_t slide, const char *name) {
    if (mh->magic != MH_MAGIC_64) return NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const uint8_t *cmd = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT)) linkedit = (const struct segment_command_64 *)lc;
        else if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        cmd += lc->cmdsize;
    }
    if (!linkedit || !symtab) return NULL;
    uintptr_t le_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const struct nlist_64 *)(le_base + symtab->symoff);
    const char *strs = (const char *)(le_base + symtab->stroff);
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        if ((syms[i].n_type & N_TYPE) != N_SECT || !syms[i].n_value) continue;
        if (!strcmp(strs + syms[i].n_un.n_strx, name)) return (void *)(syms[i].n_value + (uintptr_t)slide);
    }
    return NULL;
}

EXPORT void *MSFindSymbol(MSImageRef image, const char *name) {
    if (!name) return NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (image && (const void *)mh != image) continue;
        void *p = find_in_image((const struct mach_header_64 *)mh, _dyld_get_image_vmaddr_slide(i), name);
        if (p) return p;
    }
    if (name[0] == '_') return dlsym(RTLD_DEFAULT, name + 1);
    return dlsym(RTLD_DEFAULT, name);
}

EXPORT void MSHookMemory(void *target, const void *data, size_t size) {
    vm_address_t page = (vm_address_t)target & ~(vm_address_t)(PAGE_SIZE - 1);
    vm_size_t len = (vm_address_t)target + size - page;
    if (vm_protect(mach_task_self(), page, len, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
    memcpy(target, data, size);
    vm_protect(mach_task_self(), page, len, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(target, size);
}

EXPORT void MSHookClassPair(Class target, Class hook, Class old) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(hook, &n);
    for (unsigned int i = 0; i < n; i++) {
        IMP orig = NULL;
        MSHookMessageEx(target, method_getName(ms[i]), method_getImplementation(ms[i]), &orig);
        if (old && orig) class_addMethod(old, method_getName(ms[i]), orig, method_getTypeEncoding(ms[i]));
    }
    free(ms);
}

struct LHFunctionHookOptions {
    int options;
    void *jmp_reg;
};

struct LHFunctionHook {
    void *function;
    void *replacement;
    void *oldptr;
    struct LHFunctionHookOptions *options;
};

struct libhooker_image {
    const void *imageHeader;
    uintptr_t slide;
    void *dyldHandle;
};

EXPORT int LHHookFunctions(const struct LHFunctionHook *hooks, int count) {
    int ok = 0;
    for (int i = 0; i < count; i++) {
        if (hook_function(hooks[i].function, hooks[i].replacement, (void **)hooks[i].oldptr)) ok++;
    }
    return ok;
}

EXPORT int LBHookMessage(Class cls, SEL sel, void *replacement, void *old_ptr) {
    if (!class_getInstanceMethod(cls, sel)) return 2;
    MSHookMessageEx(cls, sel, (IMP)replacement, (IMP *)old_ptr);
    return 0;
}

EXPORT const char *LHStrError(int err) {
    switch (err) {
    case 0: return "No errors took place";
    case 1: return "An Objective-C selector was not found";
    case 2: return "A function was too short to hook";
    case 3: return "A problematic instruction was found";
    case 4: return "Unable to modify memory";
    case 5: return "Unable to allocate memory";
    case 6: return "dlopen failed";
    case 7: return "dlsym failed";
    default: return "Unknown error";
    }
}

EXPORT struct libhooker_image *LHOpenImage(const char *path) {
    MSImageRef h = MSGetImageByName(path);
    if (!h) {
        dlopen(path, RTLD_LAZY);
        h = MSGetImageByName(path);
    }
    if (!h) return NULL;
    struct libhooker_image *img = calloc(1, sizeof *img);
    img->imageHeader = h;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++)
        if ((const void *)_dyld_get_image_header(i) == h) img->slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
    return img;
}

EXPORT void LHCloseImage(struct libhooker_image *img) { free(img); }

EXPORT bool LHFindSymbols(struct libhooker_image *img, const char **names, void **out, size_t count) {
    bool all = true;
    for (size_t i = 0; i < count; i++) {
        out[i] = MSFindSymbol(img ? img->imageHeader : NULL, names[i]);
        if (!out[i]) all = false;
    }
    return all;
}

EXPORT int LHPatchMemory(const void *patches, int count) { return 0; }

EXPORT void *LHExecMemory(void *page, void *data, size_t size) { return NULL; }

struct substitute_function_hook {
    void *function;
    void *replacement;
    void *old_ptr;
    int options;
};

EXPORT int substitute_hook_functions(const struct substitute_function_hook *hooks, size_t nhooks, void *recordp, int options) {
    for (size_t i = 0; i < nhooks; i++) hook_function(hooks[i].function, hooks[i].replacement, (void **)hooks[i].old_ptr);
    return 0;
}

EXPORT int substitute_hook_objc_message(Class cls, SEL sel, void *replacement, void *old_ptr, bool *created) {
    MSHookMessageEx(cls, sel, (IMP)replacement, (IMP *)old_ptr);
    if (created) *created = false;
    return 0;
}

EXPORT const void *substitute_open_image(const char *filename) { return MSGetImageByName(filename); }
EXPORT void substitute_close_image(const void *handle) {}
EXPORT int substitute_find_private_syms(const void *handle, const char **names, void **syms, size_t nsyms) {
    for (size_t i = 0; i < nsyms; i++) syms[i] = MSFindSymbol(handle, names[i]);
    return 0;
}
