@ Minimal 3DS test program: burns CPU in a loop and sleeps ~16 ms per iteration.
@ Exercises the ARM JIT / interpreter, the scheduler and svcSleepThread.
    .syntax unified
    .arm
    .text
    .global _start
_start:
    mov     r4, #0
outer:
    ldr     r5, =200000
inner:
    add     r4, r4, r5
    eor     r4, r4, r4, lsl #3
    subs    r5, r5, #1
    bne     inner
    ldr     r0, =16000000       @ 16 ms (s64 low word)
    mov     r1, #0              @ high word
    svc     0x0A                @ svcSleepThread
    b       outer
    .ltorg
