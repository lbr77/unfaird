#include "UnfairDaemonSupport.h"

#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#include <xpc/xpc.h>

#define UNFAIRD_CS_PLATFORM_BINARY UINT32_C(0x04000000)

typedef int (*set_mac_label_fn)(uint64_t, uint64_t, uint64_t *);
typedef int (*steal_ucred_fn)(uint64_t, uint64_t *);
typedef uint64_t (*proc_find_fn)(int);
typedef uint64_t (*proc_task_fn)(uint64_t);
typedef int (*proc_rele_fn)(uint64_t);
typedef int (*proc_csflags_set_fn)(uint64_t, uint32_t);
typedef int (*cs_allow_invalid_fn)(uint64_t, bool);
typedef uint64_t (*kread_ptr_fn)(uint64_t);
typedef uint32_t (*kread32_fn)(uint64_t);
typedef uint64_t (*kread64_fn)(uint64_t);
typedef int (*kwrite64_fn)(uint64_t, uint64_t);
typedef xpc_object_t (*get_system_info_fn)(void);

struct unfaird_kernel_api {
    set_mac_label_fn set_mac_label;
    steal_ucred_fn steal_ucred;
    proc_find_fn proc_find;
    proc_task_fn proc_task;
    proc_rele_fn proc_rele;
    kread_ptr_fn kread_ptr;
    kread32_fn kread32;
    kread64_fn kread64;
    kwrite64_fn kwrite64;
};

struct unfaird_offsets {
    uint64_t task_map;
    uint64_t vm_map_hdr;
    uint64_t header_links;
    uint64_t header_nentries;
    uint64_t entry_links;
    uint64_t entry_flags;
    uint64_t flags_prot;
    uint64_t flags_maxprot;
    uint64_t flags_user_debug;
    uint64_t links_next;
    uint64_t links_min;
    uint64_t links_max;
    bool has_user_debug;
};

struct unfaird_vm_entry {
    uint64_t address;
    uint64_t flags;
};

struct unfaird_active_mapping {
    void *address;
    size_t size;
    uint64_t original_flags;
    uint64_t original_ucred;
    uint64_t kernel_sandbox_label;
    bool borrowed_kernel_ucred;
    bool active;
};

static pthread_mutex_t unfaird_prepare_lock = PTHREAD_MUTEX_INITIALIZER;
static bool unfaird_prepared;
static struct unfaird_kernel_api unfaird_kernel;
static struct unfaird_offsets unfaird_offsets;
static _Thread_local bool unfaird_promotion_enabled;
static _Thread_local char unfaird_mapping_error[512];
static _Thread_local struct unfaird_active_mapping unfaird_active_mapping;

static void unfaird_trace(const char *stage) {
    if (getenv("UNFAIRD_MAPPING_TRACE") != NULL) {
        dprintf(STDERR_FILENO, "unfaird-mapping stage=%s\n", stage);
    }
}

static void unfaird_write_error(char *buffer, size_t size, const char *format, ...) {
    if (buffer == NULL || size == 0) {
        return;
    }

    va_list arguments;
    va_start(arguments, format);
    vsnprintf(buffer, size, format, arguments);
    va_end(arguments);
}

static void unfaird_record_mapping_error(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(unfaird_mapping_error, sizeof(unfaird_mapping_error), format, arguments);
    va_end(arguments);
}

static void *unfaird_open_libjailbreak(char *error, size_t error_size) {
    if (dlsym(RTLD_DEFAULT, "jbclient_initialize_primitives") != NULL) {
        return RTLD_DEFAULT;
    }

    const char *paths[] = {
        "/private/var/tmp/libjailbreak.dylib",
        "/var/jb/basebin/libjailbreak.dylib",
        "/var/jb/usr/lib/libjailbreak.dylib",
        "/basebin/libjailbreak.dylib",
    };
    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
        void *handle = dlopen(paths[index], RTLD_NOW | RTLD_LOCAL);
        if (handle != NULL) {
            return handle;
        }
    }

    unfaird_write_error(error, error_size, "dlopen libjailbreak failed: %s", dlerror());
    return NULL;
}

static void *unfaird_symbol(void *handle, const char *name, char *error, size_t error_size) {
    void *symbol = dlsym(handle, name);
    if (symbol == NULL) {
        unfaird_write_error(error, error_size, "dlsym %s failed: %s", name, dlerror());
    }
    return symbol;
}

