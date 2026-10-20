// Probe SMC/PSCI: is an SMC call usable from EL1 on this bootloader?
// yellow = payload ran, then SMC #0 executed; green = SMC returned.
    .section .text
    .global _start
_start:
    movz x0, #0x9c00, lsl #16
    movz x1, #0xff00
    movk x1, #0xff, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
1:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 1b

    movz x0, #0x0, lsl #16
    movk x0, #0x8400, lsl #16      // PSCI_VERSION
    smc  #0

    movz x1, #0xff00               // green: SMC returned
    movz x0, #0x9c00, lsl #16
    movz x2, #0xc4c0
    movk x2, #0x13, lsl #16
2:  str  x1, [x0], #8
    subs x2, x2, #1
    b.ne 2b
3:  wfi
    b 3b
