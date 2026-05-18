/* ---------------------------------------------------------------------
 * soc.h - Definiciones del SoC RISC-V para DE10-Lite.
 *
 * Mapa de memoria, registros MMIO, helpers para framebuffer y UART.
 * --------------------------------------------------------------------- */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

/* ===== Mapa de memoria ===== */
#define MMIO_BASE       0xF0000000U
#define FB_BASE         0x10000000U
#define FB_WIDTH        320
#define FB_HEIGHT       200
#define FB_PIXELS       (FB_WIDTH * FB_HEIGHT)
#define FB_WORDS        (FB_PIXELS / 8)         /* 8 pixeles por word de 32b */

/* ===== Registros MMIO ===== */
/* Acceso volatil obligatorio - el compilador no debe reordenar/cachear */
#define REG(offset)     (*(volatile uint32_t *)(MMIO_BASE + (offset)))

#define LEDR            REG(0x00)   /* W: bits[9:0] -> 10 LEDs rojos */
#define SWITCHES        REG(0x04)   /* R: bits[9:0] -> estado switches */
#define KEYS            REG(0x08)   /* R: bits[1:0] -> KEY[1], KEY[0] (KEY0 = reset) */
#define HEX_REG         REG(0x0C)   /* W: 24 bits = 6 nibbles (HEX5..HEX0) */
#define UART_TX_REG     REG(0x10)   /* W: byte a transmitir */
#define UART_STATUS     REG(0x14)   /* R: bit 0 = busy */
#define TIMER           REG(0x18)   /* R: contador libre 32b @ 50 MHz */
#define JOYSTICK        REG(0x1C)   /* R: bits[6:0] -> joystick UP, DOWN, LEFT, RIGHT, MID, SET, RST */

/* Paleta de 16 entradas (escritura). Cada entrada = 12 bits xRGB. */
#define PALETTE(i)      REG(0x20 + ((i) & 0xF) * 4)

/* Contadores de performance del D-cache (solo lectura). */
#define CACHE_HITS      REG(0x60)   /* R: 32-bit hit count, monotonico */
#define CACHE_MISSES    REG(0x64)   /* R: 32-bit miss count, monotonico */

/* Empaqueta xRGB de 12 bits desde componentes 0..15 */
#define RGB12(r, g, b)  ((((r) & 0xF) << 8) | (((g) & 0xF) << 4) | ((b) & 0xF))

/* ===== Constantes utiles ===== */
#define CPU_HZ          50000000U  /* 50 MHz */

/* ===== API del framebuffer ===== */
void fb_clear(uint8_t color);
void fb_putpixel(int x, int y, uint8_t color);
uint8_t fb_getpixel(int x, int y);
void fb_fill_rect(int x, int y, int w, int h, uint8_t color);
void fb_hline(int x, int y, int w, uint8_t color);
void fb_vline(int x, int y, int h, uint8_t color);
void fb_line(int x0, int y0, int x1, int y1, uint8_t color);

/* Cambia una entrada de la paleta (0..15, color = xRGB 12 bits) */
void fb_set_palette(int index, uint16_t xrgb);

/* ===== UART ===== */
void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_hex(uint32_t v);

/* ===== Tiempo / retardo ===== */
uint32_t cycles(void);
void delay_cycles(uint32_t n);
void delay_us(uint32_t us);
void delay_ms(uint32_t ms);

#endif /* SOC_H */
