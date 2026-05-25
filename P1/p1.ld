ENTRY(_start)

SECTIONS
{
    /* P1 code/data region */
    . = 0x82100000;

    .text : { *(.text*) }

    .rodata : { *(.rodata*) }

    .data : { *(.data*) }

    .bss : {
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        __bss_end__ = .;
    }

    . = 0x82110000;

    /* Define stack 8KB */
    __p1_stack_top = 0x82112000;
}