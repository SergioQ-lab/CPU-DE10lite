/* ---------------------------------------------------------------------
 * main.c - Demo del SoC RISC-V sin UART
 *
 * Verifica:
 *  1) LEDs/HEX (MMIO basico)
 *  2) Framebuffer VGA - confirma el fix de alineacion byte->word
 *     (las escrituras secuenciales FB[i] = ... deben rellenar la
 *     pantalla SIN huecos de 3 palabras entre cada una)
 *
 * Sin UART para evitar el bug del busy atascado mientras lo arreglamos.
 *
 * Comportamiento esperado:
 *  - Al arrancar (o pulsar KEY[0]): LEDR = 0x3FF (todos los 10 LEDs ON)
 *  - Despues: pinta la pantalla con un patron de rectangulos solidos
 *    + diagonal + borde -> si se ven sin huecos, el bug esta resuelto
 *  - Mientras tanto: HEX5..HEX0 muestran un contador hexadecimal que
 *    avanza despacio, prueba de que la CPU sigue ejecutando
 *  - SW[3:0] cambia el color del fondo en vivo
 * --------------------------------------------------------------------- */
#include "soc.h"

/* Atajos a colores de la paleta inicial */
enum {
    C_BLACK = 0,  C_DRED  = 1,  C_DGRN  = 2,  C_DYEL  = 3,
    C_DBLU  = 4,  C_DMAG  = 5,  C_DCYA  = 6,  C_LGRY  = 7,
    C_DGRY  = 8,  C_RED   = 9,  C_GRN   = 10, C_YEL   = 11,
    C_BLU   = 12, C_MAG   = 13, C_CYA   = 14, C_WHT   = 15
};

/* Delay corto usando bucle de assembly puro (no depende del timer) */
static inline void busy_wait(uint32_t iters)
{
    __asm__ volatile (
        "1: addi %0, %0, -1 \n"
        "   bne  %0, zero, 1b \n"
        : "+r" (iters)
    );
}

/* Pinta la escena completa de prueba con el color de fondo elegido */
static void draw_scene(uint8_t bg)
{
    /* Fondo - test critico del fix: rellenar 8000 words secuenciales.
     * Si el bug de alineacion persistiera, solo veriamos rayas
     * horizontales con huecos (las direcciones se interpretan como word
     * en lugar de byte) o nada. Tras el fix, debe quedar uniforme. */
    fb_clear(bg);

    /* Borde blanco (4 pixeles) */
    fb_fill_rect(0,             0,             FB_WIDTH, 4, C_WHT);
    fb_fill_rect(0,             FB_HEIGHT - 4, FB_WIDTH, 4, C_WHT);
    fb_fill_rect(0,             0,             4, FB_HEIGHT, C_WHT);
    fb_fill_rect(FB_WIDTH - 4,  0,             4, FB_HEIGHT, C_WHT);

    /* 6 rectangulos de colores en cuadricula 3x2 */
    fb_fill_rect( 20,  20, 40, 40, C_RED);
    fb_fill_rect( 80,  20, 40, 40, C_GRN);
    fb_fill_rect(140,  20, 40, 40, C_BLU);
    fb_fill_rect( 20,  80, 40, 40, C_YEL);
    fb_fill_rect( 80,  80, 40, 40, C_MAG);
    fb_fill_rect(140,  80, 40, 40, C_CYA);

    /* Triangulo formado por 3 lineas de Bresenham */
    fb_line(220,  30, 290, 110, C_WHT);
    fb_line(290, 110, 200, 110, C_WHT);
    fb_line(200, 110, 220,  30, C_WHT);

    /* Diagonal pixel-a-pixel (prueba que putpixel funciona con
     * read-modify-write sin pisar pixeles vecinos del mismo word) */
    for (int i = 0; i < 30; i++) {
        fb_putpixel(220 + i, 140 + i, C_LGRY);
    }
}

void main(void)
{
    /* Splash: enciende los 10 LEDs para confirmar arranque */
    LEDR = 0x3FF;
    busy_wait(2000000);     /* ~40 ms a 50 MHz */
    LEDR = 0;

    /* Pinta la escena inicial */
    draw_scene(C_DGRY);

    /* Estado guardado para detectar cambios en los switches */
    uint32_t last_sw = 0xFFFFFFFF;
    uint32_t tick    = 0;

    while (1) {
        /* Si cambian los switches, redibuja con el nuevo fondo */
        uint32_t sw = SWITCHES & 0xF;
        if (sw != last_sw) {
            last_sw = sw;
            draw_scene((uint8_t)sw);
        }

        /* HEX displays: muestra el tick para ver que la CPU vive */
        HEX_REG = tick & 0x00FFFFFF;
        LEDR    = tick & 0x3FF;
        tick++;

        /* Retardo entre iteraciones (~30 ms) */
        busy_wait(1500000);
    }
}
