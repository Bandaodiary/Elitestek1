#include "c1_recovery.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct {
    uint32_t cap, status, fail_read;
    unsigned reads,writes,samples,complete_after,idle_after;
    unsigned races,sequence;
    bool fail_write,active;
} fake_t;
static bool rd(void *ctx,uint32_t off,uint32_t *v) {
    fake_t *f=ctx; f->reads++;
    if(off==f->fail_read) return false;
    switch(off) {
    case C1_REG_CAPABILITY: *v=f->cap;break;
    case C1_REG_RECOVERY_STATUS:
        *v=f->status;
        if(f->active) {
            f->samples++;
            *v=C1_RECOVERY_ENABLED | (f->samples>=f->complete_after ?
                C1_RECOVERY_DONE : C1_RECOVERY_BUSY);
        } break;
    case C1_REG_STATUS: *v=f->samples>=f->idle_after ? 0 : C1_STATUS_BUSY;break;
    case C1_REG_ERROR_CODE: *v=0x46;break;
    case C1_REG_ERROR_SEQUENCE: *v=f->sequence;break;
    case C1_REG_ERROR_ADDRESS:
        if(f->races){f->races--;f->sequence++;}
        *v=0x1230+16*f->sequence;break;
    default: assert(0);return false;
    } return true;
}
static bool wr(void *ctx,uint32_t off,uint32_t v) {
    fake_t *f=ctx;f->writes++;
    assert(off==C1_REG_RECOVERY_COMMAND && v==C1_RECOVERY_REQUEST);
    if(f->fail_write) return false;
    f->active=true;return true;
}
static fake_t initial(void) {
    fake_t f;memset(&f,0,sizeof f);
    f.cap=C1_CAP_CAPTURE_RECOVERY|C1_CAP_ERROR_SEQUENCE;
    f.status=C1_RECOVERY_ENABLED|C1_RECOVERY_READY|C1_RECOVERY_DONE;
    f.fail_read=0xffffffffu;f.complete_after=2;f.idle_after=4;return f;
}
int main(void) {
    fake_t f=initial();c1_recovery_report_t r;
    c1_recovery_io_t io={&f,rd,wr};
    assert(c1_recovery_request(NULL,&r)==C1_RECOVERY_INVALID);
    f.cap=0;
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_UNSUPPORTED && f.reads==1 && !f.writes);
    f=initial();f.status=C1_RECOVERY_ENABLED|C1_RECOVERY_BUSY;
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_NOT_READY && !f.writes);
    f=initial();f.fail_read=C1_REG_ERROR_ADDRESS;
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_IO_ERROR && !r.diagnostic_valid && !f.writes);
    f=initial();f.fail_write=true;
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_IO_ERROR);
    assert(r.command_attempted && !r.command_accepted && r.diagnostic_valid && f.writes==1);
    assert(c1_recovery_wait(&io,3,&r)==C1_RECOVERY_INVALID && f.writes==1);
    f=initial();
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_OK);
    assert(r.error_code==0x46 && r.error_address==0x1230 && r.command_accepted);
    assert(c1_recovery_wait(&io,0,&r)==C1_RECOVERY_INVALID && f.samples==0);
    assert(c1_recovery_wait(&io,1,&r)==C1_RECOVERY_TIMEOUT); // stale pre-command done is ignored
    assert(c1_recovery_wait(&io,1,&r)==C1_RECOVERY_TIMEOUT); // done but whole system busy
    assert(c1_recovery_wait(&io,2,&r)==C1_RECOVERY_OK && f.writes==1);
    f.fail_read=C1_REG_RECOVERY_STATUS;
    assert(c1_recovery_wait(&io,1,&r)==C1_RECOVERY_IO_ERROR && f.writes==1);
    f=initial();f.complete_after=1;f.idle_after=1;
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_OK);
    assert(c1_recovery_wait(&io,1,&r)==C1_RECOVERY_OK && f.writes==1);
    f=initial();f.races=1;
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_OK && r.diagnostic_coherent);
    assert(r.error_sequence==1 && r.error_address==0x1240 && f.writes==1);
    f=initial();f.races=4;
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_NOT_READY && !r.diagnostic_valid && !f.writes);
    f=initial();f.cap=C1_CAP_CAPTURE_RECOVERY;
    assert(c1_recovery_request(&io,&r)==C1_RECOVERY_OK && r.diagnostic_valid && !r.diagnostic_coherent);
    puts("C1_RECOVERY_HOST_PASS capability diagnostics rejected_write stale_done drain timeout_resume io_error coherent_retry legacy_fallback");
    return 0;
}
