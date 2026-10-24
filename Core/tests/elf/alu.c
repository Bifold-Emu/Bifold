// Interpreter self-check: runs ARM forms the specialised dyncom handlers cover (and their
// conditional variants) on pseudo-random inputs, folds every result and the NZCV flags into a
// hash, then draws the hash's 32 bits as bands on the top screen.
typedef unsigned char u8;
typedef unsigned int u32;

static u32 mem[64];

#define FOLD "eor %[h], %[t], %[h], ror #7\n\tmrs %[f], cpsr\n\tadd %[h], %[h], %[f], lsr #28\n\t"

__attribute__((noinline)) static u32 run(u32 a, u32 b, u32 c, u32* m, u32 h) {
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
        "b 1f\n\t.ltorg\n1:\n\t"
        : [t] "+&r"(t), [f] "=&r"(f), [h] "+&r"(h)
        : [a] "r"(a), [b] "r"(b), [c] "r"(c), [m] "r"(m)
        : "cc", "memory");
    return h;
}

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
        h = run(a, b, c, &mem[32 + (i & 15)], h);
    }
    for (;;) {
        band((u8*)0x1F1E6000, 400, h);
        band((u8*)0x1F48F000, 320, ~h);
        sleep_ns(16000000);
    }
}
