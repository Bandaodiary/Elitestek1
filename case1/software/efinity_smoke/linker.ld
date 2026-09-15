OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ram (rwxai) : ORIGIN = 0x00001000, LENGTH = 124K
}

SECTIONS
{
    .init : { KEEP(*(.init)) } > ram
    .text : { *(.text .text.*) } > ram
    .rodata : { *(.rodata .rodata.*) } > ram
    .data : { *(.data .data.*) } > ram
    .bss (NOLOAD) :
    {
        __bss_start = .;
        *(.bss .bss.* COMMON)
        . = ALIGN(4);
        _end = .;
    } > ram
    . = ALIGN(16);
    . += 4K;
    PROVIDE(_stack_top = .);
}