static bool unfaird_read_offset(
    xpc_object_t dictionary,
    const char *key,
    uint64_t *value,
    char *error,
    size_t error_size
) {
    xpc_object_t object = xpc_dictionary_get_value(dictionary, key);
    if (object == NULL || xpc_get_type(object) != XPC_TYPE_UINT64) {
        unfaird_write_error(error, error_size, "kernel offset missing: %s", key);
        return false;
    }
    *value = xpc_uint64_get_value(object);
    return true;
}

static bool unfaird_get_offset(xpc_object_t dictionary, const char *key, uint64_t *value) {
    xpc_object_t object = xpc_dictionary_get_value(dictionary, key);
    if (object == NULL || xpc_get_type(object) != XPC_TYPE_UINT64) {
        return false;
    }
    *value = xpc_uint64_get_value(object);
    return true;
}

#define UNFAIRD_READ_OFFSET(dictionary, field, key) \
    do { \
        if (!unfaird_read_offset(dictionary, key, &unfaird_offsets.field, error, error_size)) { \
            xpc_release(dictionary); \
            return -1; \
        } \
    } while (0)

static int unfaird_load_offsets(get_system_info_fn get_system_info, char *error, size_t error_size) {
    xpc_object_t system_info = get_system_info();
    if (system_info == NULL || xpc_get_type(system_info) != XPC_TYPE_DICTIONARY) {
        unfaird_write_error(error, error_size, "jbinfo_get_serialized returned invalid data");
        return -1;
    }
    UNFAIRD_READ_OFFSET(system_info, task_map, "kernelStruct.task.map");
    UNFAIRD_READ_OFFSET(system_info, vm_map_hdr, "kernelStruct.vm_map.hdr");
    UNFAIRD_READ_OFFSET(system_info, header_links, "kernelStruct.vm_map_header.links");
    UNFAIRD_READ_OFFSET(system_info, header_nentries, "kernelStruct.vm_map_header.nentries");
    UNFAIRD_READ_OFFSET(system_info, entry_links, "kernelStruct.vm_map_entry.links");
    UNFAIRD_READ_OFFSET(system_info, entry_flags, "kernelStruct.vm_map_entry.flags");
    UNFAIRD_READ_OFFSET(system_info, links_next, "kernelStruct.vm_map_links.next");
    UNFAIRD_READ_OFFSET(system_info, links_min, "kernelStruct.vm_map_links.min");
    UNFAIRD_READ_OFFSET(system_info, links_max, "kernelStruct.vm_map_links.max");

    bool has_protection = unfaird_get_offset(
        system_info,
        "kernelStruct.vm_map_entry.flags_prot",
        &unfaird_offsets.flags_prot);
    bool has_max_protection = unfaird_get_offset(
        system_info,
        "kernelStruct.vm_map_entry.flags_maxprot",
        &unfaird_offsets.flags_maxprot);
    unfaird_offsets.has_user_debug = unfaird_get_offset(
        system_info,
        "kernelStruct.vm_map_entry.flags_xnu_user_debug",
        &unfaird_offsets.flags_user_debug);

    if (!has_protection && !has_max_protection && !unfaird_offsets.has_user_debug &&
        unfaird_offsets.task_map == 40 &&
        unfaird_offsets.entry_flags == 72) {
        // XNU 8020 stores protection at bit 7 and max_protection at bit 11.
        // Its corresponding later user-debug bit is still reserved.
        unfaird_offsets.flags_prot = 7;
        unfaird_offsets.flags_maxprot = 11;
        unfaird_trace("prepare.offsets-xnu8020");
    } else if (!has_protection || !has_max_protection || !unfaird_offsets.has_user_debug) {
        unfaird_write_error(error, error_size, "kernel VM-entry flag layout is incomplete");
        xpc_release(system_info);
        return -1;
    }
    xpc_release(system_info);
    return 0;
}

