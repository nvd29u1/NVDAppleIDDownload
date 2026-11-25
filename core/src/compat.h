#pragma once
/* Small POSIX shims so the engine builds with MinGW on Windows. */
#ifdef _WIN32
#include <direct.h>
#include <errno.h>
#include <io.h>
#include <sys/stat.h>
#include <sys/types.h>
#define mkdir(path, mode) _mkdir(path)
#define lstat stat
#ifndef S_ISLNK
#define S_ISLNK(m) 0
#endif
/* Windows bundles have no symlinks; pretend success so unzip keeps going. */
static inline int symlink(const char *target, const char *path) { (void)target; (void)path; return 0; }
static inline long readlink(const char *path, char *buf, size_t n) { (void)path; (void)buf; (void)n; errno = EINVAL; return -1; }
#include <time.h>
static inline struct tm *gmtime_r(const time_t *t, struct tm *out) { return gmtime_s(out, t) ? NULL : out; }
#define timegm _mkgmtime
#endif

#include <stdlib.h>
/* Directory for temporary files: $TMPDIR, %TEMP% or /tmp. */
static inline const char *sayo_tmp_dir(void) {
    const char *t = getenv("TMPDIR");
    if (!t || !*t) t = getenv("TEMP");
    if (!t || !*t) t = getenv("TMP");
    return (t && *t) ? t : "/tmp";
}
