#include "soc.h"
#include <stdint.h>

#define SDRAM_BASE 0x20000000U
#define SDRAM_W    ((volatile uint32_t *)SDRAM_BASE)
#define SDRAM_H    ((volatile uint16_t *)SDRAM_BASE)

/*
 * D-cache test + benchmark
 *
 * Fase A — CORRECTITUD
 *   Escribe N palabras de 32 bits con un patron derivado de la direccion y
 *   las lee de vuelta. Verifica que cada lectura coincide. Esto valida que:
 *     - El cache devuelve los datos correctos en hits y misses.
 *     - El write-through actualiza tanto el cache como la SDRAM.
 *     - LW/SW de 32 bits funciona (antes estaba roto, replicaba halfwords).
 *
 * Fase B — TASA DE HITS
 *   Lee la misma region dos veces. Mide hits/misses con los contadores de
 *   MMIO. La primera pasada debe tener ~N misses (cache frio). La segunda
 *   pasada debe tener ~N hits (cache caliente).
 *
 * Salida:
 *   Pantalla verde brillante  -> todo OK
 *   Pantalla roja             -> error de correctitud (KEY1 cicla detalles)
 *   Pantalla azul             -> tasa de hits inesperada (cache rota)
 *
 * HEX (cuando OK, ciclar con KEY1):
 *   Vista 0: 0xEEEEEE (success marker)
 *   Vista 1: hits totales (24 bits bajos)
 *   Vista 2: misses totales (24 bits bajos)
 *   Vista 3: ratio hit/miss * 100 si hay misses, 0xFFFFFF si no hay
 */

#define N_WORDS 1024   /* 4 KB -> cabe en el cache exactamente */
/* Phase B usa addresses 4096..8191 (palabras 1024..2047). Coinciden con
 * los mismos indices que phase A (0..1023) pero con tag distinto, asi
 * forzamos evictions y vemos misses en la primera pasada. */
#define PHASE_B_OFFSET 1024
#define PATTERN(i) ((uint32_t)(((i) ^ 0xA5A5A5A5U) + 0xCAFE0000U))

enum {
    C_BG    = 0,
    C_OK    = 1,   /* verde   */
    C_FAIL  = 2,   /* rojo    */
    C_WARN  = 3,   /* azul    */
    C_AMBER = 4,   /* amarillo */
};

static uint32_t g_first_fail_addr;
static uint32_t g_first_fail_got;
static uint32_t g_first_fail_exp;
static int      g_correctness_ok = 1;

static uint32_t g_hits_before, g_misses_before;
static uint32_t g_hits_after,  g_misses_after;

static void fill_screen(uint8_t color) {
    for (int y = 0; y < FB_HEIGHT; y++)
        for (int x = 0; x < FB_WIDTH; x++)
            fb_putpixel(x, y, color);
}

static void phase_correctness(void) {
    /* Escritura completa */
    for (uint32_t i = 0; i < N_WORDS; i++) {
        SDRAM_W[i] = PATTERN(i);
    }
    /* Lectura y verificacion */
    for (uint32_t i = 0; i < N_WORDS; i++) {
        uint32_t got = SDRAM_W[i];
        uint32_t exp = PATTERN(i);
        if (got != exp) {
            g_correctness_ok    = 0;
            g_first_fail_addr   = i * 4;
            g_first_fail_got    = got;
            g_first_fail_exp    = exp;
            return;
        }
    }
}

static void phase_hit_rate(void) {
    /* Baseline counters */
    uint32_t h0 = CACHE_HITS;
    uint32_t m0 = CACHE_MISSES;

    /* Primera pasada en region nueva: cache frio para estos addresses,
     * deberia ser todo misses (los indices coinciden con phase A pero
     * los tags son distintos, asi evictamos al hacer fill). */
    uint32_t sink = 0;
    for (uint32_t i = 0; i < N_WORDS; i++) {
        sink ^= SDRAM_W[PHASE_B_OFFSET + i];
    }
    g_hits_before   = CACHE_HITS   - h0;
    g_misses_before = CACHE_MISSES - m0;

    /* Segunda pasada misma region: cache caliente, deberia ser todo hits */
    uint32_t h1 = CACHE_HITS;
    uint32_t m1 = CACHE_MISSES;
    for (uint32_t i = 0; i < N_WORDS; i++) {
        sink ^= SDRAM_W[PHASE_B_OFFSET + i];
    }
    g_hits_after   = CACHE_HITS   - h1;
    g_misses_after = CACHE_MISSES - m1;

    /* sink se descarta pero forzamos que no se optimice escribiendolo a un
     * LED apagado por si el compilador es agresivo */
    if (sink == 0xDEADBEEF) LEDR = 0;
}

int main(void) {
    fb_set_palette(0, 0x000);
    fb_set_palette(1, 0x0F0); /* verde   */
    fb_set_palette(2, 0xF00); /* rojo    */
    fb_set_palette(3, 0x00F); /* azul    */
    fb_set_palette(4, 0xFF0); /* amarillo*/
    fb_clear(C_BG);
    LEDR    = 0;
    HEX_REG = 0;

    /* === Fase A: correctitud === */
    LEDR    = 0x100;
    HEX_REG = 0x010000;
    phase_correctness();

    if (!g_correctness_ok) {
        /* Pantalla roja, KEY1 cicla detalles del primer fallo */
        fill_screen(C_FAIL);
        LEDR    = 0x001;
        int view = 0;
        int prev = 1;
        HEX_REG = 0x000000 | (g_first_fail_addr & 0xFFFF);
        while (1) {
            int k = (KEYS >> 1) & 1;
            if (prev == 1 && k == 0) {
                view = (view + 1) & 3;
                switch (view) {
                    case 0: HEX_REG = g_first_fail_addr & 0xFFFFFF; break;
                    case 1: HEX_REG = g_first_fail_got  & 0xFFFFFF; break;
                    case 2: HEX_REG = g_first_fail_exp  & 0xFFFFFF; break;
                    case 3: HEX_REG = 0xF00000; break;
                }
            }
            prev = k;
            delay_ms(10);
        }
    }

    /* === Fase B: hit rate === */
    LEDR    = 0x200;
    HEX_REG = 0x020000;
    phase_hit_rate();

    /* Comprobamos que la primera pasada tuvo principalmente misses
     * (>= 90% de los accesos) y la segunda pasada principalmente hits
     * (>= 90% de los accesos). Con N=1024 esperamos:
     *   primera: ~1024 misses, ~0 hits
     *   segunda: ~1024 hits,   ~0 misses */
    int ok_cold = (g_misses_before >= (N_WORDS * 9 / 10));
    int ok_warm = (g_hits_after    >= (N_WORDS * 9 / 10));

    if (!ok_cold || !ok_warm) {
        fill_screen(C_WARN);
        LEDR    = 0x004;
        int view = 0;
        int prev = 1;
        HEX_REG = 0x030000;
        while (1) {
            int k = (KEYS >> 1) & 1;
            if (prev == 1 && k == 0) {
                view = (view + 1) & 3;
                switch (view) {
                    case 0: HEX_REG = g_hits_before   & 0xFFFFFF; break;
                    case 1: HEX_REG = g_misses_before & 0xFFFFFF; break;
                    case 2: HEX_REG = g_hits_after    & 0xFFFFFF; break;
                    case 3: HEX_REG = g_misses_after  & 0xFFFFFF; break;
                }
            }
            prev = k;
            delay_ms(10);
        }
    }

    /* === SUCCESS === */
    fill_screen(C_OK);
    LEDR    = 0x3FF;
    HEX_REG = 0xEEEEEE;

    int view = 0;
    int prev = 1;
    uint32_t total_hits     = CACHE_HITS;
    uint32_t total_misses   = CACHE_MISSES;
    uint32_t total_accesses = total_hits + total_misses;
    /* Aritmetica de 32 bits a proposito: con N_WORDS=1024 los totales no
     * superan ~3000, asi que total_hits*100 cabe holgadamente en 32 bits
     * y no arrastramos __udivdi3 de libgcc al firmware bare-metal. */
    uint32_t ratio_pct      = (total_accesses != 0)
                              ? ((total_hits * 100u) / total_accesses)
                              : 0xFFFFFFu;

    while (1) {
        int k = (KEYS >> 1) & 1;
        if (prev == 1 && k == 0) {
            view = (view + 1) & 3;
            switch (view) {
                case 0: HEX_REG = 0xEEEEEE; break;
                case 1: HEX_REG = total_hits   & 0xFFFFFF; break;
                case 2: HEX_REG = total_misses & 0xFFFFFF; break;
                case 3: HEX_REG = ratio_pct    & 0xFFFFFF; break;
            }
        }
        prev = k;
        delay_ms(10);
    }
    return 0;
}
