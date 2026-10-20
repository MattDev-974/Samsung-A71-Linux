// Probe 1d: control paint (yellow, same encoding as the working payload)
// then FDT check on x19 (x0 saved before painting) and repaint green/red.
    .section .text
    .global _start
_start:
    mov  x19, x0
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movk x1, #0xff, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
1:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 1b

    ldr  w3, [x19]
    movz w4, #0x0dd0
    movk w4, #0xedfe, lsl #16
    cmp  w3, w4
    b.ne 2f
    ldr  w3, [x19, #4]
    rev  w3, w3
    movz w4, #0x0002, lsl #16
    cmp  w3, w4
    b.hi 2f
    movz x1, #0xff00
    b    3f
2:  movz x1, #0xff, lsl #16
3:  movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
4:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 4b
5:  wfi
    b 5b
