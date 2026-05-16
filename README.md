# CPU RISC-V para DE10-Lite (MAX10) - SoC con VGA

CPU RV32IM pipelined de 5 etapas + SoC completo (framebuffer VGA con paleta indexada, UART, GPIO, displays HEX) pensado para correr DOOM sobre la Terasic DE10-Lite. Inspirado en RPU (Domipheus) pero reescrito desde cero con pipeline real y un mapa de memoria orientado a juegos.

---

## Arquitectura

```
                              50 MHz
                                |
           +------------------- v -------------------+
           |  CPU RV32IM 5-stage pipeline            |
           |  (IF -> ID -> EX -> MEM -> WB)          |
           |  forwarding + hazard detection          |
           |  multiplier (2 cy) + divider (~34 cy)   |
           |  CSR machine-mode (mcycle = benchmark)  |
           +-----------+-------------+---------------+
                I-bus  |             | D-bus (32b + BE4)
                       |             |
   +---------+--------- ---+--------+-+----------+----------+
   | 64 KiB main_memory     | vga_framebuffer    | mmio     |
   | (M9K dual-port BRAM)   | 320x240 nibble pal | LEDR/HEX |
   | code + data + heap     | -> 640x480 @ 60Hz  | SW/UART  |
   +------------------------+--------------------+----------+
```

## Caracteristicas del core

- **ISA**: RV32IM (`base I` + `M` extension). Sin compresion (RVC), sin float.
- **Pipeline**: 5 etapas en orden, **prediccion estatica not-taken**, **forwarding EX/MEM y MEM/WB**, **stall load-use de 1 ciclo**.
- **Mul**: 2 ciclos (DSP inferido por Quartus).
- **Div**: ~34 ciclos por shift-and-subtract con casos especiales del estandar (div/0 -> -1, INT_MIN/-1 -> INT_MIN, etc).
- **CSRs M-mode**: `mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mtval, mip, mcycle/mcycleh`.
- **Trampas sincronas**: `ecall`, `ebreak`, `illegal instruction`, `mret`. (Interrupciones externas dejadas como I_irq pero sin enmascaramiento todavia).

### Rendimiento esperado

- 50 MHz x ~0.85 IPC (codigo entero medio con loads esporadicos) = **~42 MIPS**.
- El RPU original a 100 MHz con CPI ~5 entrega ~20 MIPS y da 8 fps en Doom.
- A igual codigo, deberiamos rondar **30-40 fps** en Doom timedemo3 (sin tener en cuenta penalizaciones de un bus de memoria mas lento si se anade SDRAM en una segunda iteracion).

## Estructura del repositorio

```
CPU-RISC-V/
+-- src/
|   +-- riscv_pkg.vhd           - constantes ISA
|   +-- register_file.vhd       - banco de 32 registros con bypass interno
|   +-- decoder.vhd             - decodificador RV32IM
|   +-- alu.vhd                 - ALU combinacional + interfaz mul/div
|   +-- multiplier.vhd          - mul de 2 ciclos
|   +-- divider.vhd             - div restoring de 34 ciclos
|   +-- csr_unit.vhd            - CSRs machine mode + trampas
|   +-- branch_unit.vhd         - eval. de branches y saltos
|   +-- hazard_unit.vhd         - forwarding + stall + flush
|   +-- cpu_core.vhd            - top de la CPU pipelined
|   +-- main_memory.vhd         - BRAM dual-port (I-bus + D-bus)
|   +-- vga_framebuffer.vhd     - framebuffer 320x240 paletizado
|   +-- uart_tx.vhd             - UART 115200 8N1
|   +-- seven_seg.vhd           - decodificador hex->display
|   +-- mmio_bridge.vhd         - puente MMIO (LEDR/HEX/SW/UART/timer)
|   +-- soc.vhd                 - integrador
|   +-- top_de10_lite.vhd       - top con pin mapping
+-- CPU-RISC-V.qpf              - proyecto Quartus
+-- CPU-RISC-V.qsf              - settings y pin assignments
+-- program.mif                 - imagen inicial de la RAM (placeholder)
+-- README.md
```

## Mapa de memoria

| Rango                       | Tamano   | Funcion                                  |
|-----------------------------|----------|------------------------------------------|
| `0x0000_0000 - 0x0000_FFFF` | 64 KiB   | RAM principal (codigo + datos + pila)    |
| `0x1000_0000 - 0x1001_2BFF` | 75 KiB   | Framebuffer (320x240 px x 4 bpp)         |
| `0xF000_0000 - 0xF000_00FF` | 256 B    | Periferia MMIO                           |

### MMIO

