// Interpreter self-check: runs ARM forms the specialised dyncom handlers cover (and their
// conditional variants) on pseudo-random inputs, folds every result and the NZCV flags into a
// hash, then draws the hash's 32 bits as bands on the top screen.
typedef unsigned char u8;
typedef unsigned int u32;

static u32 mem[64];

#define FOLD "eor %[h], %[t], %[h], ror #7\n\tmrs %[f], cpsr\n\tadd %[h], %[h], %[f], lsr #28\n\t"

__attribute__((noinline)) static u32 run(u32 a, u32 b, u32 c, u32 x, u32* m, u32 h) {
    u32 t = c, f;
    asm volatile(
        "adds %[t], %[a], #0x3fc\n\t" FOLD
        "adds %[t], %[a], #0xff000000\n\t" FOLD
        "add %[t], %[a], %[b]\n\t" FOLD
        "adds %[t], %[a], %[b]\n\t" FOLD
        "add %[t], %[t], #1\n\t" FOLD
        "subs %[t], %[a], #1\n\t" FOLD
        "subs %[t], %[a], %[b]\n\t" FOLD
        "sub %[t], %[b], #0x80000000\n\t" FOLD
        "sub %[t], %[t], %[c]\n\t" FOLD
        "cmp %[a], #0x10\n\taddgt %[t], %[t], #5\n\tsubls %[t], %[t], %[c]\n\t" FOLD
        "cmp %[a], %[b]\n\tmovhi %[t], #0xab00\n\tmovlt %[t], #0x7f\n\t" FOLD
        "cmp %[b], #0\n\tmoveq %[t], #1\n\taddsne %[t], %[t], %[a]\n\t" FOLD
        "cmp %[c], #0xc0000000\n\tsubsvs %[t], %[t], #3\n\tmovvc %[t], #0x3f0000\n\t" FOLD
        "cmp %[a], %[a]\n\tsubseq %[t], %[b], %[c]\n\t" FOLD
        "mov %[t], #0xff\n\t" FOLD
        "str %[a], [%[m], #4]\n\tstr %[b], [%[m], #-4]\n\tldr %[t], [%[m], #4]\n\t" FOLD
        "ldr %[t], [%[m], #-4]\n\t" FOLD
        "str %[t], [%[m], #8]\n\tldr %[t], [%[m]]\n\t" FOLD
        "strb %[a], [%[m], #3]\n\tstrb %[c], [%[m], #-1]\n\tldrb %[t], [%[m], #3]\n\t" FOLD
        "ldrb %[t], [%[m], #-1]\n\t" FOLD
        "ldr %[t], [%[m], #0]\n\t" FOLD
        "ldr %[t], [%[m], #-8]\n\t" FOLD
        "cmp %[a], %[c]\n\tldrge %[t], [%[m], #8]\n\tstrlt %[b], [%[m], #12]\n\tldrlt %[t], [%[m], #12]\n\t" FOLD
        "cmp %[b], %[c]\n\tstrbhs %[a], [%[m], #2]\n\tldrblo %[t], [%[m], #2]\n\t" FOLD
        "ldr %[t], =0x12345678\n\t" FOLD
        "cmp %[t], %[a]\n\tldrne %[t], =0xdeadbeef\n\t" FOLD
        "ldr %[t], [%[m], #2]\n\t" FOLD   // unaligned word load
        "add %[t], %[a], %[b], lsl #3\n\t" FOLD
        "adds %[t], %[a], %[b], lsr #5\n\t" FOLD
        "add %[t], %[a], %[b], asr #31\n\t" FOLD
        "subs %[t], %[a], %[b], lsl #1\n\t" FOLD
        "sub %[t], %[t], %[c], asr #4\n\t" FOLD
        "cmp %[a], %[b], lsl #2\n\taddcc %[t], %[t], %[c], lsr #1\n\t" FOLD
        "cmp %[c], %[a], asr #9\n\tsubge %[t], %[t], %[b], lsl #30\n\t" FOLD
        "mov %[t], %[a], lsl #7\n\t" FOLD
        "mov %[t], %[b], asr #3\n\t" FOLD
        "cmp %[a], #0\n\tmovmi %[t], %[c], lsr #31\n\t" FOLD
        "orr %[t], %[a], %[b], lsl #16\n\t" FOLD
        "orr %[t], %[t], %[c], asr #2\n\t" FOLD
        "and %[t], %[a], #0xff00\n\t" FOLD
        "orr %[t], %[b], #0x80000001\n\t" FOLD
        "cmp %[b], %[c]\n\tandhi %[t], %[t], #0xf0\n\torrls %[t], %[t], #0x3c000\n\t" FOLD
        "rsbs %[t], %[a], #0\n\t" FOLD
        "rsb %[t], %[b], #0x100\n\t" FOLD
        "rsbs %[t], %[c], #0x7f000000\n\t" FOLD
        "str %[a], [%[m], %[x], lsl #2]\n\tldr %[t], [%[m], %[x], lsl #2]\n\t" FOLD
        "ldr %[t], [%[m], -%[x], lsl #2]\n\t" FOLD
        "str %[c], [%[m], -%[x], lsl #3]\n\tldr %[t], [%[m], -%[x], lsl #3]\n\t" FOLD
        "ldr %[t], [%[m], %[x]]\n\t" FOLD
        "ldrb %[t], [%[m], %[x]]\n\t" FOLD
        "ldrb %[t], [%[m], -%[x], lsl #1]\n\t" FOLD
        "cmp %[x], #4\n\tstrgt %[b], [%[m], %[x], lsl #2]\n\tldrle %[t], [%[m], -%[x], lsl #2]\n\t" FOLD
        "b 1f\n\t.ltorg\n1:\n\t"
        : [t] "+&r"(t), [f] "=&r"(f), [h] "+&r"(h)
        : [a] "r"(a), [b] "r"(b), [c] "r"(c), [x] "r"(x), [m] "r"(m)
        : "cc", "memory");
    return h;
}


