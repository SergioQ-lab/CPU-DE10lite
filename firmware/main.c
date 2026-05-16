/* ---------------------------------------------------------------------
 * main.c - Demo completo del SoC RISC-V (sin UART)
 *
 * Funcionalidad:
 *  - Limpia la pantalla al arrancar para no heredar contenido viejo
 *  - Dibuja una escena estatica (rectangulos de colores + lineas + ...)
 *  - Anima un cuadrado que rebota dentro del area util
 *  - SW[3:0] cambian el color de fondo en vivo (redibuja todo)
 *  - SW[4] cambia el modo de la animacion
 *  - HEX5..HEX0 muestran el contador de frames en hex
 *  - LEDs muestran los bits bajos del contador (efecto Knight Rider)
 * --------------------------------------------------------------------- */
#include "soc.h"

/* Atajos a la paleta inicial */
enum {
    C_BLACK = 0,  C_DRED  = 1,  C_DGRN  = 2,  C_DYEL  = 3,
    C_DBLU  = 4,  C_DMAG  = 5,  C_DCYA  = 6,  C_LGRY  = 7,
    C_DGRY  = 8,  C_RED   = 9,  C_GRN   = 10, C_YEL   = 11,
    C_BLU   = 12, C_MAG   = 13, C_CYA   = 14, C_WHT   = 15
};

static inline void delay(uint32_t iters)
{
    __asm__ volatile (
        "1: addi %0, %0, -1\n"
        "   bne  %0, zero, 1b\n"
        : "+r" (iters)
    );
}

/* Pinta la escena estatica de fondo. Se redibuja cuando cambian los
 * switches que modifican el color de fondo. */
static void draw_scene(uint8_t bg)
{
    fb_clear(bg);

    /* Borde blanco de 3 pixeles */
    fb_fill_rect(0,             0,             FB_WIDTH, 3, C_WHT);
    fb_fill_rect(0,             FB_HEIGHT - 3, FB_WIDTH, 3, C_WHT);
    fb_fill_rect(0,             0,             3, FB_HEIGHT, C_WHT);
    fb_fill_rect(FB_WIDTH - 3,  0,             3, FB_HEIGHT, C_WHT);

    /* Paleta de demostracion: 16 cuadrados con los 16 colores */
    for (int i = 0; i < 16; i++) {
        int cx = 10 + (i % 8) * 18;
        int cy = 12 + (i / 8) * 18;
        fb_fill_rect(cx, cy, 14, 14, (uint8_t)i);
    }

    /* Triangulo con lineas Bresenham */
    fb_line(220,  20, 290, 100, C_WHT);
    fb_line(290, 100, 200, 100, C_WHT);
    fb_line(200, 100, 220,  20, C_WHT);

    /* Texto pixel-art "RV32IM" rudimentario - solo puntos diagonales */
    for (int i = 0; i < 30; i++) {
        fb_putpixel(220 + i, 140 + i, C_LGRY);
        fb_putpixel(220 + i, 169 - i, C_LGRY);
    }

    /* Linea horizontal de muestra */
    fb_line(10, 180, 180, 180, C_YEL);
}

void main(void)
{
    /* Limpia siempre al arrancar para no heredar contenido del run
     * anterior (la BRAM del FB persiste durante un reset de CPU). */
    fb_clear(C_BLACK);

    /* Splash en LEDs */
    LEDR = 0x3FF;
    delay(5000000);   /* ~0.4 s */
    LEDR = 0;

    /* Pinta la escena inicial */
    draw_scene(C_DGRY);

    /* Estado del cuadrado que rebota */
    int sq_x = 50, sq_y = 130;
    int sq_dx = 1, sq_dy = 1;
    const int sq_sz = 12;
    uint8_t sq_color = C_RED;

    uint32_t tick = 0;
    uint32_t last_sw = 0xFFFFFFFF;
    uint8_t  bg = C_DGRY;

    while (1) {
        /* Lee switches: si SW[3:0] cambia, redibuja con nuevo fondo */
        uint32_t sw = SWITCHES;
        uint32_t sw_color = sw & 0xF;
        if (sw_color != (last_sw & 0xF)) {
            bg = (uint8_t)sw_color;
            draw_scene(bg);
        }
        last_sw = sw;

        /* Borra cuadrado anterior pintandolo del color de fondo */
        fb_fill_rect(sq_x, sq_y, sq_sz, sq_sz, bg);

        /* Avanza la posicion */
        sq_x += sq_dx;
        sq_y += sq_dy;

        /* Rebote contra los bordes utiles (deja margen de 4 px) */
        if (sq_x <= 4)                     { sq_dx =  1; sq_color = ((sq_color + 1) & 0xF); if (sq_color == 0) sq_color = 1; }
        if (sq_x + sq_sz >= FB_WIDTH - 4)  { sq_dx = -1; sq_color = ((sq_color + 1) & 0xF); if (sq_color == 0) sq_color = 1; }
        if (sq_y <= 4)                     { sq_dy =  1; sq_color = ((sq_color + 1) & 0xF); if (sq_color == 0) sq_color = 1; }
        if (sq_y + sq_sz >= FB_HEIGHT - 4) { sq_dy = -1; sq_color = ((sq_color + 1) & 0xF); if (sq_color == 0) sq_color = 1; }

        /* Pinta el cuadrado en la nueva posicion */
        fb_fill_rect(sq_x, sq_y, sq_sz, sq_sz, sq_color);

        /* Contador en HEX5..HEX0 */
        HEX_REG = tick & 0x00FFFFFF;

        /* Knight Rider en los LEDs (un bit que se mueve ida y vuelta) */
        uint32_t phase = tick & 0xF;          /* 0..15 */
        uint32_t pos   = phase < 8 ? phase : 14 - phase; /* 0..7..1..0 ping-pong, pero limitado a 9 */
        if (pos > 9) pos = 9;
        LEDR = 1u << pos;

        tick++;

        /* Frame rate: ~30 FPS */
        delay(400000);
    }
}
