/* Linker script for PicoRV32 firmware
 * 
 * Memory map (adjust to match your SoC):
 *   0x00000000 - 0x0000FFFF : Instruction/Data RAM (64KB)
 *   0x10000000 - 0x100000FF : Accelerator MMIO registers
 */

MEMORY {
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

ENTRY(_start)

SECTIONS {
    /* Code section */
    .text : {
        . = 0x00000000;
        *(.text.init)       /* Startup code first */
        *(.text .text.*)    /* All other code */
        . = ALIGN(4);
    } > RAM

    /* Read-only data */
    .rodata : {
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > RAM

    /* Initialized data */
    .data : {
        *(.data .data.*)
        . = ALIGN(4);
    } > RAM

    /* Uninitialized data (BSS) */
    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /* Stack at end of RAM */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        . = . + 0x1000;     /* 4KB stack */
        __stack_top = .;
    } > RAM

    /* End of used memory */
    _end = .;
}
