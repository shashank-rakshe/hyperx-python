/* File: tests/test_c_api_stack.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Bounded-stack gate for the shared library (Win32 threads or POSIX threads).
 *
 * Usage: test_c_api_stack <stack_kib> <dt> <deck.dat> [<dt> <deck.dat> ...]
 *
 * A host such as python.exe calls the library on its own threads, with the stack
 * size the host chose (python.exe reserves about 2 MB; the Windows default for an
 * MSVC-linked program is 1 MB), so the library must not rely on the stack reserve of
 * a CableDyn executable. For every deck this program starts one thread whose stack
 * is <stack_kib> KiB and, on that thread, creates a handle, initialises the deck,
 * steps it with the coupled points held (coupling step <dt> s), saves the state, takes
 * one more step and restores it (the whole-model copies of CableDyn_SaveState and
 * CableDyn_RestoreState), evaluates the coupled loads, initialises the deck again with
 * the statics at the coupled positions (CableDyn_InitDeckAt with the full coupled
 * vector), evaluates the loads again, and closes the handle. A stack
 * overflow ends the process (SIGSEGV on POSIX systems, STATUS_STACK_OVERFLOW on
 * Windows), which fails the test. On Windows the deepest stack page the thread touched
 * is also reported.
 */
#include "CableDyn_CAPI.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#include <process.h>
#else
#include <limits.h>
#include <pthread.h>
#include <unistd.h>
#endif

enum { N_STEP = 3 };

struct deck_task {
    const char *deck;
    double dt;
    int status;          /* 0 = pass */
    int ndof;
    size_t peak_bytes;   /* deepest committed stack (Windows), 0 elsewhere */
    char message[1100];
};

static size_t stack_in_use(void)
{
#if defined(_WIN32)
    /* The stack is committed one guard page at a time from the top of its reservation
     * down, and never decommitted: the pages still only reserved at the bottom of the
     * reservation were never touched, and the rest is the thread's high-water mark. */
    MEMORY_BASIC_INFORMATION here, bottom;
    volatile char marker = 0;
    char *top;

    if (VirtualQuery((const void *)&marker, &here, sizeof here) == 0) return 0;
    if (VirtualQuery(here.AllocationBase, &bottom, sizeof bottom) == 0) return 0;
    top = (char *)here.BaseAddress + here.RegionSize;
    if (bottom.State != MEM_RESERVE) return (size_t)(top - (char *)here.AllocationBase);
    return (size_t)(top - ((char *)bottom.BaseAddress + bottom.RegionSize));
#else
    return 0;
#endif
}

static void fail(struct deck_task *t, void *m, const char *what)
{
    char last[1025] = "";
    if (m != NULL) CableDyn_GetLastError(m, last, (int)sizeof last);
    snprintf(t->message, sizeof t->message, "%s%s%s", what, last[0] ? ": " : "", last);
    t->status = 1;
}

static void run_deck(struct deck_task *t)
{
    void *m = NULL;
    int err = -1, ndof, n_iter = 0, i, step;
    bool converged = false, stalled = true;
    double *q = NULL, *v = NULL, *a = NULL, *loads = NULL;

    t->status = 0;
    CableDyn_Create(&m, &err);
    if (err != CD_C_OK || m == NULL) {
        fail(t, NULL, "create failed");
        return;
    }
    CableDyn_InitDeck(m, t->deck, (int)strlen(t->deck), &err);
    if (err != CD_C_OK) {
        fail(t, m, "deck initialisation failed");
        goto done;
    }
    ndof = CableDyn_NCoupledDOF(m, &err);
    t->ndof = ndof;
    if (err != CD_C_OK || ndof <= 0) {
        fail(t, m, "coupled DOF query failed");
        goto done;
    }
    q = calloc((size_t)ndof, sizeof *q);
    v = calloc((size_t)ndof, sizeof *v);
    a = calloc((size_t)ndof, sizeof *a);
    loads = calloc((size_t)ndof, sizeof *loads);
    if (!q || !v || !a || !loads) {
        fail(t, NULL, "allocation failed");
        goto done;
    }
    CableDyn_GetCoupledMotion(m, q, v, a, ndof, &err);
    if (err != CD_C_OK) {
        fail(t, m, "coupled motion query failed");
        goto done;
    }
    for (step = 0; step < N_STEP; ++step) {
        CableDyn_Step(m, t->dt, q, v, a, ndof, &converged, &stalled, &n_iter, &err);
        if (err != CD_C_OK || !converged || stalled) {
            fail(t, m, "held-point step did not converge");
            goto done;
        }
    }
    CableDyn_SaveState(m, &err);
    if (err != CD_C_OK) {
        fail(t, m, "state save failed");
        goto done;
    }
    CableDyn_Step(m, t->dt, q, v, a, ndof, &converged, &stalled, &n_iter, &err);
    if (err != CD_C_OK || !converged || stalled) {
        fail(t, m, "held-point step after the save did not converge");
        goto done;
    }
    CableDyn_RestoreState(m, &err);
    if (err != CD_C_OK) {
        fail(t, m, "state restore failed");
        goto done;
    }
    CableDyn_CalcOutput(m, loads, ndof, &err);
    if (err != CD_C_OK) {
        fail(t, m, "output failed");
        goto done;
    }
    for (i = 0; i < ndof; ++i) {
        if (!isfinite(loads[i])) {
            fail(t, NULL, "non-finite coupled load");
            goto done;
        }
    }
    /* Re-initialise with the statics at the coupled positions (the full-vector q0 form). */
    CableDyn_InitDeckAt(m, t->deck, (int)strlen(t->deck), q, ndof, &err);
    if (err != CD_C_OK) {
        fail(t, m, "initialisation at the coupled positions failed");
        goto done;
    }
    CableDyn_CalcOutput(m, loads, ndof, &err);
    if (err != CD_C_OK) {
        fail(t, m, "output after the initialisation at the coupled positions failed");
        goto done;
    }
    for (i = 0; i < ndof; ++i) {
        if (!isfinite(loads[i])) {
            fail(t, NULL, "non-finite coupled load after the initialisation at the coupled positions");
            goto done;
        }
    }

done:
    free(q);
    free(v);
    free(a);
    free(loads);
    CableDyn_Close(&m, &err);
    if (t->status == 0 && err != CD_C_OK) fail(t, NULL, "close failed");
    t->peak_bytes = stack_in_use();
}

