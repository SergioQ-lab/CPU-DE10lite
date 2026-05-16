# Firmware C para el SoC RISC-V

Esto te permite escribir programas en C y compilarlos a una imagen `.mif`
que Quartus carga en la BRAM principal del SoC. Asi no tienes que
encodear instrucciones a mano.

## 1. Instalar la toolchain RISC-V

Necesitas un GCC cruzado que genere binarios para `rv32im` bare-metal.

### Opcion A: WSL (Windows Subsystem for Linux) - recomendado en Windows

```bash
sudo apt update
sudo apt install gcc-riscv64-unknown-elf
```

El prefijo sera `riscv64-unknown-elf-` aunque compilemos para 32 bits
(con `-march=rv32im` ya esta cubierto). Edita el `Makefile` y cambia:
```
PREFIX ?= riscv64-unknown-elf-
```

### Opcion B: xPack RISC-V GNU Toolchain (binarios precompilados)

Descarga de https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases

- Descomprime en algun sitio (p.ej. `C:\xpack-riscv-none-elf-gcc-13.2`)
- Anade `C:\xpack-riscv-none-elf-gcc-13.2\bin` a tu PATH
- En el Makefile usa:
```
PREFIX ?= riscv-none-elf-
```

### Opcion C: SiFive Freedom Tools

https://github.com/sifive/freedom-tools/releases - prefijo
`riscv64-unknown-elf-`.

### Verificacion

```bash
riscv32-unknown-elf-gcc --version   # o el prefijo que toque
```

Si devuelve la version, esta instalada.

## 2. Compilar el firmware

Desde esta carpeta `firmware/`:

```bash
make
```

Esto:
1. Compila `start.S`, `main.c` y `soc.c` con flags `-march=rv32im -mabi=ilp32`
2. Linka con `linker.ld` produciendo `program.elf`
3. Extrae el binario plano (`program.bin`) con `objcopy`
4. Convierte el binario a `../program.mif` con `tools/bin2mif.py`

Si el prefijo de tu toolchain es distinto:
```bash
make PREFIX=riscv-none-elf-
```

## 3. Recompilar Quartus con el nuevo programa

Una vez generado `program.mif`, abre Quartus y haz:
- `Processing → Start Compilation` (o `Update Memory Initialization File`
  si solo cambio el MIF, mas rapido)
- `Tools → Programmer → Start` para grabar la placa

## 4. Que hace el demo (`main.c`)

- Imprime saludo por UART (115200 8N1 en `ARDUINO_IO[1]` / pin AB17)
- Pinta una escena en VGA: borde blanco, 6 rectangulos de colores, un
  triangulo y una diagonal pixel-a-pixel
- Cuadrado que rebota cambiando de color
- Contador en displays HEX y LEDs
- Switches SW[3:0] cambian el color de fondo en tiempo real

## 5. Estructura

```
firmware/
├── Makefile         # build system
├── linker.ld        # mapa de memoria y secciones
├── start.S          # boot: inicializa stack y BSS, llama main
├── soc.h            # API y direcciones MMIO
├── soc.c            # implementacion: putpixel, uart, delay...
├── main.c           # demo
└── tools/
    └── bin2mif.py   # convierte .bin a MIF de Quartus
```

## 6. Limitaciones actuales

- **RAM = 32 KiB**: todo el codigo, datos y stack tienen que caber.
  El demo ocupa ~3 KiB sin libc.
- **No hay libc** (printf, malloc...). Hemos puesto helpers basicos en
  `soc.c`. Si quieres `printf`, integra newlib-nano (anade
  `-nostdlib` -> `-lc -lgcc` y conecta `_write` al UART).
- **No hay floats**: la CPU es `rv32im` sin extension F. Usa enteros o
  emulacion software (`-mabi=ilp32` ya lo hace).
- **Read-modify-write en framebuffer**: para escribir un pixel, la CPU
  lee la palabra de 32b, modifica el nibble y la reescribe. Cada
  putpixel cuesta ~6-8 ciclos. Para sprites grandes, considerar
  escribir palabras enteras pre-empaquetadas.

## 7. Como anadir un programa nuevo

1. Edita `main.c` (o anade otro `.c` y mete su nombre en `C_SRCS` del Makefile).
2. `make clean && make`
3. Recompila Quartus y graba.

Y listo.
