#ifndef UNFAIR_DAEMON_SUPPORT_H
#define UNFAIR_DAEMON_SUPPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>
#include <stdint.h>

int unfaird_raise_jetsam_limit(int32_t megabytes, char *error, size_t error_size);
int unfaird_prepare_kernel_decryption(char *error, size_t error_size);
void *unfaird_map_encrypted_region(
    void *address,
    size_t size,
    int protection,
    int flags,
    int fd,
    off_t offset
);
void unfaird_set_mapping_promotion_enabled(bool enabled);
const char *unfaird_last_mapping_error(void);

#endif
