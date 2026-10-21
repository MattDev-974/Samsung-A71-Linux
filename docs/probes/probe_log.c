/* Render the tail of the ramoops console zone straight from physical RAM.
 * Runs as a uniLoader payload (MMU off), so it can read what the previous
 * kernel left behind even after a warm reset. */
#include "font8x8.h"

#define FB      ((volatile unsigned int *)0x9c000000UL)
#define W       1080
#define H       2400
#define RAMO    0xa1380000UL   /* console zone: base + 0x80000 */
#define RAMO_SZ 0x40000UL

#define COLS 60
#define ROWS 25

static void px(int x, int y, unsigned int c)
{
    if (x >= 0 && x < W && y >= 0 && y < H)
        FB[y * W + x] = c;
}

static void glyph(int col, int row, unsigned char ch)
{
    const unsigned char *g;
    int x = col * 16, y = row * 16, r, b;

    if (ch < 32 || ch > 126)
        ch = 32;
    g = &font8x8[ch * 8];          /* font has all 256 glyphs */
    for (r = 0; r < 8; r++) {
        for (b = 0; b < 8; b++) {
            if (g[r] & (1 << b)) {
                px(x + b * 2,     y + r * 2,     0xffffffff);
                px(x + b * 2 + 1, y + r * 2,     0xffffffff);
                px(x + b * 2,     y + r * 2 + 1, 0xffffffff);
                px(x + b * 2 + 1, y + r * 2 + 1, 0xffffffff);
            }
        }
    }
}

void _start(void)
{
    const unsigned char *z = (const unsigned char *)RAMO;
    long end = RAMO_SZ - 1, start;
    int i;

    while (end > 0 && z[end] == 0)
        end--;
    start = end - (COLS * ROWS) + 1;
    if (start < 0)
        start = 0;

    for (i = 0; i < W * H; i++)
        FB[i] = 0;

    for (i = 0; i < COLS * ROWS; i++)
        glyph(i % COLS, i / COLS, z[start + i]);

    for (;;)
        ;
}
