#include "c1_recovery.h"

c1_recovery_result_t c1_recovery_request(const c1_recovery_io_t *io,
                                        c1_recovery_report_t *r)
{
    uint32_t capability;
    if (!io || !io->read32 || !io->write32 || !r) return C1_RECOVERY_INVALID;
    *r = (c1_recovery_report_t){0};
    if (!io->read32(io->context, C1_REG_CAPABILITY, &capability))
        return C1_RECOVERY_IO_ERROR;
    if (!(capability & C1_CAP_CAPTURE_RECOVERY)) return C1_RECOVERY_UNSUPPORTED;
    if (!io->read32(io->context, C1_REG_RECOVERY_STATUS, &r->recovery_status))
        return C1_RECOVERY_IO_ERROR;
    if (!(r->recovery_status & C1_RECOVERY_ENABLED) ||
        !(r->recovery_status & C1_RECOVERY_READY) ||
        (r->recovery_status & C1_RECOVERY_BUSY)) return C1_RECOVERY_NOT_READY;
    if (capability & C1_CAP_ERROR_SEQUENCE) {
        for (unsigned attempt=0; attempt<4; ++attempt) {
            uint32_t before,after;
            if (!io->read32(io->context, C1_REG_ERROR_SEQUENCE, &before) ||
                !io->read32(io->context, C1_REG_ERROR_CODE, &r->error_code) ||
                !io->read32(io->context, C1_REG_ERROR_ADDRESS, &r->error_address) ||
                !io->read32(io->context, C1_REG_ERROR_SEQUENCE, &after))
                return C1_RECOVERY_IO_ERROR;
            if (before==after) {
                r->error_sequence=after;r->diagnostic_coherent=true;break;
            }
        }
        if (!r->diagnostic_coherent) return C1_RECOVERY_NOT_READY;
    } else if (!io->read32(io->context, C1_REG_ERROR_CODE, &r->error_code) ||
               !io->read32(io->context, C1_REG_ERROR_ADDRESS, &r->error_address)) {
        return C1_RECOVERY_IO_ERROR;
    }
    r->diagnostic_valid = true;
    r->command_attempted = true;
    if (!io->write32(io->context, C1_REG_RECOVERY_COMMAND, C1_RECOVERY_REQUEST))
        return C1_RECOVERY_IO_ERROR;
    r->command_accepted = true;
    return C1_RECOVERY_OK;
}

c1_recovery_result_t c1_recovery_wait(const c1_recovery_io_t *io, uint32_t polls,
                                     c1_recovery_report_t *r)
{
    if (!io || !io->read32 || !r || !r->command_accepted || !polls)
        return C1_RECOVERY_INVALID;
    for (uint32_t i=0; i<polls; ++i) {
        if (!io->read32(io->context, C1_REG_RECOVERY_STATUS, &r->recovery_status) ||
            !io->read32(io->context, C1_REG_STATUS, &r->system_status))
            return C1_RECOVERY_IO_ERROR;
        if ((r->recovery_status & C1_RECOVERY_ENABLED) &&
            (r->recovery_status & C1_RECOVERY_DONE) &&
            !(r->recovery_status & C1_RECOVERY_BUSY) &&
            !(r->system_status & C1_STATUS_BUSY)) return C1_RECOVERY_OK;
    }
    return C1_RECOVERY_TIMEOUT;
}
