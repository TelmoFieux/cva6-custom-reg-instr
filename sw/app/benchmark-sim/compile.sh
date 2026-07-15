#!/bin/bash

C_FILE="${1:-bench_mem.c}"
BASE_NAME=$(basename "$C_FILE" .c)

OBJ_FILE="${BASE_NAME}.o"
ELF_FILE="${BASE_NAME}.riscv"
BIN_FILE="${BASE_NAME}.bin"
MEM_FILE="${BASE_NAME}.mem"
LINKER_SCRIPT="../../bsp/config/link.ld"
OUTPUT_DIR="../"

echo "=== Compilation de $C_FILE avec crt0.S ==="

# 1. Assemblage
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -c crt0.S -o crt0.o
if [ $? -ne 0 ]; then
	echo "ERREUR : crt0.S"
	exit 1
fi

# 2. Compilation C
riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -ffreestanding -c "$C_FILE" -o "$OBJ_FILE"
if [ $? -ne 0 ]; then
	echo "ERREUR : compilation C"
	exit 1
fi

# 3. Édition de liens (LINK) avec -e _start
# On force le point d'entrée avec -e _start
riscv64-unknown-elf-ld -m elf32lriscv -T "$LINKER_SCRIPT" crt0.o "$OBJ_FILE" -o "$ELF_FILE"
if [ $? -ne 0 ]; then
	echo "ERREUR : édition de liens"
	exit 1
fi

# 4. suite...
riscv64-unknown-elf-objcopy -O binary "$ELF_FILE" "$BIN_FILE"
python3 ../../utils/bin2mem.py "$BIN_FILE"
mv "$MEM_FILE" "$OUTPUT_DIR"

echo "=== Terminé ! ==="
