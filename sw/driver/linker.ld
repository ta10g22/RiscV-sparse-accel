

MEMORY {
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

ENTRY(_start)

SECTIONS {

    .text : {
        . = 0x00000000;
        *(.text.init)
        *(.text .text.*)
        . = ALIGN(4);
    } > RAM


    .rodata : {
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > RAM


    .data : {
        *(.data .data.*)
        . = ALIGN(4);
    } > RAM


    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM


    .stack (NOLOAD) : {
        . = ALIGN(16);
        . = . + 0x1000;
        __stack_top = .;
    } > RAM


    _end = .;
}
