#include "soc.h"
#include <stdint.h>

/*
 * SDRAM stress test
 *
 * 5 fases que aislan tipos distintos de bug. La pantalla dibuja una
 * barra por fase: gris = pendiente, azul = en curso, verde = pasa,
 * rojo = falla. Si todas pasan, fb se rellena de verde y HEX=0xEEEEEE.
 * Si alguna falla, KEY1 cicla por el diagnostico de la PRIMERA fase
 * fallada: numero de fase / addr / leido / esperado.
 *
 * LEDR:
 *   bit i  = fase i+1 pasada
 *   bit 9  = todas OK
 *
 * Layout de SDRAM (16-bit words, 25-bit addr):
 *   addr[24:23] = banco  (4)
 *   addr[22:10] = fila   (8192)
 *   addr[9:0]   = columna (1024)
 */

#define SDRAM_BASE 0x20000000U
#define SDRAM      ((volatile uint16_t *)SDRAM_BASE)

#define N_PHASES   5

enum {
    C_BG    = 0,
    C_OK    = 1,   /* verde   */
    C_FAIL  = 2,   /* rojo    */
    C_BUSY  = 3,   /* azul    */
    C_AMBER = 4,   /* amarillo (libre) */
    C_PEND  = 5,   /* gris    */
};

static uint8_t   phase_status[N_PHASES];        /* 0=pend, 1=ok, 2=fail, 3=busy */
static uint32_t  fail_info[N_PHASES][3];        /* [addr, got, exp] */

#define BAR_Y0   (FB_HEIGHT/2 - 40)
#define BAR_H    80

static void draw_panel(void) {
    int bar_w = FB_WIDTH / N_PHASES;
    for (int p = 0; p < N_PHASES; p++) {
        int x = p * bar_w;
        uint8_t color;
        switch (phase_status[p]) {
            case 1:  color = C_OK;    break;
            case 2:  color = C_FAIL;  break;
            case 3:  color = C_BUSY;  break;
            default: color = C_PEND;  break;
        }
        fb_fill_rect(x + 2, BAR_Y0, bar_w - 4, BAR_H, color);
    }
}

static void record_fail(int ph, uint32_t addr, uint32_t got, uint32_t exp) {
    phase_status[ph]   = 2;
    fail_info[ph][0]   = addr;
    fail_info[ph][1]   = got;
    fail_info[ph][2]   = exp;
}

/* ===== Fase 1: walking 1s / walking 0s en addr 0 ===== */
static int phase_walking_bits(void) {
    for (int i = 0; i < 16; i++) {
        uint16_t exp = (uint16_t)(1u << i);
        SDRAM[0] = exp;
        uint16_t got = SDRAM[0];
        if (got != exp) { record_fail(0, (uint32_t)i, got, exp); return 0; }
    }
    for (int i = 0; i < 16; i++) {
        uint16_t exp = (uint16_t)~(1u << i);
        SDRAM[0] = exp;
        uint16_t got = SDRAM[0];
        if (got != exp) { record_fail(0, (uint32_t)(0x100 + i), got, exp); return 0; }
    }
    return 1;
}

/* ===== Fase 2: fill secuencial 16K palabras (16 filas) ===== */
#define N_SEQ 16384u
static int phase_addr_as_data(void) {
    for (uint32_t i = 0; i < N_SEQ; i++) {
        SDRAM[i] = (uint16_t)(i ^ 0xA5A5u);
        if ((i & 0x3FF) == 0) HEX_REG = 0x200000u | i;
    }
    for (uint32_t i = 0; i < N_SEQ; i++) {
        uint16_t exp = (uint16_t)(i ^ 0xA5A5u);
        uint16_t got = SDRAM[i];
        if (got != exp) { record_fail(1, i, got, exp); return 0; }
        if ((i & 0x3FF) == 0) HEX_REG = 0x200000u | (i + 0x10000u);
    }
    return 1;
}

/* ===== Fase 3: una palabra en col 0 de 64 filas distintas ===== */
#define N_ROWS 64u
static int phase_row_stride(void) {
    for (uint32_t r = 0; r < N_ROWS; r++) {
        SDRAM[r * 1024u] = (uint16_t)(0xC000u + r);
    }
    for (uint32_t r = 0; r < N_ROWS; r++) {
        uint16_t exp = (uint16_t)(0xC000u + r);
        uint16_t got = SDRAM[r * 1024u];
        if (got != exp) { record_fail(2, r * 1024u, got, exp); return 0; }
    }
    return 1;
}

