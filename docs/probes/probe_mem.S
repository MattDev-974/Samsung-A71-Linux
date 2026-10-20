// Probe RAM access: green = payload ran, then test writes at high addresses.
// yellow = 0xAA280000 writable/readable
// blue   = 0xA0000000 writable/readable
// red    = neither
    .section .text
    .global _start
_start:
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
0:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 0b

    // test 0xAA280000
    movz x3, #0xaa00, lsl #16
    movk x3, #0x28, lsl #16
    movz x4, #0xbeef
    movk x4, #0xdead, lsl #16
    str  x4, [x3]
    ldr  x5, [x3]
    cmp  x4, x5
    b.ne 1f
    movz x1, #0xff00               // yellow
    b    paint
1:
    // test 0xA0000000
    movz x3, #0xa000, lsl #16
    str  x4, [x3]
    ldr  x5, [x3]
    cmp  x4, x5
    b.ne 2f
    movz x1, #0xff                 // blue
    b    paint
2:
    movz x1, #0xff, lsl #16        // red
paint:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
3:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 3b
4:  wfi
    b 4b
