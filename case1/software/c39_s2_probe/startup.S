    .section .init
    .globl _start
    .type _start,@function
    .option norvc
    .option norelax
_start:
    csrci mstatus, 8
    la sp, _stack_top
    la t0, trap_forever
    csrw mtvec, t0
    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:
    call main
    .balign 4
trap_forever:
    j trap_forever
