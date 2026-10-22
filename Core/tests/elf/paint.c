// Draws animated colour bars straight into the default 3DS framebuffers in VRAM
// (top 0x181E6000, bottom 0x1848F000 physical = 0x1F1E6000 / 0x1F48F000 virtual, RGB8 stored
// as B,G,R, rotated: 240 bytes-triplets per row, 400 resp. 320 rows). Lets the frontend's
// presentation path be checked without libctru or a GPU command list.
typedef unsigned char u8;
typedef unsigned int u32;

static const u8 palette[8][3] = {
    {0x30, 0x30, 0xE0}, {0x30, 0xA0, 0xF0}, {0x40, 0xE0, 0x40}, {0xE0, 0xE0, 0x30},
    {0xF0, 0x80, 0x30}, {0xE0, 0x30, 0x30}, {0xC0, 0x30, 0xC0}, {0xF0, 0xF0, 0xF0},
};

static void sleep_ns(u32 ns) {
    register u32 r0 asm("r0") = ns;
    register u32 r1 asm("r1") = 0;
    asm volatile("svc 0x0A" : "+r"(r0), "+r"(r1) : : "r2", "r3", "memory");
}

#ifdef SOLID
// Single flat colour (0xRRGGBB): used to tell a base title from its update in the CIA tests.
static const u8 solid[3] = {(SOLID >> 16) & 0xFF, (SOLID >> 8) & 0xFF, SOLID & 0xFF};
#endif

static void fill(u8* fb, u32 rows, u32 frame, u32 shift) {
    for (u32 y = 0; y < rows; ++y) {
#ifdef SOLID
        {
            u8* q = fb + y * 240 * 3;
            for (u32 x = 0; x < 240; ++x) {
                q[0] = solid[2];
                q[1] = solid[1];
                q[2] = solid[0];
                q += 3;
            }
            continue;
        }
#endif
        const u8* c = palette[((y >> shift) + frame) & 7];
        u8* p = fb + y * 240 * 3;
        for (u32 x = 0; x < 240; ++x) {
            // Darken towards one edge so the orientation is visible.
            const u32 k = 128 + (x >> 1);
            p[0] = (u8)((c[2] * k) >> 8); // B
            p[1] = (u8)((c[1] * k) >> 8); // G
            p[2] = (u8)((c[0] * k) >> 8); // R
            p += 3;
        }
    }
}

__attribute__((noreturn, section(".text.start"))) void _start(void) {
    u32 frame = 0;
    for (;;) {
        fill((u8*)0x1F1E6000, 400, frame, 5);       // top: vertical bars moving sideways
        fill((u8*)0x1F48F000, 320, frame >> 2, 6);  // bottom: wider bars, slower
        ++frame;
        sleep_ns(16000000);
    }
}
