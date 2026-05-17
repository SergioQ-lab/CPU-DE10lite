#include "soc.h"
#include <stdint.h>
#include <stdbool.h>

#define SDRAM_BASE 0x20000000

// Helper para convertir el numero a hexadecimal en los HEX displays
void hex_display_word(uint32_t word) {
    HEX_REG = word & 0xFFFFFF;
}

int main() {
    uart_puts("\r\n============================\r\n");
    uart_puts("   SDRAM CONTROLLER TEST    \r\n");
    uart_puts("============================\r\n\r\n");

    // Configurar paleta de colores basicos
    fb_set_palette(0, 0x000); // Negro
    fb_set_palette(1, 0x0F0); // Verde
    fb_set_palette(2, 0xF00); // Rojo

    // Limpiar pantalla
    fb_clear(0);
    LEDR = 0x000;
    hex_display_word(0x000000);

    volatile uint16_t* sdram = (volatile uint16_t*)SDRAM_BASE;

    uart_puts("Paso 1: Escribiendo patron de prueba en SDRAM...\r\n");
    
    // Escribimos valores en varias posiciones de la SDRAM
    sdram[0] = 0xAAAA;
    sdram[1] = 0x5555;
    sdram[2] = 0x1234;
    sdram[1000] = 0xDEAD;
    sdram[5000] = 0xBEEF;
    sdram[8000000] = 0xCAFE; // Direccion lejana para probar bancos/filas

    uart_puts("Paso 2: Leyendo y verificando...\r\n");

    int errors = 0;

    if (sdram[0] != 0xAAAA) { uart_puts("ERROR: sdram[0] falla.\r\n"); errors++; }
    if (sdram[1] != 0x5555) { uart_puts("ERROR: sdram[1] falla.\r\n"); errors++; }
    if (sdram[2] != 0x1234) { uart_puts("ERROR: sdram[2] falla.\r\n"); errors++; }
    if (sdram[1000] != 0xDEAD) { uart_puts("ERROR: sdram[1000] falla.\r\n"); errors++; }
    if (sdram[5000] != 0xBEEF) { uart_puts("ERROR: sdram[5000] falla.\r\n"); errors++; }
    if (sdram[8000000] != 0xCAFE) { uart_puts("ERROR: sdram[8000000] falla.\r\n"); errors++; }

    if (errors == 0) {
        uart_puts("\r\n============================\r\n");
        uart_puts("  RESULTADO: EXITO TOTAL!   \r\n");
        uart_puts("============================\r\n");
        
        // Efecto visual de exito
        LEDR = 0x3FF; // Todos los LEDs encendidos
        hex_display_word(0x111111); // Mostrar algun patron
        
        for (int x = 0; x < FB_WIDTH; x++) {
            for (int y = 0; y < FB_HEIGHT; y++) {
                fb_putpixel(x, y, 1); // 1 = Verde
            }
        }
    } else {
        uart_puts("\r\n============================\r\n");
        uart_puts("  RESULTADO: FALLO          \r\n");
        uart_puts("============================\r\n");
        
        LEDR = 0x001; // Solo el primer LED
        hex_display_word(0xEEEEEE); // EEEEEE de Error
        
        for (int x = 0; x < FB_WIDTH; x++) {
            for (int y = 0; y < FB_HEIGHT; y++) {
                fb_putpixel(x, y, 2); // 2 = Rojo
            }
        }
    }

    // Bucle infinito
    while (1) {
        // Blink LEDs para indicar que la CPU sigue viva
        delay_ms(500);
        LEDR ^= 0x3FF; 
    }

    return 0;
}