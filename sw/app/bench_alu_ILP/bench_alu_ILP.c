#include <stdint.h>


#define EXPECTED_RESULT 57

void check_result(int result) {
    if (result != EXPECTED_RESULT) {
        // Option A : Écrire dans une adresse mémoire spécifique pour le testbench
        volatile int *error_ptr = (volatile int *)0x80001000;
        *error_ptr = 0xDEADBEEF; // Valeur indiquant une erreur

        // Option B : Provoquer une exception logicielle (Illegal Instruction)
        // Cela stoppera immédiatement la simulation pour inspection
        __asm__ volatile (".word 0x00000000");
    } else {
        // Succès : marquer une valeur de "Pass"
        volatile int *pass_ptr = (volatile int *)0x80001000;
        *pass_ptr = 0x00000001;
    }
}

// Fonction pour lire le registre mcycle (compteur de cycles)
static inline uint64_t read_mcycle() {
    uint64_t val;
    __asm__ volatile ("csrr %0, mcycle" : "=r" (val));
    return val;
}

// Fonction de charge de travail (Workload)
// Ajustez cette constante pour changer la durée
#define WORKLOAD_SIZE 5

int heavy_computation_parallel() {
    // On utilise 4 accumulateurs indépendants
    int a1 = 0, a2 = 0, a3 = 0, a4 = 0;

    for (int i = 0; i < WORKLOAD_SIZE; i++) {
        for (int j = 0; j < WORKLOAD_SIZE; j++) {
            // Ces 4 opérations ne dépendent pas les unes des autres !
            // Le CPU peut donc les envoyer vers différentes unités de calcul
            // en même temps (si disponibles).
            a1 = (a1 + i * j) % 123;
            a2 = (a2 + i * j) % 123;
            a3 = (a3 + i * j) % 123;
            a4 = (a4 + i * j) % 123;
        }
    }

    return a1;
}

int main() {
    uint64_t start, end;

    // Mesure du début
    start = read_mcycle();

    // Exécution de la charge
    int result = heavy_computation_parallel();

    // Mesure de la fin
    end = read_mcycle();

    // Le résultat (end - start) est le nombre de cycles
    // Dans un environnement bare-metal, vous voudrez probablement
    // écrire ce résultat dans une adresse mémoire spécifique
    // ou via une instruction de sortie (syscall) pour le voir
    // depuis votre testbench.

    volatile uint64_t total_cycles = end - start;

    // // Vérification
    // if (result == EXPECTED_RESULT) {
    //     // Test réussi : on écrit un code de succès
    //     *(volatile uint32_t*)0x80001000 = 0x1;
    // } else {
    //     // Test échoué : on provoque une exception "Illegal Instruction"
    //     // Le simulateur va lever une exception, ce qui te permet
    //     // de voir exactement quel cycle a fait planter le processeur.
    //     __asm__ volatile (".word 0x0");
    // }

    return 0; // Point d'arrêt ici dans votre simulateur
}
