.section .text
.global _start

_start:
    .fill 32, 4, 0x00000013 # Remplit avec des NOP (li x0, 0)

end_loop:
    .fill 32, 4, 0x00000013 # Remplit avec des NOP (li x0, 0)
    j end_loop          # Boucle infinie pour arrêter proprement la simulation

# -------------------------------------------------------------------------
# Zone mémoire pour le test des Load/Store
# -------------------------------------------------------------------------
.section .data
.align 4
mem_buffer:
    .word 0x00000000
