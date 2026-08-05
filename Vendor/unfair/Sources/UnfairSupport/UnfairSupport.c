#include "UnfairSupport.h"

#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#define UNFAIR_CS_PLATFORM_BINARY 0x04000000u

typedef int (*jbclient_initialize_primitives_fn)(void);
typedef uint64_t (*proc_find_fn)(int);
typedef int (*proc_rele_fn)(uint64_t);
typedef int (*proc_csflags_set_fn)(uint64_t, uint32_t);

static void set_error(char *error, size_t error_size, const char *format, ...) {
    if (error == NULL || error_size == 0) {
        return;
    }

    va_list args;
    va_start(args, format);
    vsnprintf(error, error_size, format, args);
    va_end(args);
}

static void *open_libjailbreak(char *error, size_t error_size) {
    if (dlsym(RTLD_DEFAULT, "jbclient_initialize_primitives") != NULL) {
        return RTLD_DEFAULT;
    }

    // Roothide assigns a randomized jailbreak root on each device, and unfaird
    // publishes the resolved prefix through its launchd environment.
    const char *prefix = getenv("UNFAIRD_JB_PREFIX");
    if (prefix != NULL && prefix[0] != '\0') {
        const char *suffixes[] = {
            "/basebin/libjailbreak.dylib",
            "/usr/lib/libjailbreak.dylib",
        };
        for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++) {
            char path[PATH_MAX];
            int written = snprintf(path, sizeof(path), "%s%s", prefix, suffixes[i]);
            if (written <= 0 || (size_t)written >= sizeof(path)) {
                continue;
            }
            void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
            if (handle != NULL) {
                return handle;
            }
        }
    }

    const char *paths[] = {
        "libjailbreak.dylib",
        "/var/jb/usr/lib/libjailbreak.dylib",
        "/var/jb/basebin/libjailbreak.dylib",
        "/basebin/libjailbreak.dylib",
    };

    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *handle = dlopen(paths[i], RTLD_NOW);
        if (handle != NULL) {
            return handle;
        }
    }

    set_error(error, error_size, "dlopen libjailbreak failed: %s", dlerror());
    return NULL;
}

static void *required_symbol(void *handle, const char *name, char *error, size_t error_size) {
    void *symbol = dlsym(handle, name);
    if (symbol == NULL) {
        set_error(error, error_size, "dlsym %s failed: %s", name, dlerror());
    }
    return symbol;
}

int unfair_prepare_app_bundle_decryption(char *error, size_t error_size) {
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    static int prepared = 0;
    if (prepared) {
        return 0;
    }

    if (geteuid() != 0) {
        set_error(error, error_size, "root privileges required for jailbreak primitives");
        return -1;
    }

    void *handle = open_libjailbreak(error, error_size);
    if (handle == NULL) {
        return -1;
    }

    jbclient_initialize_primitives_fn jbclient_initialize_primitives =
        (jbclient_initialize_primitives_fn)required_symbol(handle, "jbclient_initialize_primitives", error, error_size);
    proc_find_fn proc_find =
        (proc_find_fn)required_symbol(handle, "proc_find", error, error_size);
    proc_rele_fn proc_rele =
        (proc_rele_fn)required_symbol(handle, "proc_rele", error, error_size);
    proc_csflags_set_fn proc_csflags_set =
        (proc_csflags_set_fn)required_symbol(handle, "proc_csflags_set", error, error_size);

    if (jbclient_initialize_primitives == NULL ||
        proc_find == NULL ||
        proc_rele == NULL ||
        proc_csflags_set == NULL) {
        return -1;
    }

    if (jbclient_initialize_primitives() != 0) {
        set_error(error, error_size, "jbclient_initialize_primitives failed");
        return -1;
    }

    uint64_t proc = proc_find(getpid());
    if (proc == 0) {
        set_error(error, error_size, "proc_find(%d) failed", getpid());
        return -1;
    }

    int status = proc_csflags_set(proc, UNFAIR_CS_PLATFORM_BINARY);
    proc_rele(proc);
    if (status != 0) {
        set_error(error, error_size, "proc_csflags_set failed: %d", status);
        return -1;
    }
    prepared = 1;
    return 0;
#else
    (void)error;
    (void)error_size;
    return 0;
#endif
}
