// Probe: does the DTB handed to the kernel actually carry the initramfs
// handoff (linux,initrd-start == CONFIG_RAMDISK_ENTRY) ?
// yellow = payload ran
// green  = string present AND value 0x90000000 found
// blue   = string present, value not found
// red    = string absent
    .section .text
    .global _start
_start:
    mov  x19, x0
    // marker: yellow
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movk x1, #0xff, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
0:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 0b

    // constants
    movz x24, #0x696c
    movk x24, #0x6e69, lsl #16
    movk x24, #0x2c78, lsl #32
    movk x24, #0x6e69, lsl #48      // "linux,in"
    movz x25, #0x7469
    movk x25, #0x6472, lsl #16
    movk x25, #0x732d, lsl #32
    movk x25, #0x6174, lsl #48      // "itrd-sta"
    movz w26, #0x7472               // "rt"

    ldr  w20, [x19, #4]
    rev  w20, w20                   // totalsize
    mov  x21, x19
    sub  w22, w20, #17
scan:
    cbz  w22, no_str
    ldr  x3, [x21]
    cmp  x3, x24
    b.ne next
    ldr  x3, [x21, #8]
    cmp  x3, x25
    b.ne next
    ldrh w3, [x21, #16]
    cmp  w3, w26
    b.eq found_str
next:
    add  x21, x21, #1
    subs w22, w22, #1
    b.ne scan
    b    no_str

found_str:
    // scan for the 64-bit value 0x0000000090000000
    movz x27, #0x0
    movk x27, #0x9000, lsl #16
    mov  x21, x19
    mov  w22, w20
    sub  w22, w22, #8
vscan:
    cbz  w22, val_missing
    ldr  x3, [x21]
    cmp  x3, x27
    b.eq val_found
    add  x21, x21, #1
    subs w22, w22, #1
    b.ne vscan
    b    val_missing

val_missing:
    movz x1, #0xff                 // blue
    b    paint
val_found:
    movz x1, #0xff00               // green
    b    paint
no_str:
    movz x1, #0xff, lsl #16        // red
paint:
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
9:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 9b
    wfi
    b .
