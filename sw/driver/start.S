

.section .text.init
.global _start

_start:

    la      sp, __stack_top


    la      t0, __bss_start
    la      t1, __bss_end
clear_bss:
    bge     t0, t1, bss_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       clear_bss
bss_done:


    jal     ra, main


    li      t0, 0x00001000
    sw      a0, 0(t0)

halt:

    j       halt


.global _trap_handler
_trap_handler:
    j       _trap_handler
