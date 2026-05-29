ENTRY(_start)

SECTIONS
{
    . = 0x82000000;

    .vectors : {
        KEEP(*(.vectors))
    }

    .text : {
        *(.text*)
    }

    .rodata : {
        *(.rodata*)
    }

    . = 0x82008000;
    .os_api : {
        KEEP(*(.os_api))
    }

    .data : {
        *(.data*)
    }

    .bss : {
        __bss_start__ = .;
        *(.bss*)
        *(COMMON)
        __bss_end__ = .;
    }

    __irq_stack_top = 0x82011000;
    __os_stack_top  = 0x82012000;
    __svc_stack_top = 0x82013000;
}