static int unfaird_prepare_locked(char *error, size_t error_size) {
    unfaird_trace("prepare.begin");
    if (geteuid() != 0) {
        unfaird_write_error(error, error_size, "root privileges required for kernel mapping promotion");
        return -1;
    }

    void *handle = unfaird_open_libjailbreak(error, error_size);
    if (handle == NULL) {
        return -1;
    }

    unfaird_kernel.set_mac_label =
        (set_mac_label_fn)unfaird_symbol(handle, "jbclient_root_set_mac_label", error, error_size);
    unfaird_kernel.steal_ucred =
        (steal_ucred_fn)unfaird_symbol(handle, "jbclient_root_steal_ucred", error, error_size);
    proc_csflags_set_fn set_csflags =
        (proc_csflags_set_fn)unfaird_symbol(handle, "proc_csflags_set", error, error_size);
    cs_allow_invalid_fn allow_invalid =
        (cs_allow_invalid_fn)unfaird_symbol(handle, "cs_allow_invalid", error, error_size);
    get_system_info_fn get_system_info =
        (get_system_info_fn)unfaird_symbol(handle, "jbinfo_get_serialized", error, error_size);

    unfaird_kernel.proc_find = (proc_find_fn)unfaird_symbol(handle, "proc_find", error, error_size);
    unfaird_kernel.proc_task = (proc_task_fn)unfaird_symbol(handle, "proc_task", error, error_size);
    unfaird_kernel.proc_rele = (proc_rele_fn)unfaird_symbol(handle, "proc_rele", error, error_size);
    unfaird_kernel.kread_ptr = (kread_ptr_fn)unfaird_symbol(handle, "kread_ptr", error, error_size);
    unfaird_kernel.kread32 = (kread32_fn)unfaird_symbol(handle, "kread32", error, error_size);
    unfaird_kernel.kread64 = (kread64_fn)unfaird_symbol(handle, "kread64", error, error_size);
    unfaird_kernel.kwrite64 = (kwrite64_fn)unfaird_symbol(handle, "kwrite64", error, error_size);

    if (unfaird_kernel.set_mac_label == NULL || unfaird_kernel.steal_ucred == NULL ||
        set_csflags == NULL || allow_invalid == NULL ||
        get_system_info == NULL ||
        unfaird_kernel.proc_find == NULL || unfaird_kernel.proc_task == NULL ||
        unfaird_kernel.proc_rele == NULL || unfaird_kernel.kread_ptr == NULL ||
        unfaird_kernel.kread32 == NULL || unfaird_kernel.kread64 == NULL ||
        unfaird_kernel.kwrite64 == NULL) {
        return -1;
    }

    // UnfairKit prepares the process before registering the code signature.
    // Reuse those primitives because legacy physrw receivers are single-owner.
    int status = 0;
    unfaird_trace("prepare.primitives-reused");

    // The daemon keeps its own credential. Only its private sandbox slot is
    // cleared, so the shared kernel credential and its MAC label stay intact.
    uint64_t original_sandbox_label = 0;
    status = unfaird_kernel.set_mac_label(1, UINT64_MAX, &original_sandbox_label);
    if (status != 0) {
        unfaird_write_error(error, error_size, "jbclient_root_set_mac_label failed: %d", status);
        return -1;
    }
    unfaird_trace("prepare.mac-label-cleared");
    uint64_t observed_sandbox_label = 0;
    status = unfaird_kernel.set_mac_label(1, UINT64_MAX, &observed_sandbox_label);
    if (status != 0 || observed_sandbox_label != UINT64_MAX) {
        unfaird_write_error(
            error,
            error_size,
            "sandbox label verification failed: status=%d original=0x%llx observed=0x%llx",
            status,
            (unsigned long long)original_sandbox_label,
            (unsigned long long)observed_sandbox_label);
        return -1;
    }
    unfaird_trace("prepare.mac-label-verified");

    uint64_t proc = unfaird_kernel.proc_find(getpid());
    if (proc == 0) {
        unfaird_write_error(error, error_size, "proc_find(%d) failed", getpid());
        return -1;
    }

    status = set_csflags(proc, UNFAIRD_CS_PLATFORM_BINARY);
    unfaird_trace("prepare.csflags");
    if (status == 0) {
        status = allow_invalid(proc, false);
        unfaird_trace("prepare.allow-invalid");
    }
    unfaird_kernel.proc_rele(proc);
    if (status != 0) {
        unfaird_write_error(error, error_size, "code-signing state preparation failed: %d", status);
        return -1;
    }

    status = unfaird_load_offsets(get_system_info, error, error_size);
    if (status == 0) {
        unfaird_trace("prepare.offsets");
    } else if (getenv("UNFAIRD_MAPPING_TRACE") != NULL) {
        dprintf(STDERR_FILENO, "unfaird-mapping offsets-error=%s\n", error);
    }
    return status;
}

