#include <stdint.h>

// Fonction pour lire le registre mcycle (compteur de cycles)
static inline uint64_t read_mcycle() {
    uint64_t val;
    __asm__ volatile ("csrr %0, mcycle" : "=r" (val));
    return val;
}

// Fonction de charge de travail (Workload)
// Ajustez cette constante pour changer la durée
#define WORKLOAD_SIZE 10

void heavy_computation() {
    volatile int a = 0;
    for (int i = 0; i < WORKLOAD_SIZE; i++) {
        for (int j = 0; j < WORKLOAD_SIZE; j++) {
            a = (a + i * j) % 123;
        }
    }
}

int main() {
    uint64_t start, end;

    // Mesure du début
    start = read_mcycle();

    // Exécution de la charge
    heavy_computation();

    // Mesure de la fin
    end = read_mcycle();

    // Le résultat (end - start) est le nombre de cycles
    // Dans un environnement bare-metal, vous voudrez probablement
    // écrire ce résultat dans une adresse mémoire spécifique
    // ou via une instruction de sortie (syscall) pour le voir
    // depuis votre testbench.

    volatile uint64_t total_cycles = end - start;

    return 0; // Point d'arrêt ici dans votre simulateur
}
