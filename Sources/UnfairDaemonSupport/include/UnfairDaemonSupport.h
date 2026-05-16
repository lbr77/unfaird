#ifndef UNFAIR_DAEMON_SUPPORT_H
#define UNFAIR_DAEMON_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

int unfaird_raise_jetsam_limit(int32_t megabytes, char *error, size_t error_size);

#endif