static int unfaird_prepare_kernel_decryption(char *error, size_t error_size) {
    pthread_mutex_lock(&unfaird_prepare_lock);
    if (unfaird_prepared) {
        pthread_mutex_unlock(&unfaird_prepare_lock);
        return 0;
    }

    int status = unfaird_prepare_locked(error, error_size);
    if (status == 0) {
        unfaird_prepared = true;
    }
    pthread_mutex_unlock(&unfaird_prepare_lock);
    return status;
}

static uint8_t unfaird_current_protection(uint64_t flags) {
    return (uint8_t)((flags >> unfaird_offsets.flags_prot) & UINT64_C(0xf));
}

static uint8_t unfaird_max_protection(uint64_t flags) {
    return (uint8_t)((flags >> unfaird_offsets.flags_maxprot) & UINT64_C(0xf));
}

static bool unfaird_user_debug(uint64_t flags) {
    if (!unfaird_offsets.has_user_debug) {
        return true;
    }
    return ((flags >> unfaird_offsets.flags_user_debug) & UINT64_C(1)) != 0;
}

static int unfaird_find_vm_entry(void *address, size_t size, struct unfaird_vm_entry *result) {
    uint64_t proc = unfaird_kernel.proc_find(getpid());
    if (proc == 0) {
        return ESRCH;
    }

    uint64_t task = unfaird_kernel.proc_task(proc);
    uint64_t vm_map = unfaird_kernel.kread_ptr(task + unfaird_offsets.task_map);
    unfaird_kernel.proc_rele(proc);
    if (vm_map == 0) {
        return EFAULT;
    }

    uint64_t header = vm_map + unfaird_offsets.vm_map_hdr;
    uint32_t count = unfaird_kernel.kread32(header + unfaird_offsets.header_nentries);
    uint64_t entry = unfaird_kernel.kread_ptr(
        header + unfaird_offsets.header_links + unfaird_offsets.links_next);
    uint64_t first_entry = entry;
    uint64_t requested_start = (uint64_t)address;
    uint64_t requested_end = requested_start + size;

    for (uint32_t index = 0; entry != 0 && index < count; index++) {
        uint64_t links = entry + unfaird_offsets.entry_links;
        uint64_t entry_start = unfaird_kernel.kread_ptr(links + unfaird_offsets.links_min);
        uint64_t entry_end = unfaird_kernel.kread_ptr(links + unfaird_offsets.links_max);
        if (entry_start <= requested_start && requested_end <= entry_end) {
            result->address = entry;
            result->flags = unfaird_kernel.kread64(entry + unfaird_offsets.entry_flags);
            return 0;
        }

        entry = unfaird_kernel.kread_ptr(links + unfaird_offsets.links_next);
        if (entry == first_entry) {
            break;
        }
    }
    return ENOENT;
}

static int unfaird_promote_mapping(
    void *mapping,
    size_t size,
    struct unfaird_active_mapping *active_mapping
) {
    struct unfaird_vm_entry entry = {0};
    int status = unfaird_find_vm_entry(mapping, size, &entry);
    if (status != 0) {
        unfaird_record_mapping_error("vm_map entry lookup failed: %d", status);
        return status;
    }

    uint8_t current = unfaird_current_protection(entry.flags);
    uint8_t maximum = unfaird_max_protection(entry.flags);
    if (current != VM_PROT_READ || (maximum & VM_PROT_READ) == 0 ||
        (maximum & VM_PROT_EXECUTE) != 0) {
        unfaird_record_mapping_error(
            "unexpected mapping protections: current=0x%x maximum=0x%x",
            current,
            maximum);
        return EINVAL;
    }

    uint64_t shift = unfaird_offsets.flags_maxprot;
    uint64_t promoted_flags =
        (entry.flags & ~(UINT64_C(0xf) << shift)) |
        ((uint64_t)(VM_PROT_READ | VM_PROT_EXECUTE) << shift);
    status = unfaird_kernel.kwrite64(entry.address + unfaird_offsets.entry_flags, promoted_flags);
    if (status != 0) {
        unfaird_record_mapping_error("vm_map max-protection write failed: %d", status);
        return status;
    }

    uint64_t observed_flags = unfaird_kernel.kread64(entry.address + unfaird_offsets.entry_flags);
    if (observed_flags != promoted_flags) {
        unfaird_record_mapping_error("vm_map max-protection verification failed");
        return EIO;
    }

    kern_return_t kr = vm_protect(
        mach_task_self(),
        (vm_address_t)mapping,
        size,
        false,
        VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        unfaird_record_mapping_error("vm_protect RX failed: %d", kr);
        return EPERM;
    }

    struct unfaird_vm_entry protected_entry = {0};
    status = unfaird_find_vm_entry(mapping, size, &protected_entry);
    if (status != 0) {
        unfaird_record_mapping_error("protected vm_map entry lookup failed: %d", status);
        return status;
    }
    if (unfaird_current_protection(protected_entry.flags) !=
        (VM_PROT_READ | VM_PROT_EXECUTE)) {
        unfaird_record_mapping_error("vm_protect did not set RX protection");
        return ENOTSUP;
    }
    if (!unfaird_user_debug(protected_entry.flags)) {
        unfaird_record_mapping_error("vm_protect did not set user-debug state");
        return ENOTSUP;
    }

    active_mapping->address = mapping;
    active_mapping->size = size;
    active_mapping->original_flags = entry.flags;
    active_mapping->active = true;
    return 0;
}

