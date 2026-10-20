// Probe: did the mainline kernel (6.11.0-a71) reach pstore/ramoops init?
// Scans the ramoops region (0xa1300000, 1 MiB) for "6.11.0-a7".
// yellow = payload ran, green = mainline log found, red = not found.
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

    movz x24, #0x2e36
    movk x24, #0x3131, lsl #16
    movk x24, #0x302e, lsl #32
    movk x24, #0x612d, lsl #48      // "6.11.0-a"
    movz w25, #0x3137               // "71"

    movz x21, #0xa130, lsl #16      // 0xa1300000
    movz w22, #0x0010, lsl #16      // 0x100000 = 1 MiB
    sub  w22, w22, #16
scan:
    cbz  w22, not_found
    ldr  x3, [x21]
    cmp  x3, x24
    b.ne next
    ldrh w3, [x21, #8]
    cmp  w3, w25
    b.eq found
next:
    add  x21, x21, #1
    subs w22, w22, #1
    b.ne scan
    b    not_found
found:
    movz x1, #0xff00                // green
    b    paint
not_found:
    movz x1, #0xff, lsl #16         // red
paint:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
9:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 9b
    wfi
    b .