// Block transfers: every addressing mode, writeback, base in the list, PC stored, a transfer
// that crosses a page boundary (big[] straddles one) and a loaded PC (the return).
// u32 ldmstm(u32 a, u32 b, u32 c, u32* m)
__attribute__((aligned(4096))) static u32 big[2048];
u32 ldmstm(u32 a, u32 b, u32 c, u32* m);
asm(".text\n.arm\n.global ldmstm\nldmstm:\n"
    "push {r4-r11, lr}\n"
    "mov r4, r0\n mov r5, r1\n mov r6, r2\n mov r7, r3\n"
    "stmia r7, {r4-r6}\n"            // IA, no writeback
    "ldmib r7, {r8, r9}\n"           // IB: b, c
    "eor r0, r0, r8, ror #3\n add r0, r0, r9\n"
    "stmdb r7!, {r4, r5, r6, r8}\n"  // DB with writeback
    "sub r0, r0, r7\n"
    "ldmia r7!, {r8-r11}\n"          // IA with writeback
    "eor r0, r0, r8\n add r0, r0, r9, lsl #1\n eor r0, r0, r10\n sub r0, r0, r11\n add r0, r0, r7\n"
    "stmda r7, {r0, r1, r7}\n"       // DA, base in the list
    "ldmda r7, {r8, r9, r10}\n"
    "add r0, r0, r8\n eor r0, r0, r9\n add r0, r0, r10, lsr #2\n"
    "mov r8, r7\n mov r9, r6\n stmia r8!, {r8, r9, pc}\n"  // old base stored (lowest), PC as PC + 8
    "sub r9, r8, r7\n add r0, r0, r9\n"
    "ldr r9, [r7]\n sub r9, r9, r7\n add r0, r0, r9\n ldr r9, [r7, #4]\n eor r0, r0, r9\n"
    "ldr r9, [r7, #8]\n adr r10, 1f\n sub r9, r9, r10\n add r0, r0, r9\n1:\n"
    "cmp r4, r5\n stmdbhi r7, {r4, r5}\n ldmdbhi r7, {r9, r10}\n movls r9, #7\n movls r10, #9\n"
    "add r0, r0, r9\n eor r0, r0, r10, ror #11\n"
    "pop {r4-r11, pc}\n");


// Calls and returns (the interpreter predicts returns): recursion deeper than its 16-entry
// return stack, calls through a function pointer (BLX Rm) and a return to Thumb code.
__attribute__((noinline)) static u32 rec(u32 n, u32 x) {
    if (n == 0)
        return x * 3 + 1;
    const u32 a = rec(n - 1, x ^ n);
    return (a << 1) ^ rec(n > 1 ? n - 2 : 0, a + n);
}
__attribute__((noinline, target("thumb"))) static u32 thumb_leaf(u32 x) { return (x >> 3) ^ (x * 7); }
__attribute__((noinline, target("thumb"))) static u32 thumb_mid(u32 x, u32 (*f)(u32, u32)) {
    return f(x & 7, x) + thumb_leaf(x);
}
static u32 (*volatile rec_ptr)(u32, u32) = rec;


// A block ends at a page boundary: pagecross() puts specialisable instructions in the last
// words of a page and goes on in the next one.
u32 pagecross(u32 x);
asm(".text\n.arm\n.p2align 12\n.space 4084\n.global pagecross\npagecross:\n"
    "add r0, r0, #1\n"     // page offset 0xff4
    "eor r0, r0, r0, lsl #3\n"
    "add r0, r0, #2\n"     // 0xffc: last word of the page
    "sub r0, r0, #3\n"     // next page
    "bx lr\n");


