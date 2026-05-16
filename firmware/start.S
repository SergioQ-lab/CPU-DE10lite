/* ---------------------------------------------------------------------
 * start.S - Punto de entrada del firmware C.
 *
 * Se ejecuta al arrancar la CPU (PC=0). Sus tareas son:
 *   1) Inicializar el stack pointer al tope de la RAM
 *   2) Cerar la seccion .bss (variables globales sin inicializar)
 *   3) Llamar a main()
 *   4) Si main() retorna, bucle infinito
 *
 * Como todo el programa esta en BRAM precargada via MIF, NO necesitamos
 * copiar .data desde una ROM (ya esta en RAM al arrancar).
 * --------------------------------------------------------------------- */

    .section .text.init
    .global _start
    .global _stop

_start:
    /* Apila a tope de RAM (_stack_top viene del linker script) */
    la      sp, _stack_top

    /* Limpia BSS: range [_bss_start, _bss_end) */
    la      t0, _bss_start
    la      t1, _bss_end
1:
    beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* Llama main */
    call    main

    /* main retorno - bucle infinito */
_stop:
    j       _stop
