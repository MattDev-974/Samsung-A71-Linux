// Probe 1b: paint blue immediately (proof the payload runs), then check the
// DTB passed in x0 and repaint green (valid FDT) or red (bad/absent).
    .section .text
    .global _start
_start:
    mov  x9, x0                   // save DT pointer
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff                // blue = payload started
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16       // 0x13c4c0 = 1_296_000 stores
    bl   fill

    ldr  w3, [x9]                 // FDT magic (big-endian in memory)
    movz w4, #0x0dd0
    movk w4, #0xedfe, lsl #16
    cmp  w3, w4
    b.ne bad
    ldr  w3, [x9, #4]             // totalsize, big-endian
    rev  w3, w3
    movz w4, #0x0002, lsl #16
    cmp  w3, w4
    b.hi bad
    movz x1, #0xff00              // green = valid DT
    b    paint2
bad:
    movz x1, #0xff, lsl #16       // red = invalid DT
paint2:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
    bl   fill
spin:
    wfi
    b spin
fill:
    str  x1, [x0], #8
    subs x2, x2, #1
    b.ne fill
    ret
