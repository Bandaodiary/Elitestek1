#ifndef C1_RECOVERY_H
#define C1_RECOVERY_H
#include "c1_accel.h"

/* Callbacks perform ordered, completed bus accesses; true means success.
 * A false write result may be ambiguous: never automatically retry it.
 * Caller serializes all software/hardware recovery and source control. */
typedef struct {
    void *context;
    bool (*read32)(void *, uint32_t offset, uint32_t *value);
    bool (*write32)(void *, uint32_t offset, uint32_t value);
} c1_recovery_io_t;
typedef enum {
    C1_RECOVERY_OK, C1_RECOVERY_INVALID, C1_RECOVERY_UNSUPPORTED,
    C1_RECOVERY_NOT_READY, C1_RECOVERY_IO_ERROR, C1_RECOVERY_TIMEOUT
} c1_recovery_result_t;
typedef struct {
    bool diagnostic_valid, diagnostic_coherent, command_attempted, command_accepted;
    uint32_t error_sequence;
    uint32_t error_code, error_address, recovery_status, system_status;
} c1_recovery_report_t;

/* Saves diagnostics before the command. Does not stop/restart the camera. */
c1_recovery_result_t c1_recovery_request(const c1_recovery_io_t *io,
                                        c1_recovery_report_t *report);
/* Read-only, bounded by sample count (not wall time). May resume after timeout.
 * Success requires both recovery completion and whole-system BUSY cleared. */
c1_recovery_result_t c1_recovery_wait(const c1_recovery_io_t *io, uint32_t polls,
                                     c1_recovery_report_t *report);
#endif