// Loads and stores with writeback (post-indexed and pre-indexed !) and register moves.
__attribute__((noinline)) static u32 wb(u32 a, u32 b, u32* m, u32 h) {
    u32 p = (u32)m, t, f;
    asm volatile(
        "str %[a], [%[p]], #4\n\t"
        "str %[b], [%[p]], #-8\n\t"
        "ldr %[t], [%[p]], #4\n\t" FOLD
        "add %[h], %[h], %[p]\n\t"
        "ldr %[t], [%[p], #4]!\n\t" FOLD
        "str %[t], [%[p], #-12]!\n\t"
        "add %[h], %[h], %[p], lsl #2\n\t"
        "strb %[a], [%[p]], #1\n\t"
        "strb %[b], [%[p]], #2\n\t"
        "ldrb %[t], [%[p], #-3]!\n\t" FOLD
        "ldrb %[t], [%[p]], #1\n\t" FOLD
        "strb %[h], [%[p], #2]!\n\t"
        "ldr %[t], [%[p], #-3]!\n\t" FOLD
        "sub %[h], %[h], %[p]\n\t"
        "cmp %[a], %[b]\n\tldrhi %[t], [%[p]], #4\n\tstrls %[a], [%[p], #4]!\n\t" FOLD
        "add %[h], %[h], %[p]\n\t"
        "mov %[t], %[a]\n\t" FOLD
        "cmp %[b], #0x8000\n\tmovlo %[t], %[b]\n\t" FOLD
        : [t] "=&r"(t), [f] "=&r"(f), [h] "+&r"(h), [p] "+&r"(p)
        : [a] "r"(a), [b] "r"(b)
        : "cc", "memory");
    return h - (u32)m;
}


// One-register POP {pc} is LDR PC, [SP], #4; also a conditional one.
u32 ldrpop(u32 x);
asm(".text\n.arm\n.global ldrpop\nldrpop:\n"
    "str lr, [sp, #-4]!\n"
    "bl 1f\n"
    "add r0, r0, #5\n"
    "cmp r0, #0x1000\n"
    "ldrhi pc, [sp], #4\n"
    "add r0, r0, r0, lsl #1\n"
    "ldr pc, [sp], #4\n"
    "1: str lr, [sp, #-4]!\n"
    "eor r0, r0, r0, lsr #7\n"
    "ldr pc, [sp], #4\n");


// CMP immediately followed by a conditional branch (fused in the interpreter): every kind of
// CMP operand, taken and not taken, and a conditional BL.
u32 cmpbr(u32 a, u32 b);
asm(".text\n.arm\n.global cmpbr\ncmpbr:\n"
    "push {r4, lr}\n mov r2, #0\n"
    "cmp r0, #0x100\n bhi 1f\n add r2, r2, #1\n1:\n"
    "cmp r0, r1\n blt 2f\n add r2, r2, #2\n2:\n"
    "cmp r1, r0, lsr #3\n bne 3f\n add r2, r2, #4\n3:\n"
    "cmp r0, r1, asr #2\n blcc 9f\n"
    "cmp r1, #0x80000000\n bvs 4f\n add r2, r2, #16\n4:\n"
    "cmp r0, r0\n beq 5f\n add r2, r2, #32\n5:\n"
    "add r0, r2, r0, lsl #6\n pop {r4, pc}\n"
    "9: add r2, r2, #8\n bx lr\n");

static void band(u8* fb, u32 rows, u32 hash) {
    for (u32 y = 0; y < rows; ++y) {
        const u32 bit = (hash >> ((y * 32) / rows)) & 1;
        u8* p = fb + y * 240 * 3;
        for (u32 x = 0; x < 240; ++x) {
            p[0] = p[1] = p[2] = (u8)(bit ? 0xF0 : 0x10);
            p += 3;
        }
    }
}

static void sleep_ns(u32 ns) {
    register u32 r0 asm("r0") = ns;
    register u32 r1 asm("r1") = 0;
    asm volatile("svc 0x0A" : "+r"(r0), "+r"(r1) : : "r2", "r3", "memory");
}

__attribute__((noreturn, section(".text.start"))) void _start(void) {
    u32 x = 0x9E3779B9, h = 0;
    for (u32 i = 0; i < 20000; ++i) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        const u32 a = x;
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        const u32 b = (i & 3) == 0 ? a : x;           // equal operands sometimes
        const u32 c = (i & 7) == 1 ? 0 : x * 2654435761u;
        h = run(a, b, c, (x >> 7) & 7, &mem[32 + (i & 15)], h);
        // big[1024] starts a page: offsets 1016..1032 make some transfers cross it.
        h = (h ^ ldmstm(a, b, c, &big[1016 + (i & 15)])) * 0x9E3779B1u;
        if ((i & 63) == 0)
            h += rec(18 + (i & 1), a) ^ rec_ptr(i & 7, b) ^ thumb_mid(c, rec_ptr);
        h = pagecross(h ^ a);
        h = wb(a, b, &mem[16 + (i & 15)], h);
        h ^= ldrpop(h & 0x1fff);
        h = (h << 3) ^ cmpbr(a ^ (i & 0x1ff), b) ^ (cmpbr(i & 0x3ff, (i * 7) & 0x3ff) * 0x9E3779B1u);
    }
    for (;;) {
        band((u8*)0x1F1E6000, 400, h);
        band((u8*)0x1F48F000, 320, ~h);
        sleep_ns(16000000);
    }
}
