# On force le placement dans .text.start, car le link.ld
# le récupère et le place dans la section .init à 0x80000080
.section .text.start
.globl _start

_start:
    # Ton code d'initialisation ici
    lui sp, 0x80002
    jal ra, main
    j _start
