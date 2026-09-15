OUTPUT_ARCH("riscv")
ENTRY(_start)
/* Same application DDR window as the generated official S2 default linker.
   This is NOT the separate 4 KiB on-chip bootloader RAM at 0xf9000000. */
MEMORY { ram (rwx) : ORIGIN = 0x00001000, LENGTH = 124K }
SECTIONS
{
    .init : { KEEP(*(.init)) } > ram
    .text : { *(.text .text.*) } > ram
    .rodata : { *(.rodata .rodata.*) } > ram
    .data : { *(.data .data.* .sdata .sdata.*) } > ram
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > ram
    _stack_top = ORIGIN(ram) + LENGTH(ram);
    ASSERT(__bss_end <= _stack_top - 4096, "application overlaps reserved 4 KiB stack")
}
