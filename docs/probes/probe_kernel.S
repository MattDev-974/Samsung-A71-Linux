// Probe 3: does the mainline kernel's entry point actually execute?
// - copies the real Image to 0xAA280000 (2 MB aligned base 0xAA200000 + text_offset)
// - writes a stub at 0xAA000000 that paints the screen blue
// - patches the kernel entry with "b 0xAA000000"
// - jumps to the kernel, DT pointer preserved in x0
// If the screen turns blue, the kernel's first instruction was reached.
    .section .text
    .global _start
_start:
    mov  x19, x0                  // DT pointer
    // marker: payload started (green)
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
0:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 0b
    // copy kernel image
    adr  x0, kernel_blob
    movz x1, #0xaa00, lsl #16
    movk x1, #0x28, lsl #16       // 0xAA280000
    movz x2, #(KSIZE & 0xffff)
    movk x2, #((KSIZE >> 16) & 0xffff), lsl #16
    lsr  x2, x2, #3
1:  ldr  x3, [x0], #8
    str  x3, [x1], #8
    subs x2, x2, #1
    b.ne 1b
    // copy stub
    adr  x0, stub
    movz x1, #0xaa00, lsl #16     // 0xAA000000
    adr  x2, stub_end
    sub  x2, x2, x0
    lsr  x2, x2, #3
2:  ldr  x3, [x0], #8
    str  x3, [x1], #8
    subs x2, x2, #1
    b.ne 2b
    // patch kernel entry: b 0xAA000000
    movz x4, #0xaa00, lsl #16
    movk x4, #0x28, lsl #16
    movz x3, #0x0000, lsl #16
    movk x3, #0x140a, lsl #16     // 0x140a0000
    str  w3, [x4]
    // marker: copy + patch done (yellow)
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movk x1, #0xff, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
4:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 4b
    // jump into the kernel
    mov  x0, x19
    br   x4

    .balign 8
stub:
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff                // blue
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
3:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 3b
    .word 0x140a0001              // b 0xAA280004 (kernel entry + 4)
    .balign 8
stub_end:
kernel_blob:
    .incbin "out/Image"
kernel_blob_end:
