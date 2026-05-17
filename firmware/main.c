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

    uart_puts("Paso 1: Escribiendo patron de prueba...\r\n");
    
    sdram[0] = 0x1234;
    
    uart_puts("Paso 2: Leyendo patron...\r\n");
    uint16_t rdata = sdram[0];

    if (rdata == 0x1234) {
        uart_puts("  RESULTADO: EXITO! \r\n");
        LEDR = 0x3FF; 
        hex_display_word(0x111111);
        
        for (int x = 0; x < FB_WIDTH; x++) {
            for (int y = 0; y < FB_HEIGHT; y++) {
                fb_putpixel(x, y, 1); // Verde
            }
        }
    } else {
        uart_puts("  RESULTADO: FALLO! \r\n");
        LEDR = 0x001; 
        // Mostramos en los displays exactamente lo que se leyo
        hex_display_word(rdata);
        
        for (int x = 0; x < FB_WIDTH; x++) {
            for (int y = 0; y < FB_HEIGHT; y++) {
                fb_putpixel(x, y, 2); // Rojo
            }
        }
    }

    // Bucle infinito
    while (1) {
        delay_ms(500);
        LEDR ^= 0x3FF; 
    }

    return 0;
}