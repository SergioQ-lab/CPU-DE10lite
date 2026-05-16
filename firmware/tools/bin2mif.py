#!/usr/bin/env python3
"""
bin2mif.py - Convierte un binario (.bin) plano a formato MIF de Quartus.

Uso:
    python bin2mif.py input.bin output.mif [--depth 8192] [--width 32]

El binario se interpreta como una secuencia de palabras little-endian
del ancho indicado (por defecto 32 bits = 4 bytes por word). Las
direcciones que no aparecen en el binario se rellenan con NOP RISC-V
(0x00000013 = addi x0, x0, 0) para evitar que la CPU encuentre
instrucciones ilegales si se "sale" del programa.
"""

import argparse
import sys
import os


NOP_INSTR = 0x00000013  # RISC-V ADDI x0, x0, 0


def bin_to_words(data: bytes, word_bytes: int) -> list:
    """Convierte bytes a lista de words (little-endian)."""
    if len(data) % word_bytes != 0:
        # Padea con ceros al final
        data = data + b"\x00" * (word_bytes - (len(data) % word_bytes))
    words = []
    for i in range(0, len(data), word_bytes):
        w = 0
        for j in range(word_bytes):
            w |= data[i + j] << (8 * j)
        words.append(w)
    return words


def write_mif(out_path: str, words: list, depth: int, width: int) -> None:
    """Escribe el fichero MIF con las palabras dadas, paddeando con NOPs."""
    if len(words) > depth:
        sys.exit(f"ERROR: el binario tiene {len(words)} palabras pero la "
                 f"profundidad es {depth}. Aumentalo o reduce el firmware.")

    hex_width = width // 4  # numero de digitos hex por word

    with open(out_path, "w", encoding="ascii") as f:
        f.write(f"-- Generado por bin2mif.py - {len(words)}/{depth} palabras usadas\n")
        f.write(f"WIDTH = {width};\n")
        f.write(f"DEPTH = {depth};\n\n")
        f.write("ADDRESS_RADIX = HEX;\n")
        f.write("DATA_RADIX = HEX;\n\n")
        f.write("CONTENT\nBEGIN\n")

        # Padding de NOPs en toda la memoria (Quartus permite rangos)
        f.write(f"    [0000..{depth-1:04X}] : {NOP_INSTR:0{hex_width}X};\n\n")

        # Escribe las palabras del binario, una por linea
        for idx, w in enumerate(words):
            f.write(f"    {idx:04X} : {w:0{hex_width}X};\n")

        f.write("END;\n")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", help="Fichero binario de entrada")
    ap.add_argument("output", help="Fichero MIF de salida")
    ap.add_argument("--depth", type=int, default=8192,
                    help="Numero total de palabras en la memoria (default 8192)")
    ap.add_argument("--width", type=int, default=32,
                    help="Ancho de cada palabra en bits (default 32)")
    args = ap.parse_args()

    if args.width % 8 != 0:
        sys.exit("ERROR: width debe ser multiplo de 8")
    word_bytes = args.width // 8

    if not os.path.exists(args.input):
        sys.exit(f"ERROR: no existe {args.input}")

    with open(args.input, "rb") as f:
        data = f.read()

    words = bin_to_words(data, word_bytes)
    write_mif(args.output, words, args.depth, args.width)

    print(f"OK: {len(data)} bytes -> {len(words)} palabras -> {args.output}")


if __name__ == "__main__":
    main()
