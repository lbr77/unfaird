#include "UnfairDaemonSupport.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#define UNFAIRD_MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 6
#define UNFAIRD_MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK 5

extern int memorystatus_control(unsigned int command, int pid, unsigned int flags, void *buffer, size_t buffersize);

static void unfaird_set_error(char *error, size_t error_size, const char *format, ...) {
    if (error == NULL || error_size == 0) {
        return;
    }

    va_list args;
    va_start(args, format);
    vsnprintf(error, error_size, format, args);
    va_end(args);
}

int unfaird_raise_jetsam_limit(int32_t megabytes, char *error, size_t error_size) {
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    int pid = getpid();
    int result = memorystatus_control(
        UNFAIRD_MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT,
        pid,
        (unsigned int)megabytes,
        NULL,
        0
    );
    if (result != 0) {
        unfaird_set_error(error, error_size, "memorystatus task limit %d MB failed: %s", megabytes, strerror(errno));
        return -1;
    }

    result = memorystatus_control(
        UNFAIRD_MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK,
        pid,
        (unsigned int)megabytes,
        NULL,
        0
    );
    if (result != 0) {
        unfaird_set_error(error, error_size, "memorystatus high water mark %d MB failed: %s", megabytes, strerror(errno));
        return -1;
    }

    return 0;
#else
    (void)megabytes;
    (void)error;
    (void)error_size;
    return 0;
#endif
}
