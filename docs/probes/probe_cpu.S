// Probe 2: report CPU state at payload entry as three colour bands.
// Band 1 (top):  CurrentEL -> green=EL1, blue=EL2, red=other
// Band 2 (mid):  MMU (SCTLR_EL1.M) -> white=on, black=off
// Band 3 (bottom): D/I caches (SCTLR_EL1.C/I) -> yellow=on, magenta=off
    .section .text
    .global _start
_start:
    // --- band 1: exception level
    mrs  x5, CurrentEL
    lsr  x5, x5, #2
    and  x5, x5, #3
    movz x1, #0xff, lsl #16        // red (default)
    cmp  x5, #1
    b.ne 1f
    movz x1, #0xff00               // green (EL1)
    b    3f
1:  cmp  x5, #2
    b.ne 3f
    movz x1, #0xff                 // blue (EL2)
3:
    movz x0, #0x9c00, lsl #16
    movz x2, #0x9780
    movk x2, #0x6, lsl #16         // 0x69780 stores = 800 rows
    bl   fill

    // --- band 2: MMU
    mrs  x6, SCTLR_EL1
    tst  x6, #1
    movz x1, #0                    // black = MMU off
    b.eq 4f
    movz x1, #0xffff               // white = MMU on
4:
    movz x2, #0x9780
    movk x2, #0x6, lsl #16
    bl   fill

    // --- band 3: caches
    mrs  x6, SCTLR_EL1
    and  x7, x6, #(1 << 2)
    and  x8, x6, #(1 << 12)
    orr  x7, x7, x8
    movz x1, #0xff00, lsl #16      // magenta? (0xFF000000) = caches off
    cbz  x7, 5f
    movz x1, #0xff00
    movk x1, #0xff, lsl #16       // yellow = caches on
5:
    movz x2, #0x9780
    movk x2, #0x6, lsl #16
    bl   fill

6:  wfi
    b 6b

// x0 = framebuffer pointer, x1 = colour, x2 = number of 8-byte stores
fill:
    str  x1, [x0], #8
    subs x2, x2, #1
    b.ne fill
    ret