| Offset | RW | Descripcion                                 |
|--------|----|---------------------------------------------|
| `0x00` | W  | LEDR (10 LEDs rojos)                        |
| `0x04` | R  | Lectura de los 10 switches                  |
| `0x08` | R  | Lectura de KEY1/KEY0 (KEY0 es tambien reset)|
| `0x0C` | W  | HEX5..HEX0 (6 nibbles)                      |
| `0x10` | W  | UART TX byte                                |
| `0x14` | R  | UART status (bit 0 = busy)                  |
| `0x18` | R  | Timer libre (contador 32 b @ 50 MHz)        |
| `0x20..0x5C` | W | Paleta (16 entradas xRGB de 12 bits)   |

## Como compilar y programar

1. **Compilar el firmware** con la toolchain RISC-V (Newlib bare-metal):
   ```bash
   riscv32-unknown-elf-gcc -march=rv32im -mabi=ilp32 -Os -nostdlib \
       -T linker.ld -o doom.elf start.S *.c
   riscv32-unknown-elf-objcopy -O binary doom.elf doom.bin
   python tools/bin2mif.py doom.bin program.mif 16384
   ```
   El linker script debe colocar `.text` en `0x00000000`, `.data` y `.bss` por debajo de `0x00010000`. La pila se inicializa en `0x0000FFFC` (decreciente).

2. **Generar el proyecto** en Quartus Prime Lite 20.1 o superior:
   ```
   File > Open Project... > CPU-RISC-V.qpf
   ```
   Quartus leera todos los `VHDL_FILE` listados en el `.qsf`. La SoC se sintetiza para el dispositivo `10M50DAF484C7G`. Si se cambia la version de Quartus, conviene revisar `MAX10` device support.

3. **Compilar el SoC**: `Processing > Start Compilation`. Tarda 5-10 min. Se generara `output_files/CPU-RISC-V.sof`.

4. **Programar** la DE10-Lite via USB-Blaster:
   ```
   Tools > Programmer > Add File > CPU-RISC-V.sof > Start
   ```

## Verificacion rapida del SoC sin Doom

El `program.mif` incluido enciende un patron en los LEDs y entra en bucle. Tras programar la FPGA:
- LEDR debe mostrar `0010101010` (bits 1, 3, 5, 7 encendidos).
- HEX displays apagados (no se escriben).
- Pantalla VGA negra (no se escribe el framebuffer).
- Botoncito KEY[0] sirve como reset.

## Adaptacion para correr Doom

El port RISC-V de Doom (`doom_riscv-master`) ya esta orientado a bare-metal y solo requiere:

1. **Backend de video**: el `i_video.c` escribe en un framebuffer 320x200 paletizado. Hay que mapearlo a `FB_BASE` (cada pixel = 1 nibble, 8 px por palabra). En `I_FinishUpdate` basta con un `memcpy` del buffer interno al framebuffer del SoC.
2. **Paleta**: en `I_SetPalette`, escribir las 16 entradas del nibble seleccionado a `MMIO_BASE + 0x20`. Como Doom usa 256 colores y nosotros 16, hay que reducir la paleta (algoritmo k-means o mapa fijo). Alternativa: ampliar el framebuffer a 8 bpp (doblar el tamano de BRAM o usar SDRAM).
3. **Stdio**: `mini-printf` ya usa una funcion `putc` que se redirige al UART_TX (0x10 + polling de 0x14).
4. **Heap/stack**: ajustar `riscv.lds` para que el codigo cabe en 64 KiB. Si no cabe, configurar la SDRAM externa de 64 MiB de la DE10-Lite (no incluido en este diseno - es un trabajo futuro: anadir `sdram_controller.vhd` y mapear `0x20000000`).

## Mejoras y limitaciones conocidas

- **Sin SDRAM**: la RAM principal es BRAM (64 KiB). Para correr Doom completo + WAD (~4 MiB) hay que anadir el controlador SDRAM IS42S16320 que viene en la placa. Es la principal area de mejora.
- **Sin cache de instrucciones**: la BRAM esta directamente conectada al I-bus a 50 MHz; con SDRAM seria imprescindible una I-cache. Direct-mapped de 4 KiB caben en 1 M9K.
- **Multiplicador**: usa la inferencia de DSP de Quartus. Si la sintesis no logra inferir, se puede reescribir como Booth de 4 bits para no consumir LUTs.
- **Sin RVC**: aumentar 30% el codigo objetivo. Anadir un decodificador previo de 16->32 bits que multiplexe el camino de IF.

## Licencia

Inspirado en RPU (Apache-2.0, Colin Riley). Codigo nuevo bajo MIT.
