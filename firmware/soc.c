/* ---------------------------------------------------------------------
 * soc.c - Implementacion de los helpers de soc.h
 *
 * Funciones para acceder al framebuffer, al UART y al timer.
 * Pensadas para bare-metal (sin libc, sin malloc).
 * --------------------------------------------------------------------- */
#include "soc.h"

/* ===== Helpers internos ===== */

/* Acceso directo al framebuffer como array de 32-bit words */
static volatile uint32_t * const FB = (volatile uint32_t *)FB_BASE;

/* ===== Framebuffer ===== */

void fb_clear(uint8_t color)
{
    /* Rellena toda la palabra con el mismo nibble repetido 8 veces */
    uint32_t c = color & 0xF;
    uint32_t pattern = c | (c << 4) | (c << 8) | (c << 12) |
                       (c << 16) | (c << 20) | (c << 24) | (c << 28);
    for (int i = 0; i < FB_WORDS; i++) {
        FB[i] = pattern;
    }
}

void fb_putpixel(int x, int y, uint8_t color)
{
    if ((unsigned)x >= FB_WIDTH || (unsigned)y >= FB_HEIGHT) return;
    int idx = y * FB_WIDTH + x;
    int word = idx >> 3;
    int shift = (idx & 7) << 2;
    uint32_t mask = 0xFU << shift;
    /* Read-modify-write: el framebuffer permite lectura desde la CPU */
    FB[word] = (FB[word] & ~mask) | (((uint32_t)(color & 0xF)) << shift);
}

uint8_t fb_getpixel(int x, int y)
{
    if ((unsigned)x >= FB_WIDTH || (unsigned)y >= FB_HEIGHT) return 0;
    int idx = y * FB_WIDTH + x;
    int word = idx >> 3;
    int shift = (idx & 7) << 2;
    return (FB[word] >> shift) & 0xF;
}

void fb_fill_rect(int x, int y, int w, int h, uint8_t color)
{
    /* Recorta a la pantalla */
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > FB_WIDTH)  w = FB_WIDTH  - x;
    if (y + h > FB_HEIGHT) h = FB_HEIGHT - y;
    if (w <= 0 || h <= 0) return;

    for (int yy = y; yy < y + h; yy++) {
        for (int xx = x; xx < x + w; xx++) {
            fb_putpixel(xx, yy, color);
        }
    }
}

void fb_hline(int x, int y, int w, uint8_t color)
{
    fb_fill_rect(x, y, w, 1, color);
}

void fb_vline(int x, int y, int h, uint8_t color)
{
    fb_fill_rect(x, y, 1, h, color);
}

void fb_line(int x0, int y0, int x1, int y1, uint8_t color)
{
    /* Algoritmo de Bresenham */
    int dx = x1 - x0; if (dx < 0) dx = -dx;
    int dy = y1 - y0; if (dy < 0) dy = -dy;
    int sx = (x0 < x1) ? 1 : -1;
    int sy = (y0 < y1) ? 1 : -1;
    int err = dx - dy;
    while (1) {
        fb_putpixel(x0, y0, color);
        if (x0 == x1 && y0 == y1) break;
        int e2 = err << 1;
        if (e2 > -dy) { err -= dy; x0 += sx; }
        if (e2 <  dx) { err += dx; y0 += sy; }
    }
}

void fb_set_palette(int index, uint16_t xrgb)
{
    PALETTE(index) = xrgb & 0xFFF;
}

/* ===== UART ===== */

void uart_putc(char c)
{
    /* Espera a que el TX este libre (bit 0 de UART_STATUS = busy) */
    while (UART_STATUS & 1) { }
    UART_TX_REG = (uint32_t)(uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

void uart_put_hex(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_putc('0');
    uart_putc('x');
    for (int i = 7; i >= 0; i--) {
        uart_putc(hex[(v >> (i * 4)) & 0xF]);
    }
}

/* ===== Tiempo ===== */

uint32_t cycles(void) { return TIMER; }

void delay_cycles(uint32_t n)
{
    uint32_t start = TIMER;
    /* TIMER cuenta a 50 MHz. Comparacion sin signo maneja wrap. */
    while ((uint32_t)(TIMER - start) < n) { }
}

void delay_us(uint32_t us)
{
    /* 50 ciclos por microsegundo (50 MHz) */
    delay_cycles(us * 50U);
}

void delay_ms(uint32_t ms)
{
    /* Bucle por si ms es grande y ms*50000 desborda */
    while (ms--) {
        delay_us(1000);
    }
}
