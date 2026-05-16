# =====================================================================
# Makefile para firmware del SoC RISC-V (DE10-Lite)
#
# Compila C + ASM con la toolchain RISC-V bare-metal y genera el
# fichero program.mif que Quartus carga en la BRAM principal.
#
# Uso:
#   make            -> compila todo y genera ../program.mif
#   make clean      -> limpia los artefactos
#   make dump       -> genera program.lst (disassembly) para depurar
#
# Configurable:
#   PREFIX=<prefix>  -> cambia el prefijo de la toolchain (defecto:
#                       riscv32-unknown-elf-). Otras opciones comunes:
#                         riscv64-unknown-elf-   (SiFive/xPack)
#                         riscv-none-elf-        (xPack reciente)
# =====================================================================

PREFIX ?= riscv64-elf-
CC      := $(PREFIX)gcc
AS      := $(PREFIX)gcc
LD      := $(PREFIX)gcc
OBJCOPY := $(PREFIX)objcopy
OBJDUMP := $(PREFIX)objdump

# Objetivo
TARGET   := program
ELF      := $(TARGET).elf
BIN      := $(TARGET).bin
LST      := $(TARGET).lst
MIF_OUT  := ../program.mif

# Fuentes
C_SRCS   := main.c soc.c
ASM_SRCS := start.S
OBJS     := $(C_SRCS:.c=.o) $(ASM_SRCS:.S=.o)

# Flags
ARCH_FLAGS := -march=rv32im -mabi=ilp32
CFLAGS  := $(ARCH_FLAGS) -Os -ffreestanding -fno-builtin -nostdlib \
           -Wall -Wextra -fno-pic -fno-pie -fno-stack-protector \
           -fomit-frame-pointer -mno-relax
ASFLAGS := $(ARCH_FLAGS) -c
LDFLAGS := -T linker.ld -nostdlib -nostartfiles \
           -Wl,--gc-sections -mno-relax $(ARCH_FLAGS)

# Profundidad de la BRAM (debe coincidir con ADDR_BITS de main_memory)
MEM_DEPTH := 8192

# =====================================================================
.PHONY: all clean dump info

all: $(MIF_OUT)

# Genera el MIF a partir del binario
$(MIF_OUT): $(BIN)
	@echo "[mif] $(BIN) -> $@"
	@python tools/bin2mif.py $(BIN) $@ --depth $(MEM_DEPTH) --width 32

# Binario plano desde el ELF
$(BIN): $(ELF)
	@echo "[bin] $< -> $@"
	@$(OBJCOPY) -O binary $< $@

# Linkado de todos los .o con el linker script
$(ELF): $(OBJS) linker.ld
	@echo "[ld] $@"
	@$(LD) $(LDFLAGS) $(OBJS) -o $@
	@$(PREFIX)size $@

# Reglas de compilacion
%.o: %.c soc.h
	@echo "[cc] $<"
	@$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S
	@echo "[as] $<"
	@$(AS) $(ASFLAGS) $< -o $@

# Genera un disassembly para inspeccionar el codigo
dump: $(ELF)
	@$(OBJDUMP) -D -h -S $(ELF) > $(LST)
	@echo "Disassembly en $(LST)"

info:
	@echo "Toolchain prefix : $(PREFIX)"
	@echo "Compilador       : $(shell which $(CC) 2>/dev/null || echo 'NO ENCONTRADO')"
	@echo "Memoria          : $(MEM_DEPTH) words x 32 bits"

clean:
	@rm -f $(OBJS) $(ELF) $(BIN) $(LST)
	@echo "[clean] OK"
