#include <stdint.h>

// Lecture du compteur de cycles (mcycle) sur RISC-V 32-bit
static inline uint32_t read_mcycle() {
    uint32_t val;
    __asm__ volatile ("csrr %0, mcycle" : "=r" (val));
    return val;
}

#define SIZE 128
#define ITERATIONS 50  // <--- PARAMÈTRE : Ajustez cette valeur pour faire durer le test plus ou moins longtemps !

// Alignement sur 64 octets pour s'assurer que les données soient sur des lignes de cache distinctes
volatile uint32_t data_array[SIZE] __attribute__((aligned(64)));

void init_data() {
    // Initialisation pour le test de "Pointer Chasing" (accès dépendants)
    // Chaque case contient l'adresse mémoire de la case suivante
    for (int i = 0; i < SIZE - 1; i++) {
        data_array[i] = (uint32_t)&data_array[i + 1];
    }
    data_array[SIZE - 1] = (uint32_t)&data_array[0]; // Boucle de retour
}

// TEST 1 : Accès Mémoire Indépendants
// Idéal pour voir si le CPU / LSU sait paralléliser des requêtes indépendantes
__attribute__((noinline))
uint32_t test_independent_loads() {
    uint32_t sum = 0;
    for (int i = 0; i < ITERATIONS; i++) {
        // Lectures à des offsets espacés pour forcer des lignes de cache différentes
        volatile uint32_t r0 = data_array[0];
        volatile uint32_t r1 = data_array[16];
        volatile uint32_t r2 = data_array[32];
        volatile uint32_t r3 = data_array[48];
        volatile uint32_t r4 = data_array[64];
        volatile uint32_t r5 = data_array[80];
        volatile uint32_t r6 = data_array[96];
        volatile uint32_t r7 = data_array[112];

        sum += r0 + r1 + r2 + r3 + r4 + r5 + r6 + r7;
    }
    return sum;
}

// TEST 2 : Accès Mémoire Dépendants (Pointer Chasing)
// Strictement séquentiel : l'adresse suivante est chargée depuis le contenu lu
__attribute__((noinline))
uint32_t test_dependent_loads() {
    volatile uint32_t *ptr = &data_array[0];
    for (int i = 0; i < ITERATIONS * 8; i++) { // Même nombre total d'accès (8 * ITERATIONS)
        ptr = (volatile uint32_t *)*ptr;
    }
    return (uint32_t)ptr;
}

int main() {
    init_data();

    uint32_t start, end;
    volatile uint32_t cycles_indep = 0;
    volatile uint32_t cycles_dep = 0;

    // 1. Mesure des accès indépendants
    start = read_mcycle();
    test_independent_loads();
    end = read_mcycle();
    cycles_indep = end - start;

    // 2. Mesure des accès dépendants
    start = read_mcycle();
    test_dependent_loads();
    end = read_mcycle();
    cycles_dep = end - start;

    // Calcul du ratio de performance (exprimé en %)
    // Sur un CPU purement In-Order classique, cycles_indep et cycles_dep seront très proches.
    // Sur un CPU OoO performant ou avec cache non-bloquant, cycles_indep sera bien plus faible.
    volatile uint32_t result_ratio = (cycles_dep * 100) / cycles_indep;

    return 0; // Point d'arrêt de simulation
}