#if defined(_WIN32)
static unsigned __stdcall deck_thread(void *arg)
{
    run_deck((struct deck_task *)arg);
    return 0;
}

static int run_on_small_stack(struct deck_task *t, size_t stack_bytes)
{
    /* A reservation, as the linker's stack reserve of an executable, not a commit. */
    HANDLE th = (HANDLE)_beginthreadex(NULL, (unsigned)stack_bytes, deck_thread, t,
                                       STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
    DWORD waited;

    if (th == NULL) return 1;
    waited = WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
    return waited != WAIT_OBJECT_0;
}
#else
static void *deck_thread(void *arg)
{
    run_deck((struct deck_task *)arg);
    return NULL;
}

static int run_on_small_stack(struct deck_task *t, size_t stack_bytes)
{
    pthread_attr_t attr;
    pthread_t th;
    long page = sysconf(_SC_PAGESIZE);
    int rc;

#if defined(PTHREAD_STACK_MIN)
    if (stack_bytes < (size_t)PTHREAD_STACK_MIN) stack_bytes = (size_t)PTHREAD_STACK_MIN;
#endif
    /* Some systems (macOS) accept only a whole number of pages. */
    if (page > 0) stack_bytes = (stack_bytes + (size_t)page - 1) / (size_t)page * (size_t)page;
    if (pthread_attr_init(&attr) != 0) return 1;
    rc = pthread_attr_setstacksize(&attr, stack_bytes);
    if (rc == 0) rc = pthread_create(&th, &attr, deck_thread, t);
    pthread_attr_destroy(&attr);
    if (rc != 0) return 1;
    return pthread_join(th, NULL) != 0;
}
#endif

int main(int argc, char **argv)
{
    long stack_kib;
    char *end;
    int i, failures = 0;
    struct deck_task task;

    if (argc < 4 || (argc - 2) % 2 != 0) {
        fputs("usage: test_c_api_stack <stack_kib> <dt> <deck.dat> [<dt> <deck.dat> ...]\n",
              stderr);
        return 2;
    }
    stack_kib = strtol(argv[1], &end, 10);
    if (end == argv[1] || *end != '\0' || stack_kib <= 0 || stack_kib > 1048576L) {
        fputs("FAIL: the stack size must be a whole number of KiB in [1, 1048576]\n", stderr);
        return 2;
    }
    for (i = 3; i < argc; i += 2) {
        memset(&task, 0, sizeof task);
        task.deck = argv[i];
        task.dt = strtod(argv[i - 1], &end);
        if (end == argv[i - 1] || *end != '\0' || !(task.dt > 0.0) || !isfinite(task.dt)) {
            fprintf(stderr, "FAIL: %s: the coupling step must be positive\n", argv[i]);
            ++failures;
            continue;
        }
        if (run_on_small_stack(&task, (size_t)stack_kib * 1024u) != 0) {
            fprintf(stderr, "FAIL: %s: could not start a thread with a %ld KiB stack\n",
                    argv[i], stack_kib);
            ++failures;
            continue;
        }
        if (task.status != 0) {
            fprintf(stderr, "FAIL: %s: %s\n", argv[i], task.message);
            ++failures;
            continue;
        }
        if (task.peak_bytes > 0) {
            printf("%s: %d coupled DOFs, %d steps, deepest stack %zu of %ld KiB\n", argv[i],
                   task.ndof, N_STEP, task.peak_bytes / 1024u, stack_kib);
        } else {
            printf("%s: %d coupled DOFs, %d steps on a %ld KiB stack\n", argv[i], task.ndof,
                   N_STEP, stack_kib);
        }
    }
    if (failures != 0) {
        fprintf(stderr, "test_c_api_stack: %d deck(s) failed\n", failures);
        return 1;
    }
    puts("PASS: every deck ran within the thread stack");
    return 0;
}
