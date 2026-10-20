// Probe 1: is the DTB pointer (x0, from uniLoader) a valid FDT?
// Paints the framebuffer green if the FDT magic/totalsize look sane, red otherwise.
    .section .text
    .global _start
_start:
    ldr  w3, [x0]                 // FDT magic, stored big-endian
    movz w4, #0x0dd0
    movk w4, #0xedfe, lsl #16     // 0xedfe0dd0 == 0xd00dfeed byte-swapped
    cmp  w3, w4
    b.ne bad
    ldr  w3, [x0, #4]             // totalsize (big-endian)
    rev  w3, w3
    movz w4, #0x0002, lsl #16     // 128 KiB
    cmp  w3, w4
    b.hi bad
    movz x1, #0xff00              // green = OK
    b    paint
bad:
    movz x1, #0xff, lsl #16       // red = bad
paint:
    movz x0, #0x9c00, lsl #16     // framebuffer
    movz x2, #0x13c4, lsl #16     // 1080*2400*4/8 = 1_296_000
    movk x2, #0xc0
1:
    str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 1b
2:
    wfi
    b 2b
