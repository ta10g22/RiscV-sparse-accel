# SpMM Accelerator Firmware - Startup Code
#
# Minimal startup for PicoRV32:
# 1. Set up stack pointer
# 2. Clear BSS section
# 3. Jump to main()
# 4. Handle return from main (halt or loop)

.section .text.init
.global _start

_start:
    # Set up stack pointer
    la      sp, __stack_top

    # Clear BSS section
    la      t0, __bss_start
    la      t1, __bss_end
clear_bss:
    bge     t0, t1, bss_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       clear_bss
bss_done:

    # Call main
    jal     ra, main

    # main() returned - store return value and halt
    # Return value is in a0
    # Store it at a known address for testbench to check
    li      t0, 0x00001000      # Result address
    sw      a0, 0(t0)

halt:
    # Infinite loop (or could use custom halt instruction)
    j       halt

# Trap handler (minimal - just loop)
.global _trap_handler
_trap_handler:
    j       _trap_handler
