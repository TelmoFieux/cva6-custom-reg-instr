.section .text
.global _start

_start:
    .fill 32, 4, 0x00000013 # Remplit avec des NOP (li x0, 0)
    # -------------------------------------------------------------------------
    # SECTION 1 : Aléas de données directs (RAW - Read After Write)
    # -------------------------------------------------------------------------
    # Objectif Matériel : Vérifier que les Stations de Réservation (RS) bloquent
    # bien les instructions dépendantes et attendent que la valeur soit produite
    # (ou via le réseau de Forwarding / Bypass).
    # -------------------------------------------------------------------------
    li t0, 10
    add t1, t0, t0      # RAW sur t0 (t1 = 20)
    sub t2, t1, t0      # RAW sur t1 et t0 (t2 = 10)
    mul t3, t2, t1      # RAW sur t2 et t1 (t3 = 200) - La multiplication prend du temps

    # -------------------------------------------------------------------------
    # SECTION 2 : Aléas de nommage WAW (Write After Write)
    # -------------------------------------------------------------------------
    # Objectif Matériel : Tester la RAT (Register Allocation Table). La deuxième
    # écriture dans t4 ne doit pas écraser la première si la multiplication est
    # en cours, mais les instructions suivantes doivent utiliser le t4 le plus récent.
    # -------------------------------------------------------------------------
    mul t4, t3, t0      # t4 = 200 * 10 = 2000 (Prend plusieurs cycles)
    li t4, 5            # WAW sur t4 immédiat ! (Écrit dans un nouveau registre physique)
    add t5, t4, t0      # t5 doit valoir 5 + 10 = 15, et NON PAS 2000 + 10 !

    # -------------------------------------------------------------------------
    # SECTION 3 : Aléas de nommage WAR (Write After Read)
    # -------------------------------------------------------------------------
    # Objectif Matériel : Tester si le renommage isole bien les registres.
    # L'instruction 'li t5' ne doit pas corrompre la lecture de t5 par le 'add'
    # si le 'add' est resté bloqué dans une station de réservation.
    # -------------------------------------------------------------------------
    add t6, t5, t0      # t6 = 15 + 10 = 25 (Lit t5)
    li t5, 99           # WAR sur t5 immédiat ! (Ne doit pas impacter t6)

    # -------------------------------------------------------------------------
    # SECTION 4 : Spéculation de Branchement et Vidage (Flush / Rollback)
    # -------------------------------------------------------------------------
    # Objectif Matériel : Le cas le plus critique en OoO. On force un branchement.
    # Si le prédicteur de branche se trompe (ou par défaut d'implémentation),
    # le processeur va commencer à exécuter le "Mauvais Chemin".
    # Lors de la résolution de la branche, le CPU doit vider (Flush) le ROB,
    # les RS, et RESTAURER l'ancienne RAT (Commit RAT) pour oublier s0 et s1.
    # -------------------------------------------------------------------------
    li t0, 1
    li s0, 0x1111       # Valeur initiale de s0
    li s1, 0x2222       # Valeur initiale de s1

    beq t0, t0, branch_taken  # Ce branchement est TOUJOURS pris.

    # === MAUVAIS CHEMIN (Spéculatif) ===
    # Si ton CPU exécute ceci spéculativement, ces instructions entreront dans le ROB.
    li s0, 0xBAD        # Écriture spéculative
    li s1, 0xBAD2       # Écriture spéculative
    add t0, s0, s1      # Dépendance spéculative
    # ATTENTION : Ces instructions ne doivent JAMAIS faire l'objet d'un COMMIT.

branch_taken:
    # === BON CHEMIN ===
    # Après le Flush, s0 et s1 doivent avoir conservé (ou repris) leurs valeurs d'origine.
    add s2, s0, x0      # s2 doit valoir 0x1111. Si s2 vaut 0xBAD, ton Flush/Rollback RAT a échoué !

    # -------------------------------------------------------------------------
    # SECTION 5 : Aléas Mémoire (Load-Store Queue & Disambiguation)
    # -------------------------------------------------------------------------
    # Objectif Matériel : Tester la Load/Store Unit (LSU). Un Load qui suit un
    # Store à la même adresse doit obtenir la valeur du Store (Store-to-Load Forwarding)
    # même si le Store n'a pas encore écrit physiquement dans le cache Data.
    # -------------------------------------------------------------------------
    la a0, mem_buffer   # Charge l'adresse de notre zone mémoire de test
    li t0, 0x55AA

    sw t0, 0(a0)        # Store en mémoire
    lw t1, 0(a0)        # Load immédiat à la même adresse !
    # t1 doit obtenir 0x55AA immédiatement.

    # -------------------------------------------------------------------------
    # SECTION 6 : Exceptions spéculatives (In-Order Commit des Exceptions)
    # -------------------------------------------------------------------------
    # Objectif Matériel : En OoO, une instruction peut lever une exception au
    # milieu du pipeline (ex: accès mémoire invalide). Cependant, cette exception
    # ne doit PAS être déclenchée tant que l'instruction n'arrive pas à l'étage
    # de Commit. Si elle est spéculative et flushée avant, l'exception est annulée.
    # -------------------------------------------------------------------------
    li t0, 1
    beq t0, t0, skip_exception # Branchement toujours pris, saute l'erreur

    # Si le processeur exécute ceci spéculativement, le Load va provoquer un
    # défaut d'accès (adresse 0x0). Le CPU ne doit pas crasher immédiatement !
    lw t2, 0(x0)

skip_exception:
    # Si on arrive ici, tout s'est bien passé.

    # -------------------------------------------------------------------------
    # FIN DU TEST : Boucle de succès
    # -------------------------------------------------------------------------
    li gp, 1            # Registre gp = 1 indique le succès du test
end_loop:
    j end_loop          # Boucle infinie pour arrêter proprement la simulation


# -------------------------------------------------------------------------
# Zone mémoire pour le test des Load/Store
# -------------------------------------------------------------------------
.section .data
.align 4
mem_buffer:
    .word 0x00000000
