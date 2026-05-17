#include "soc.h"

/* Colores y tamaño de la cuadricula */
#define GRID_SZ  10
#define COLS     (FB_WIDTH / GRID_SZ)
#define ROWS     (FB_HEIGHT / GRID_SZ)
#define MAX_LEN  100

/* Indices de la paleta original */
enum {
    C_BLACK = 0, C_DRED = 1, C_DGRN = 2, C_DYEL = 3,
    C_DBLU = 4, C_DMAG = 5, C_DCYA = 6, C_LGRY = 7,
    C_DGRY = 8, C_RED = 9, C_GRN = 10, C_YEL = 11,
    C_BLU = 12, C_MAG = 13, C_CYA = 14, C_WHT = 15
};

/* Variables globales del estado del juego */
int snake_x[MAX_LEN];
int snake_y[MAX_LEN];
int snake_len;
int dir_x, dir_y;
int apple_x, apple_y;

/* Generador pseudo-aleatorio usando el contador de hardware libre a 50MHz */
int random_coord(int max) {
    uint32_t r = TIMER; 
    /* Como tu CPU tiene división por hardware (~34 ciclos), usamos módulo sin problema */
    return r % max;
}

void init_game() {
    fb_clear(C_BLACK);
    
    snake_len = 4;
    dir_x = 1;
    dir_y = 0;
    
    /* Crear la serpiente inicial en el centro */
    for (int i = 0; i < snake_len; i++) {
        snake_x[i] = (COLS / 2) - i;
        snake_y[i] = ROWS / 2;
    }
    
    /* Generar primera manzana */
    apple_x = random_coord(COLS);
    apple_y = random_coord(ROWS);
    
    /* Enviar la puntuacion inicial a los displays de 7 segmentos */
    HEX_REG = snake_len;
}

void main(void)
{
    /* Saludo visual para confirmar reset */
    LEDR = 0x3FF;
    delay_ms(200);
    LEDR = 0;

    /* Bucle infinito del sistema (para reiniciar el juego al perder) */
    while (1) {
        init_game();
        int game_over = 0;

        /* Pinta la manzana inicial */
        fb_fill_rect(apple_x * GRID_SZ, apple_y * GRID_SZ, GRID_SZ, GRID_SZ, C_RED);

        while (!game_over) {
            /* 1. LEER CONTROLES (Joystick Digital) */
            /* Control (activo en bajo):
             * Bit 6 = UP
             * Bit 5 = DOWN
             * Bit 4 = LEFT
             * Bit 3 = RIGHT
             */
            uint32_t joy = JOYSTICK;
            
            /* Evitamos que la serpiente se de la vuelta sobre si misma (180 grados) */
            if      (!(joy & (1 << 6)) && dir_y == 0) { dir_x =  0; dir_y = -1; } /* UP */
            else if (!(joy & (1 << 5)) && dir_y == 0) { dir_x =  0; dir_y =  1; } /* DOWN */
            else if (!(joy & (1 << 4)) && dir_x == 0) { dir_x = -1; dir_y =  0; } /* LEFT */
            else if (!(joy & (1 << 3)) && dir_x == 0) { dir_x =  1; dir_y =  0; } /* RIGHT */

            /* 2. CALCULAR NUEVA POSICIÓN DE LA CABEZA */
            int next_x = snake_x[0] + dir_x;
            int next_y = snake_y[0] + dir_y;

            /* 3. COLISIONES */
            /* Chocar contra los bordes de la pantalla */
            if (next_x < 0 || next_x >= COLS || next_y < 0 || next_y >= ROWS) {
                game_over = 1;
            }
            
            /* Chocar contra el propio cuerpo */
            for (int i = 0; i < snake_len; i++) {
                if (snake_x[i] == next_x && snake_y[i] == next_y) {
                    game_over = 1;
                }
            }

            if (game_over) {
                /* Animación de derrota y volver a empezar */
                fb_clear(C_DRED);
                delay_ms(1500);
                break; 
            }

            /* 4. ACTUALIZAR MATRIZ EN MEMORIA (Arrastrar el cuerpo) */
            int tail_x = snake_x[snake_len - 1];
            int tail_y = snake_y[snake_len - 1];

            /* Desplazamos hasta snake_len (inclusive) para no perder la cola vieja
               en caso de que comamos una manzana y snake_len aumente. */
            for (int i = snake_len; i > 0; i--) {
                snake_x[i] = snake_x[i - 1];
                snake_y[i] = snake_y[i - 1];
            }
            snake_x[0] = next_x;
            snake_y[0] = next_y;

            /* 5. LÓGICA DE LA MANZANA */
            if (next_x == apple_x && next_y == apple_y) {
                /* Comer manzana: aumentamos tamaño */
                if (snake_len < MAX_LEN) snake_len++;
                HEX_REG = snake_len; /* Actualiza marcador */
                
                /* Nueva manzana aleatoria */
                apple_x = random_coord(COLS);
                apple_y = random_coord(ROWS);
                fb_fill_rect(apple_x * GRID_SZ, apple_y * GRID_SZ, GRID_SZ, GRID_SZ, C_RED);
            } else {
                /* Si no come, borramos el pixel de la cola antigua para simular movimiento */
                fb_fill_rect(tail_x * GRID_SZ, tail_y * GRID_SZ, GRID_SZ, GRID_SZ, C_BLACK);
            }

            /* 6. DIBUJAR CABEZA EN NUEVA POSICIÓN */
            fb_fill_rect(next_x * GRID_SZ, next_y * GRID_SZ, GRID_SZ, GRID_SZ, C_GRN);

            /* 7. VELOCIDAD (Frames per second) */
            delay_ms(100); 
        }
    }
}