static int unfaird_enter_legacy_credential(struct unfaird_active_mapping *active_mapping) {
    if (unfaird_offsets.has_user_debug || active_mapping->borrowed_kernel_ucred) {
        return 0;
    }

    int status = unfaird_kernel.steal_ucred(0, &active_mapping->original_ucred);
    if (status != 0) {
        unfaird_record_mapping_error("legacy kernel credential acquisition failed: %d", status);
        return status;
    }
    active_mapping->borrowed_kernel_ucred = true;

    status = unfaird_kernel.set_mac_label(
        1,
        UINT64_MAX,
        &active_mapping->kernel_sandbox_label);
    if (status != 0) {
        int restore_status = unfaird_kernel.steal_ucred(active_mapping->original_ucred, NULL);
        active_mapping->borrowed_kernel_ucred = false;
        unfaird_record_mapping_error(
            "legacy kernel MAC-label acquisition failed: %d credential-restore=%d",
            status,
            restore_status);
        return status;
    }
    unfaird_trace("mapping.legacy-credential");
    return 0;
}

static int unfaird_leave_legacy_credential(struct unfaird_active_mapping *active_mapping) {
    if (!active_mapping->borrowed_kernel_ucred) {
        return 0;
    }

    int label_status = unfaird_kernel.set_mac_label(
        1,
        active_mapping->kernel_sandbox_label,
        NULL);
    int credential_status = unfaird_kernel.steal_ucred(active_mapping->original_ucred, NULL);
    active_mapping->borrowed_kernel_ucred = false;
    if (label_status != 0 || credential_status != 0) {
        unfaird_record_mapping_error(
            "legacy credential restore failed: mac-label=%d credential=%d",
            label_status,
            credential_status);
        return label_status != 0 ? label_status : credential_status;
    }
    unfaird_trace("mapping.original-credential");
    return 0;
}

int unfaird_prepare_encrypted_region(char *error, size_t error_size) {
    int status = unfaird_prepare_kernel_decryption(error, error_size);
    if (status != 0) {
        return status;
    }

    status = unfaird_enter_legacy_credential(&unfaird_active_mapping);
    if (status != 0) {
        unfaird_write_error(error, error_size, "%s", unfaird_mapping_error);
    }
    return status;
}

int unfaird_finish_encrypted_region_preparation(void) {
    int status = unfaird_leave_legacy_credential(&unfaird_active_mapping);
    if (status != 0) {
        errno = status;
        return -1;
    }
    return 0;
}

