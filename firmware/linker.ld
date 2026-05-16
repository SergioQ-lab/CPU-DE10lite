/* ---------------------------------------------------------------------
 * linker.ld - Linker script para el firmware bare-metal RISC-V que
 * corre en la SoC del DE10-Lite.
 *
 * Mapa de memoria del programa:
 *   0x00000000 .. 0x00007FFF   RAM principal (32 KiB BRAM)
 *
 *   Layout interno:
 *     .text.init  (start.S)        ; debe empezar en 0x00000000
 *     .text       (codigo)
 *     .rodata     (constantes)
 *     .data       (globals init)
 *     .bss        (globals zero)
 *     stack       (crece hacia abajo desde 0x00007FFC)
 *
 * Todo cae en la BRAM, asi que NO hace falta copia ROM->RAM en boot.
 * --------------------------------------------------------------------- */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS
{
    /* Codigo de arranque + resto del codigo */
    .text : ALIGN(4)
    {
        KEEP(*(.text.init))   /* start.S primero */
        *(.text)
        *(.text.*)
    } > RAM

    /* Datos constantes (cadenas literales, tablas, etc.) */
    .rodata : ALIGN(4)
    {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
    } > RAM

    /* Globales inicializados */
    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        _data_end = .;
    } > RAM

    /* Globales sin inicializar - start.S los pone a 0 */
    .bss : ALIGN(4)
    {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        _bss_end = ALIGN(4);
    } > RAM

    /* Stack al tope de la RAM, crece hacia abajo */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /DISCARD/ :
    {
        *(.eh_frame)
        *(.comment)
        *(.note*)
    }
}
