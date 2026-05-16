#include "soc.h"

void main(void)
{
    /* Saludo inicial en los LEDs */
    LEDR = 0x3FF;
    
    /* Retardo 1: Bucle directamente en ensamblador dentro de un registro */
    uint32_t d1 = 2000000;
    __asm__ volatile (
        "1: addi %0, %0, -1 \n"  /* Resta 1 al registro */
        "   bne  %0, zero, 1b \n" /* Si no es cero, salta hacia atras (1b = label 1 backward) */
        : "+r" (d1)
    );
    
    LEDR = 0;

    /* Variable del contador */
    uint32_t contador = 0;

    while (1) {
        HEX_REG = contador & 0xFFFFFF;
        LEDR = contador & 0x3FF;
        contador++;

        /* Retardo 2: El mismo bucle antibalas */
        uint32_t d2 = 2500000;
        __asm__ volatile (
            "1: addi %0, %0, -1 \n"
            "   bne  %0, zero, 1b \n"
            : "+r" (d2)
        );
    }
}