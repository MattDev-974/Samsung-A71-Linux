// Read the kernel progress variable (physical 0xab735e48) and paint a colour.
// 0 red, 1 orange, 2 yellow, 3 green, 4 cyan, 5 blue, 6 magenta, 7 white,
// 8 grey, 9 pink, 10 violet, 11 brown, 12 teal, 13 gold, >=14 light blue.
    .section .text
    .global _start
_start:
    movz x1, #0x5e48
    movk x1, #0xab73, lsl #16
    movk x1, #0x0000, lsl #32
    ldr  w2, [x1]

    movz x1, #0xff, lsl #16        // red (0)
    cbz  w2, paint
    cmp  w2, #1
    b.ne l1
    movz x1, #0x8000
    movk x1, #0xff, lsl #16        // orange
    b    paint
l1:
    cmp  w2, #2
    b.ne l2
    movz x1, #0xff00
    movk x1, #0xff, lsl #16        // yellow
    b    paint
l2:
    cmp  w2, #3
    b.ne l3
    movz x1, #0xff00
                                   // green
    b    paint
l3:
    cmp  w2, #4
    b.ne l4
    movz x1, #0xffff
                                   // cyan
    b    paint
l4:
    cmp  w2, #5
    b.ne l5
    movz x1, #0xff
                                   // blue
    b    paint
l5:
    cmp  w2, #6
    b.ne l6
    movz x1, #0xff00
    movk x1, #0xff, lsl #16        // magenta
    b    paint
l6:
    cmp  w2, #7
    b.ne l7
    movz x1, #0xffff
    movk x1, #0xff, lsl #16        // white
    b    paint
l7:
    cmp  w2, #8
    b.ne l8
    movz x1, #0x8080
    movk x1, #0x80, lsl #16        // grey
    b    paint
l8:
    cmp  w2, #9
    b.ne l9
    movz x1, #0x0080
    movk x1, #0xff, lsl #16        // pink
    b    paint
l9:
    cmp  w2, #10
    b.ne l10
    movz x1, #0x8000
    movk x1, #0x80, lsl #16        // violet
    b    paint
l10:
    cmp  w2, #11
    b.ne l11
    movz x1, #0x4000
    movk x1, #0x80, lsl #16        // brown
    b    paint
l11:
    cmp  w2, #12
    b.ne l12
    movz x1, #0x8080
    movk x1, #0x00, lsl #16        // teal
    b    paint
l12:
    cmp  w2, #13
    b.ne l13
    movz x1, #0xc000
    movk x1, #0xc0, lsl #16        // gold
    b    paint
l13:
    movz x1, #0x80ff
    movk x1, #0x80, lsl #16        // light blue (>=14)
paint:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
99: str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 99b
    wfi
    b .
