# sw/start.s
.section .text
.global _start
_start:
    lui sp, %hi(0x00008000) # Load stack pointer (32KB mark in RAM)
    addi sp, sp, %lo(0x00008000)
    call main
_loop:
    j _loop