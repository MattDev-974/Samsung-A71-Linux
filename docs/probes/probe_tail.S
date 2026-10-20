// Truncation test: the payload is ~22 MB; execution starts at the beginning
// and branches to a stub at the very end. Blue = the whole payload made it.
    .section .text
    .global _start
_start:
    b    stub
    .space 22000000
stub:
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
1:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 1b
2:  wfi
    b 2b
