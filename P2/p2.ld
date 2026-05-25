ENTRY(_start)

SECTIONS
{
    /* P2 code/data region */
    . = 0x82200000;

    .text : { *(.text*) }

    .rodata : { *(.rodata*) }

    .data : { *(.data*) }

    .bss : {
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        __bss_end__ = .;
    }

    . = 0x82210000;

    /* Define stack 8KB */
    __p2_stack_top = 0x82212000;
}