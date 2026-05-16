/* ---------------------------------------------------------------------
 * main.c - TEST AISLADO de la division/modulo
 *
 * Hipotesis: tu CPU se cuelga cuando ejecuta DIV/REM, por eso el snake
 * se queda en HEX=000000 (random_coord usa % y la CPU nunca sale).
 *
 * Test:
 *   1) LED splash + HEX 0xABCDEF
 *   2) Marcador antes de dividir: LED 9 + HEX 0x111111
 *   3) Hace una division (100 / 32 = 3, 100 %% 32 = 4) con volatiles
 *      (el compilador NO puede pre-calcular)
 *   4) Si la division retorna, muestra el resultado en LEDs y HEX
 *
 * Esperado SI el divisor funciona:
 *   - LEDs: 0x134 (LED 8 = post-div marker, LEDs 5,4 = q=3, LED 2 = r=4)
 *   - HEX:  000304  (q=3 en HEX2, r=4 en HEX0)
 *
 * Esperado SI el divisor cuelga:
 *   - LEDs quedan en 0x200 (solo LED 9)
 *   - HEX queda en 111111
 *   - La CPU se cuelga, no avanza nunca
 * --------------------------------------------------------------------- */
#include "soc.h"

static inline void delay(uint32_t iters)
{
    __asm__ volatile (
        "1: addi %0, %0, -1\n"
        "   bne  %0, zero, 1b\n"
        : "+r" (iters)
    );
}

void main(void)
{
    /* Splash inicial */
    LEDR    = 0x3FF;
    HEX_REG = 0xABCDEF;
    delay(5000000);

    /* Marcador antes de dividir */
    LEDR    = 0x200;       /* LED 9 ON: pre-division */
    HEX_REG = 0x111111;
    delay(5000000);

    /* Operandos volatiles para que el compilador NO los pre-calcule */
    volatile int a = 100;
    volatile int b = 32;

    /* Division: 100 / 32 = 3, resto 100 %% 32 = 4 */
    int q = a / b;
    int r = a % b;

    /* Si llegamos aqui, las operaciones DIV y REM funcionaron */
    LEDR    = 0x100 | ((q & 0xF) << 4) | (r & 0xF);
    /* 0x100 | 0x30 | 0x04 = 0x134:
     *   LED 8 = post-division marker
     *   LEDs 5,4 = q = 3 (0011)
     *   LED 2   = r = 4 (0100) */
    HEX_REG = (q << 8) | r;   /* HEX2..HEX0 = 304 */

    while (1) { }
}