static int unfaird_restore_mapping_flags(
    void *mapping,
    size_t size,
    uint64_t original_flags
) {

    kern_return_t kr = vm_protect(
        mach_task_self(),
        (vm_address_t)mapping,
        size,
        false,
        VM_PROT_READ);
    if (kr != KERN_SUCCESS) {
        unfaird_record_mapping_error("vm_protect R restore failed: %d", kr);
        return EPERM;
    }

    struct unfaird_vm_entry entry = {0};
    int status = unfaird_find_vm_entry(mapping, size, &entry);
    if (status != 0) {
        unfaird_record_mapping_error("restored vm_map entry lookup failed: %d", status);
        return status;
    }

    status = unfaird_kernel.kwrite64(entry.address + unfaird_offsets.entry_flags, original_flags);
    if (status != 0) {
        unfaird_record_mapping_error("vm_map original-flags write failed: %d", status);
        return status;
    }

    uint64_t observed_flags = unfaird_kernel.kread64(entry.address + unfaird_offsets.entry_flags);
    if (observed_flags != original_flags) {
        unfaird_record_mapping_error("vm_map original-flags verification failed");
        return EIO;
    }
    unfaird_trace("mapping.read-only-restored");
    return 0;
}

int unfaird_restore_encrypted_region(void *mapping, size_t size) {
    if (!unfaird_active_mapping.active ||
        unfaird_active_mapping.address != mapping ||
        unfaird_active_mapping.size != size) {
        unfaird_record_mapping_error("encrypted mapping restoration does not match the active mapping");
        errno = EINVAL;
        return -1;
    }

    unfaird_active_mapping.active = false;
    int mapping_status = unfaird_restore_mapping_flags(
        mapping,
        size,
        unfaird_active_mapping.original_flags);
    int credential_status = unfaird_leave_legacy_credential(&unfaird_active_mapping);
    int status = mapping_status != 0 ? mapping_status : credential_status;
    if (status != 0) {
        errno = status;
        return -1;
    }
    return 0;
}

void *unfaird_map_encrypted_region(
    void *address,
    size_t size,
    int protection,
    int flags,
    int fd,
    off_t offset
) {
    bool should_promote =
        unfaird_promotion_enabled &&
        protection == (PROT_READ | PROT_EXEC) &&
        (flags & MAP_PRIVATE) != 0 &&
        fd >= 0;
    if (!should_promote) {
        errno = EINVAL;
        return MAP_FAILED;
    }
    if (unfaird_active_mapping.active) {
        unfaird_record_mapping_error("an encrypted mapping is already active on this thread");
        errno = EBUSY;
        return MAP_FAILED;
    }

    unfaird_mapping_error[0] = '\0';
    // Keeping the initial mapping read-only preserves its vnode and gives every
    // supported kernel the same temporary executable transition.
    void *mapping = mmap(address, size, PROT_READ, flags, fd, offset);
    if (mapping == MAP_FAILED) {
        return MAP_FAILED;
    }
    unfaird_trace("mapping.read-only");

    char preparation_error[512] = {0};
    int status = unfaird_prepare_kernel_decryption(
        preparation_error,
        sizeof(preparation_error));
    if (status != 0) {
        unfaird_record_mapping_error(
            "kernel mapping preparation failed: %s",
            preparation_error);
        munmap(mapping, size);
        errno = EPERM;
        return MAP_FAILED;
    }

    status = unfaird_promote_mapping(mapping, size, &unfaird_active_mapping);
    if (status != 0) {
        munmap(mapping, size);
        errno = status;
        return MAP_FAILED;
    }
    unfaird_trace("mapping.executable");

    status = unfaird_enter_legacy_credential(&unfaird_active_mapping);
    if (status != 0) {
        unfaird_restore_encrypted_region(mapping, size);
        munmap(mapping, size);
        errno = status;
        return MAP_FAILED;
    }
    return mapping;
}

void unfaird_set_mapping_promotion_enabled(bool enabled) {
    unfaird_promotion_enabled = enabled;
    if (enabled) {
        unfaird_mapping_error[0] = '\0';
    }
}

const char *unfaird_last_mapping_error(void) {
    return unfaird_mapping_error;
}

#else

int unfaird_prepare_encrypted_region(char *error, size_t error_size) {
    (void)error;
    (void)error_size;
    return 0;
}

int unfaird_finish_encrypted_region_preparation(void) {
    return 0;
}

void *unfaird_map_encrypted_region(
    void *address,
    size_t size,
    int protection,
    int flags,
    int fd,
    off_t offset
) {
    return mmap(address, size, protection, flags, fd, offset);
}

void unfaird_set_mapping_promotion_enabled(bool enabled) {
    (void)enabled;
}

int unfaird_restore_encrypted_region(void *mapping, size_t size) {
    (void)mapping;
    (void)size;
    return 0;
}

const char *unfaird_last_mapping_error(void) {
    return "";
}

#endif
