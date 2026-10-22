@ Minimal 3DS test program: sleeps 0.5 s then calls svcExitProcess.
    .syntax unified
    .arm
    .text
    .global _start
_start:
    ldr     r0, =500000000
    mov     r1, #0
    svc     0x0A                @ svcSleepThread
    svc     0x03                @ svcExitProcess
1:  b       1b
    .ltorg
