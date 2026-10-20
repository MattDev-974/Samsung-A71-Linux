// Kernel entry probe (low RAM): copy Image to 0x82000000, stub at 0x84000000.
// green = payload started, yellow = copy done, blue = kernel entry executed.
    .section .text
    .global _start
_start:
    mov  x19, x0
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
0:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 0b

    adr  x0, kernel_blob
    movz x1, #0x8200, lsl #16
    movz x2, #(22313472 & 0xffff)
    movk x2, #((22313472 >> 16) & 0xffff), lsl #16
    lsr  x2, x2, #3
1:  ldr  x3, [x0], #8
    str  x3, [x1], #8
    subs x2, x2, #1
    b.ne 1b

    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movk x1, #0xff, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
2:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 2b

    adr  x0, stub
    movz x1, #0x8400, lsl #16
    adr  x2, stub_end
    sub  x2, x2, x0
    lsr  x2, x2, #3
3:  ldr  x3, [x0], #8
    str  x3, [x1], #8
    subs x2, x2, #1
    b.ne 3b

    // marker: stub copied (white)
    movz x0, #0x9c00, lsl #16
    movz x1, #0xffff
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
5:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 5b

    movz x4, #0x8200, lsl #16
    movz x3, #0x0000
    movk x3, #0x1480, lsl #16      // b 0x84000000
    str  w3, [x4]
    mov  x0, x19
    br   x4

    .balign 8
stub:
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff                 // blue
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
4:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 4b
    .word 0x177ffffa               // b 0x82000004 (kernel entry + 4)
    .balign 8
stub_end:
kernel_blob:
    .incbin "out/Image"
kernel_blob_end:
