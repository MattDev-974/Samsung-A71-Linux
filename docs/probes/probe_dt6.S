// Probe 1e: identify what uniLoader passes in x0.
// yellow = payload started
// white  = x0 == 0
// blue   = x0 == PAYLOAD_ENTRY (0x80080000)   -> args swapped?
// magenta= x0 == RAMDISK_ENTRY (0x90000000)   -> args swapped?
// green  = valid FDT magic
// red    = other / invalid
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

    cbz  x19, white
    movz x5, #0x0, lsl #16
    movk x5, #0x8008, lsl #16
    movk x5, #0x0
    cmp  x19, x5
    b.eq blue
    movz x5, #0x0, lsl #16
    movk x5, #0x9000, lsl #16
    cmp  x19, x5
    b.eq magenta

    ldr  w3, [x19]
    movz w4, #0x0dd0
    movk w4, #0xedfe, lsl #16
    cmp  w3, w4
    b.eq green
    movz x1, #0xff, lsl #16        // red
    b    paint
white:
    movz x1, #0xffff               // 0x0000ffff
    b    paint
blue:
    movz x1, #0xff                 // 0x000000ff
    b    paint
magenta:
    movz x1, #0xff00
    movk x1, #0xff, lsl #16        // 0x00ffff00
    b    paint
green:
    movz x1, #0xff00               // 0x0000ff00
paint:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
2:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 2b
3:  wfi
    b 3b
