/* File: tests/test_memory_growth.c
 * SPDX-License-Identifier: Apache-2.0
 * Long-march memory-growth gate for the C API deck route.
 *
 * Usage: test_memory_growth <max_growth_MiB> <deck.dat> <n_steps> [<deck.dat> <n_steps> ...]
 * For every deck: initialize, drive the coupled points with a smooth surge
 * oscillation, take warm-up steps so lazily sized workspaces reach their
 * steady capacity, then march n_steps more and require the process memory
 * (Windows private commit, Linux resident set) to grow by less than the bound.
 * Exits 77 (CTest skip) where the platform exposes no process memory counter.
 */
#include "CableDyn_CAPI.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SKIP_CODE 77
#define WARMUP_STEPS 200
#define DT 0.05
#define SURGE_AMPLITUDE 0.5
#define SURGE_PERIOD 20.0

/* Process memory in MiB, or a negative value when unavailable (tests/process_memory.c). */
double cd_test_process_memory_mib(void);

static void prescribe(const double *q0, double *q, double *v, double *a, int ndof, double t)
{
    const double w = 2.0 * acos(-1.0) / SURGE_PERIOD;
    /* Ramp the amplitude in over one period so the first step starts at rest. */
    const double ramp = t < SURGE_PERIOD ? t / SURGE_PERIOD : 1.0;
    int i;
    for (i = 0; i < ndof; ++i) {
        q[i] = q0[i];
        v[i] = 0.0;
        a[i] = 0.0;
        if (i % 3 == 0) {
            q[i] += ramp * SURGE_AMPLITUDE * sin(w * t);
            v[i] = ramp * SURGE_AMPLITUDE * w * cos(w * t);
            a[i] = -ramp * SURGE_AMPLITUDE * w * w * sin(w * t);
        }
    }
}

static int march(void *m, const double *q0, double *q, double *v, double *a, double *loads, int ndof,
                 int first_step, int n_steps)
{
    int k, err = -1, n_iter = 0;
    bool converged = false, stalled = true;
    for (k = first_step; k < first_step + n_steps; ++k) {
        prescribe(q0, q, v, a, ndof, (k + 1) * DT);
        CableDyn_Step(m, DT, q, v, a, ndof, &converged, &stalled, &n_iter, &err);
        if (err != CD_C_OK || !converged || stalled) {
            char message[1025];
            CableDyn_GetLastError(m, message, (int)sizeof message);
            fprintf(stderr, "FAIL: step %d did not converge (err %d): %s\n", k + 1, err, message);
            return 1;
        }
        CableDyn_CalcOutput(m, loads, ndof, &err);
        if (err != CD_C_OK) {
            fprintf(stderr, "FAIL: output at step %d\n", k + 1);
            return 1;
        }
    }
    return 0;
}

static int check_deck(const char *deck, int n_steps, double max_growth)
{
    void *m = NULL;
    int err = -1, ndof, status = 1;
    double *q0 = NULL, *q = NULL, *v = NULL, *a = NULL, *loads = NULL;
    double mem_start, mem_end;

    CableDyn_Create(&m, &err);
    if (err != CD_C_OK) {
        fputs("FAIL: create\n", stderr);
        return 1;
    }
    CableDyn_InitDeck(m, deck, (int)strlen(deck), &err);
    if (err != CD_C_OK) {
        char message[1025];
        CableDyn_GetLastError(m, message, (int)sizeof message);
        fprintf(stderr, "FAIL: %s initialization: %s\n", deck, message);
        goto done;
    }
    ndof = CableDyn_NCoupledDOF(m, &err);
    if (err != CD_C_OK || ndof <= 0) {
        fprintf(stderr, "FAIL: %s has no coupled DOFs to drive\n", deck);
        goto done;
    }
    q0 = calloc((size_t)ndof, sizeof *q0);
    q = calloc((size_t)ndof, sizeof *q);
    v = calloc((size_t)ndof, sizeof *v);
    a = calloc((size_t)ndof, sizeof *a);
    loads = calloc((size_t)ndof, sizeof *loads);
    if (!q0 || !q || !v || !a || !loads) {
        fputs("FAIL: allocation\n", stderr);
        goto done;
    }
    CableDyn_GetCoupledMotion(m, q0, v, a, ndof, &err);
    if (err != CD_C_OK) {
        fputs("FAIL: coupled motion query\n", stderr);
        goto done;
    }
    if (march(m, q0, q, v, a, loads, ndof, 0, WARMUP_STEPS)) goto done;
    mem_start = cd_test_process_memory_mib();
    if (march(m, q0, q, v, a, loads, ndof, WARMUP_STEPS, n_steps)) goto done;
    mem_end = cd_test_process_memory_mib();
    printf("%s: %d steps, memory %.2f -> %.2f MiB (growth %.3f MiB, %.3f KiB/step)\n", deck, n_steps, mem_start,
           mem_end, mem_end - mem_start, 1024.0 * (mem_end - mem_start) / n_steps);
    if (mem_end - mem_start >= max_growth) {
        fprintf(stderr, "FAIL: %s memory grew %.3f MiB over %d steps (bound %.3f MiB)\n", deck, mem_end - mem_start,
                n_steps, max_growth);
        goto done;
    }
    status = 0;

done:
    free(q0);
    free(q);
    free(v);
    free(a);
    free(loads);
    CableDyn_Close(&m, &err);
    return status;
}

int main(int argc, char **argv)
{
    double max_growth;
    int i;

    if (argc < 4 || (argc - 2) % 2 != 0) {
        fputs("usage: test_memory_growth <max_growth_MiB> <deck.dat> <n_steps> [<deck.dat> <n_steps> ...]\n", stderr);
        return 2;
    }
    if (cd_test_process_memory_mib() < 0.0) {
        puts("SKIP: no process memory counter on this platform");
        return SKIP_CODE;
    }
    max_growth = atof(argv[1]);
    if (!(max_growth > 0.0)) {
        fputs("FAIL: max_growth_MiB must be positive\n", stderr);
        return 2;
    }
    for (i = 2; i < argc; i += 2) {
        int n_steps = atoi(argv[i + 1]);
        if (n_steps <= 0) {
            fprintf(stderr, "FAIL: invalid step count for %s\n", argv[i]);
            return 2;
        }
        if (check_deck(argv[i], n_steps, max_growth)) return 1;
    }
    puts("PASS: bounded memory over long coupled marches");
    return 0;
}
