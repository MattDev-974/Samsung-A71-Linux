// Probe: is the ramoops region readable from EL1 at payload time?
// green  = 0xa1300000 readable
// blue   = 0xa13ff000 readable
// magenta= 0xa1400000 readable (Samsung sec_dbg)
// red    = none of them
    .section .text
    .global _start
_start:
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movk x1, #0xff, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
0:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 0b

    movz x21, #0xa130, lsl #16
    ldr  x3, [x21]                  // 0xa1300000
    movz x1, #0xff00                // green
    b    paint2x
paint2x:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
1:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 1b
    movz x21, #0xa13f, lsl #16
    ldr  x3, [x21]                  // 0xa13ff000
    movz x1, #0xff                 // blue
    b    paint3x
paint3x:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
2:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 2b
    movz x21, #0xa140, lsl #16
    ldr  x3, [x21]                  // 0xa1400000
    movz x1, #0xff00
    movk x1, #0xff, lsl #16        // magenta
    b    paint
paint:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
9:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 9b
    wfi
    b .