/* ===== Fase 4: una palabra en col 0, fila 0 de cada banco ===== */
static int phase_bank_stride(void) {
    for (uint32_t b = 0; b < 4u; b++) {
        SDRAM[b * 0x800000u] = (uint16_t)(0xB000u + b);
    }
    for (uint32_t b = 0; b < 4u; b++) {
        uint16_t exp = (uint16_t)(0xB000u + b);
        uint16_t got = SDRAM[b * 0x800000u];
        if (got != exp) { record_fail(3, b * 0x800000u, got, exp); return 0; }
    }
    return 1;
}

/* ===== Fase 5: retencion tras 200ms (test del auto-refresh) ===== */
#define N_REF 1024u
static int phase_refresh(void) {
    for (uint32_t i = 0; i < N_REF; i++) {
        SDRAM[i] = (uint16_t)(0xDEADu ^ i);
    }
    delay_ms(200);
    for (uint32_t i = 0; i < N_REF; i++) {
        uint16_t exp = (uint16_t)(0xDEADu ^ i);
        uint16_t got = SDRAM[i];
        if (got != exp) { record_fail(4, i, got, exp); return 0; }
    }
    return 1;
}

typedef int (*phase_fn)(void);
static const phase_fn phases[N_PHASES] = {
    phase_walking_bits,
    phase_addr_as_data,
    phase_row_stride,
    phase_bank_stride,
    phase_refresh,
};

int main(void) {
    fb_set_palette(0, 0x000);
    fb_set_palette(1, 0x0F0); /* verde     */
    fb_set_palette(2, 0xF00); /* rojo      */
    fb_set_palette(3, 0x00F); /* azul      */
    fb_set_palette(4, 0xFF0); /* amarillo  */
    fb_set_palette(5, 0x555); /* gris      */
    fb_clear(C_BG);
    LEDR = 0;
    HEX_REG = 0;

    for (int p = 0; p < N_PHASES; p++) phase_status[p] = 0;
    draw_panel();

    int all_ok    = 1;
    int first_fail = -1;

    for (int p = 0; p < N_PHASES; p++) {
        phase_status[p] = 3; /* busy */
        draw_panel();
        HEX_REG = (uint32_t)(p + 1) << 20; /* numero de fase en HEX5 */
        LEDR    = (uint32_t)(1u << (p + 5)); /* indicador "corriendo" */

        if (phases[p]()) {
            phase_status[p] = 1;
            LEDR |= (uint32_t)(1u << p);
        } else {
            phase_status[p] = 2;
            all_ok = 0;
            if (first_fail < 0) first_fail = p;
        }
        draw_panel();
    }

    if (all_ok) {
        fb_clear(C_OK);
        LEDR    = 0x3FF;
        HEX_REG = 0xEEEEEE;
        while (1) { }
    }

    /* Algun fallo: KEY1 cicla las 4 vistas del primer fallo */
    int view     = 0;
    int prev_key = 1;
    HEX_REG = (uint32_t)((first_fail + 1) << 20) | 0xF; /* phase + marca 'F' */
    LEDR    = 0x000;
    /* indica que fase fallo */
    LEDR    = (uint32_t)(1u << first_fail);

    while (1) {
        int key1 = (KEYS >> 1) & 1;
        if (prev_key == 1 && key1 == 0) {
            view = (view + 1) & 3;
            switch (view) {
                case 0: /* fase fallada (1..5) en HEX5, F en HEX0 */
                    HEX_REG = (uint32_t)((first_fail + 1) << 20) | 0xF;
                    break;
                case 1: /* direccion del fallo */
                    HEX_REG = fail_info[first_fail][0] & 0xFFFFFFu;
                    break;
                case 2: /* dato leido */
                    HEX_REG = fail_info[first_fail][1] & 0xFFFFu;
                    break;
                case 3: /* dato esperado */
                    HEX_REG = fail_info[first_fail][2] & 0xFFFFu;
                    break;
            }
        }
        prev_key = key1;
        delay_ms(10);
    }
    return 0;
}
