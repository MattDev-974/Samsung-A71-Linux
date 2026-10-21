// Read the kernel progress value at physical 0xab735e48 and paint that many
// white stripes (20 rows each, every 40 rows) on a black screen.
    .section .text
    .global _start
_start:
    movz x1, #0x5e48
    movk x1, #0xab73, lsl #16
    ldr  w2, [x1]
    cmp  w2, #32
    b.le 1f
    mov  w2, #32
1:
    // black screen
    movz x0, #0x9c00, lsl #16
    movz x4, #0xc4c0
    movk x4, #0x13, lsl #16
2:  str  xzr, [x0], #8
    subs x4, x4, #1
    b.ne 2b
    // stripes
    mov  w3, #0
3:  cmp  w3, w2
    b.ge 9f
    movz w5, #0xa300
    movk w5, #0x0002, lsl #16       // 172800 bytes per stripe pitch
    mul  w6, w3, w5
    movz x0, #0x9c00, lsl #16
    add  x0, x0, x6, lsl #0
    movz x7, #0x2a30                // 10800 stores * 8 bytes = 20 rows
    movz x8, #0xffff
    movk x8, #0xff, lsl #16         // white
4:  str  x8, [x0], #8
    subs x7, x7, #1
    b.ne 4b
    add  w3, w3, #1
    b    3b
9:  wfi
    b 9b
