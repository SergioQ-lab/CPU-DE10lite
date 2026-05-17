#include "soc.h"
#include <stdint.h>

#define SDRAM_BASE 0x20000000

/*
 * Diagnostico SDRAM: distingue bugs de WRITE vs READ.
 *
 * Escribe 3 patrones distintos en 3 direcciones, los lee a variables
 * locales (todas las lecturas ocurren despues de todas las escrituras),
 * y luego permite inspeccionar cada valor leido por separado.
 *
 * Codigo de colores en pantalla:
 *   Verde brillante  -> los 3 OK (SDRAM funciona)
 *   Rojo brillante   -> los 3 fallan con el MISMO valor leido
 *                      => bug en WRITE (siempre devuelve constante)
 *   Azul brillante   -> fallan con valores distintos
 *                      => bug en READ / direccionamiento
 *   Amarillo         -> mezcla (algunos OK, otros no)
 *
 * LEDR muestra un bitmap del resultado (bit i = 1 si lectura i OK).
 * HEX cicla entre los 3 valores leidos: cambia con KEY1.
 *   Pulsacion 0: hex = read[0]  (esperado 0x1234)
 *   Pulsacion 1: hex = read[1]  (esperado 0x5678)
 *   Pulsacion 2: hex = read[2]  (esperado 0xCAFE)
 *   Pulsacion 3: hex = 0xAAAA si test global fallo, 0xEEEEEE si OK
 */

#define EXP0 0x1234
#define EXP1 0x5678
#define EXP2 0xCAFE

static void uart_hex16(uint16_t v) {
    static const char hex[] = "0123456789ABCDEF";
    uart_putc('0'); uart_putc('x');
    uart_putc(hex[(v >> 12) & 0xF]);
    uart_putc(hex[(v >>  8) & 0xF]);
    uart_putc(hex[(v >>  4) & 0xF]);
    uart_putc(hex[(v >>  0) & 0xF]);
}

int main(void) {
    uart_puts("\r\n=== SDRAM DIAG (multi-valor) ===\r\n");

    fb_set_palette(0, 0x000); // negro
    fb_set_palette(1, 0x0F0); // verde
    fb_set_palette(2, 0xF00); // rojo
    fb_set_palette(3, 0x00F); // azul
    fb_set_palette(4, 0xFF0); // amarillo
    fb_clear(0);
    LEDR = 0;
    HEX_REG = 0;

    volatile uint16_t *sdram = (volatile uint16_t *)SDRAM_BASE;

    /* ===== FASE 1: ESCRIBIR LAS 3 ===== */
    uart_puts("WR sdram[0]=0x1234\r\n");
    sdram[0] = EXP0;
    uart_puts("WR sdram[1]=0x5678\r\n");
    sdram[1] = EXP1;
    uart_puts("WR sdram[2]=0xCAFE\r\n");
    sdram[2] = EXP2;

    /* ===== FASE 2: LEER LAS 3 (todas despues de los writes) ===== */
    uint16_t r0 = sdram[0];
    uint16_t r1 = sdram[1];
    uint16_t r2 = sdram[2];

    uart_puts("RD sdram[0]="); uart_hex16(r0);
    uart_puts(" (exp 0x1234)\r\n");
    uart_puts("RD sdram[1]="); uart_hex16(r1);
    uart_puts(" (exp 0x5678)\r\n");
    uart_puts("RD sdram[2]="); uart_hex16(r2);
    uart_puts(" (exp 0xCAFE)\r\n");

    /* ===== FASE 3: DIAGNOSTICO ===== */
    int ok0 = (r0 == EXP0);
    int ok1 = (r1 == EXP1);
    int ok2 = (r2 == EXP2);
    int n_ok = ok0 + ok1 + ok2;

    /* LEDR: bit0=ok0, bit1=ok1, bit2=ok2, bit9=todo OK */
    uint32_t leds = (ok0 ? 1 : 0) | (ok1 ? 2 : 0) | (ok2 ? 4 : 0);
    if (n_ok == 3) leds |= 0x200;
    LEDR = leds;

    uint8_t color;
    if (n_ok == 3) {
        color = 1; /* verde */
        uart_puts("DIAG: SDRAM OK\r\n");
    } else if (n_ok == 0 && r0 == r1 && r1 == r2) {
        color = 2; /* rojo: las 3 lecturas iguales y mal => WRITE roto */
        uart_puts("DIAG: las 3 lecturas iguales => WRITE roto o bus contention\r\n");
    } else if (n_ok == 0) {
        color = 3; /* azul: lecturas distintas pero todas mal => READ/addr */
        uart_puts("DIAG: lecturas distintas pero ninguna correcta => READ timing o addr\r\n");
    } else {
        color = 4; /* amarillo: mezcla */
        uart_puts("DIAG: mezcla, algunas OK\r\n");
    }

    for (int y = 0; y < FB_HEIGHT; y++)
        for (int x = 0; x < FB_WIDTH; x++)
            fb_putpixel(x, y, color);

    /* ===== FASE 4: CICLADO INTERACTIVO ===== */
    /* KEY1 (KEY bit 1) cicla entre las 4 vistas. Activo en bajo. */
    int view = 0;
    int prev_key = 1;
    HEX_REG = r0;

    while (1) {
        int key1 = (KEYS >> 1) & 1;
        if (prev_key == 1 && key1 == 0) {
            view = (view + 1) & 3;
            switch (view) {
                case 0: HEX_REG = r0; break;
                case 1: HEX_REG = r1; break;
                case 2: HEX_REG = r2; break;
                case 3: HEX_REG = (n_ok == 3) ? 0xEEEEEE : 0xAAAAAA; break;
            }
        }
        prev_key = key1;
        delay_ms(10);
    }
    return 0;
}
