#include "c1_r2_control.h"

static uint32_t rd(uintptr_t base,unsigned offset) {
    return *(volatile uint32_t *)(base+offset);
}
static void wr(uintptr_t base,unsigned offset,uint32_t value) {
    *(volatile uint32_t *)(base+offset)=value;
}
static void barrier(void) {
#if defined(__riscv)
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
#elif defined(__GNUC__)
    __asm__ volatile ("" ::: "memory");
#endif
}
static int legal(const c1_r2_job *j) {
    uint32_t i,w,o,p;
    if(!j || j->width<4 || j->width>640 || j->height<4 || j->height>480 ||
       (j->width&3) || (j->height&3)) return 0;
    if((j->input|j->workspace|j->output|j->parameters)&0x7fffffu) return 0;
    i=j->input>>23;w=j->workspace>>23;o=j->output>>23;p=j->parameters>>23;
    return w<=509 && i!=o && i!=p && o!=p &&
           (i<w || i>w+2) && (o<w || o>w+2) && (p<w || p>w+2);
}
int c1_r2_submit(uintptr_t base,const c1_r2_job *j) {
    uint32_t status;
    if(!legal(j)) return -2;
    if(rd(base,C1_R2_ID)!=0x52324331u || rd(base,4)!=0x00010000u) return -5;
    status=rd(base,C1_R2_STATUS);
    if(status&C1_R2_FABRIC_ERROR) return -4;
    if(status&(C1_R2_BUSY|C1_R2_PENDING|C1_R2_RESULT|C1_R2_PUBLICATION)) return -1;
    wr(base,C1_R2_INPUT,j->input);wr(base,C1_R2_WORKSPACE,j->workspace);
    wr(base,C1_R2_OUTPUT,j->output);wr(base,C1_R2_PARAMETERS,j->parameters);
    wr(base,C1_R2_SHAPE,((uint32_t)j->height<<16)|j->width);wr(base,C1_R2_TAG,j->tag);
    barrier();status=rd(base,C1_R2_STATUS);
    if(status&C1_R2_FABRIC_ERROR) return -4;
    if(!(status&C1_R2_CAN_START)) return -3;
    wr(base,C1_R2_COMMAND,1);barrier();return 0;
}
int c1_r2_poll(uintptr_t base,c1_r2_result *r) {
    uint32_t status=rd(base,C1_R2_STATUS);
    if(!r || !(status&C1_R2_RESULT)) return 0;
    barrier();r->status=status;r->tag=rd(base,C1_R2_RESULT_TAG);r->cycles=rd(base,C1_R2_CYCLES);
    return 1;
}
void c1_r2_discard(uintptr_t base) { wr(base,C1_R2_COMMAND,2);barrier(); }
int c1_r2_ack_result(uintptr_t base) {
    if(!(rd(base,C1_R2_STATUS)&C1_R2_RESULT)) return -1;
    wr(base,C1_R2_COMMAND,4);barrier();return 0;
}
void c1_r2_irq_enable(uintptr_t base,uint32_t mask) { wr(base,C1_R2_IRQ_ENABLE,mask&7u);barrier(); }
void c1_r2_irq_clear(uintptr_t base,uint32_t mask) { wr(base,C1_R2_IRQ_STATUS,mask&7u);barrier(); }
