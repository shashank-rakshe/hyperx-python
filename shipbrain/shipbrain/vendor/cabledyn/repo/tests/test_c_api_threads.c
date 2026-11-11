/* File: tests/test_c_api_threads.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Portable (Win32 threads or POSIX threads) C API threading and resource gate.
 *
 * Usage: test_c_api_threads <chain_deck.dat> <syrope_deck.dat> <expected_blas_threads>
 *
 * The process first switches to the user's locale (setlocale(LC_ALL, "")), the
 * setting every Python interpreter and many GUI hosts run in, then checks:
 *   0. Run-time BLAS loading (Windows GNU builds): openblas.dll is not mapped before
 *      the first CableDyn call, i.e. no CableDyn routine imports it at load time.
 *   1. BLAS policy (Windows): after CableDyn_Create the OpenBLAS in the process runs
 *      <expected_blas_threads> threads (0 = no OpenBLAS setter linked, not checked),
 *      and the private bytes committed by loading the BLAS runtime, initialising and
 *      stepping one deck stay small (a threaded OpenBLAS commits one ~128 MB work
 *      buffer per logical CPU when its DLL loads).
 *   2. 8 threads initialise the SAME deck concurrently; every call succeeds.
 *   3. 8 threads initialise the same Syrope deck, which shares one OWC table file.
 *   4. A missing deck reports "file not found".
 *   5. 24 threads step distinct handles concurrently while other threads keep
 *      failing to open a missing deck; every trajectory, and the line values each thread
 *      reads at every step, match a serial reference.
 *
 * test_c_api_threads --mixed <n_steps> <deck> [<deck> ...] instead steps every deck on
 * several threads at once, all decks concurrently (each handle its own model: EI = 0
 * lines, finite-EI cables, Syrope and viscoelastic segments, points, bodies and rods take
 * their own code paths), n_steps steps each, and checks every trajectory and the line
 * values read at every step against the deck's serial reference. A procedure whose locals or callbacks live in storage that
 * every thread shares (static locals, closure trampolines) fails it.
 *
 * CABLEDYN_THREAD_TEST_LOOPS=<n> repeats checks 2-5 n times in one process (stress
 * mode). A watchdog thread ends the process with a failure naming the phase in
 * progress when the run exceeds CABLEDYN_THREAD_TEST_TIMEOUT seconds (default 300),
 * so a deadlock fails the gate instead of hanging it. With
 * CABLEDYN_THREAD_TEST_HOLD=<s> the watchdog keeps a hung process alive that many
 * seconds before ending it, to attach a debugger.
 *
 * Windows: test_c_api_threads --exit-stress <deck.dat> <n> starts n child processes
 * in which 24 host threads each initialise, step, and close a model; the child then
 * returns from main at once. A child that has not fully ended after
 * CABLEDYN_THREAD_TEST_EXIT_TIMEOUT seconds (default 120) fails the gate: a hang at
 * process exit, which no in-process watchdog can report, since process exit ends the
 * watchdog thread first.
 */
#include "CableDyn_CAPI.h"

#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#include <process.h>
#include <psapi.h>
#else
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#endif

enum { MAX_THREADS = 32, MAX_DOF = 256, N_STEP = 120 };

static const double STEP_DT = 0.05;

/* ----------------------------------------------------------------- watchdog -- */

/* The phase in progress, for the watchdog message. */
static const char *volatile current_phase = "start";

static long env_seconds(const char *name, long fallback)
{
    const char *text = getenv(name);
    char *end = NULL;
    long value;

    if (text == NULL || text[0] == '\0') return fallback;
    value = strtol(text, &end, 10);
    return (end == text || *end != '\0' || value < 0) ? fallback : value;
}

/* Writes msg to stderr and ends the process at once. It uses neither the C runtime
 * stdio lock nor the DLL detach path, either of which a deadlocked thread can hold. */
static void watchdog_fail(const char *msg)
{
#if defined(_WIN32)
    DWORD written;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), msg, (DWORD)strlen(msg), &written, NULL);
    TerminateProcess(GetCurrentProcess(), 3);
#else
    ssize_t rc = write(2, msg, strlen(msg));
    (void)rc;
    _exit(3);
#endif
}

static long watchdog_timeout_s, watchdog_hold_s;

#if defined(_WIN32)
static unsigned __stdcall watchdog_main(void *raw)
#else
static void *watchdog_main(void *raw)
#endif
{
    char msg[256];
    (void)raw;
#if defined(_WIN32)
    Sleep((DWORD)(watchdog_timeout_s * 1000));
#else
    sleep((unsigned)watchdog_timeout_s);
#endif
    snprintf(msg, sizeof msg, "FAIL watchdog: not finished after %ld s, in phase '%s' (pid %ld); deadlock?\n",
             watchdog_timeout_s, current_phase,
#if defined(_WIN32)
             (long)GetCurrentProcessId());
#else
             (long)getpid());
#endif
    if (watchdog_hold_s > 0) {
#if defined(_WIN32)
        DWORD written;
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), msg, (DWORD)strlen(msg), &written, NULL);
        Sleep((DWORD)(watchdog_hold_s * 1000));
#else
        ssize_t rc = write(2, msg, strlen(msg));
        (void)rc;
        sleep((unsigned)watchdog_hold_s);
#endif
    }
    watchdog_fail(msg);
    return 0;
}

/* Starts the watchdog, which ends the process with a failure if it is still running
 * after the timeout; returns 0 on success. It cannot report a hang in the DLL detach
 * stage of process exit, which starts by ending every other thread (see --exit-stress). */
static int watchdog_start(void)
{
    watchdog_timeout_s = env_seconds("CABLEDYN_THREAD_TEST_TIMEOUT", 300);
    watchdog_hold_s = env_seconds("CABLEDYN_THREAD_TEST_HOLD", 0);
    if (watchdog_timeout_s == 0) return 0;
#if defined(_WIN32)
    {
        HANDLE th = (HANDLE)_beginthreadex(NULL, 0, watchdog_main, NULL, 0, NULL);
        if (th == NULL) return 1;
        CloseHandle(th);
        return 0;
    }
#else
    {
        pthread_t th;
        if (pthread_create(&th, NULL, watchdog_main, NULL) != 0) return 1;
        return pthread_detach(th) != 0;
    }
#endif
}

/* ------------------------------------------------------------------ threads -- */

typedef void (*task_fn)(void *);

struct task {
    task_fn fn;
    void *arg;
};

#if defined(_WIN32)
static HANDLE gate_event;

static unsigned __stdcall trampoline(void *raw)
{
    struct task *t = (struct task *)raw;
    WaitForSingleObject(gate_event, INFINITE);
    t->fn(t->arg);
    return 0;
}

/* Starts n tasks, releases them together, and joins them; returns 0 on success. */
static int run_tasks(int n, struct task *tasks)
{
    HANDLE th[MAX_THREADS];
    int i, started = 0, rc = 0;

    gate_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (gate_event == NULL) return 1;
    for (i = 0; i < n; ++i) {
        th[i] = (HANDLE)_beginthreadex(NULL, 0, trampoline, &tasks[i], 0, NULL);
        if (th[i] == NULL) {
            rc = 1;
            break;
        }
        ++started;
    }
    SetEvent(gate_event);
    for (i = 0; i < started; ++i) {
        WaitForSingleObject(th[i], INFINITE);
        CloseHandle(th[i]);
    }
    CloseHandle(gate_event);
    return rc;
}
#else
static pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cond = PTHREAD_COND_INITIALIZER;
static int gate_open = 0;

static void *trampoline(void *raw)
{
    struct task *t = (struct task *)raw;
    pthread_mutex_lock(&gate_mutex);
    while (!gate_open) pthread_cond_wait(&gate_cond, &gate_mutex);
    pthread_mutex_unlock(&gate_mutex);
    t->fn(t->arg);
    return NULL;
}

static int run_tasks(int n, struct task *tasks)
{
    pthread_t th[MAX_THREADS];
    int i, started = 0, rc = 0;

    gate_open = 0;
    for (i = 0; i < n; ++i) {
        if (pthread_create(&th[i], NULL, trampoline, &tasks[i]) != 0) {
            rc = 1;
            break;
        }
        ++started;
    }
    pthread_mutex_lock(&gate_mutex);
    gate_open = 1;
    pthread_cond_broadcast(&gate_cond);
    pthread_mutex_unlock(&gate_mutex);
    for (i = 0; i < started; ++i) pthread_join(th[i], NULL);
    return rc;
}
#endif

/* ------------------------------------------------------------------ helpers -- */

static int init_deck(void *handle, const char *path)
{
    int err = -1;
    CableDyn_InitDeck(handle, path, (int)strlen(path), &err);
    return err;
}

static double private_mb(void)
{
#if defined(_WIN32)
    PROCESS_MEMORY_COUNTERS_EX pmc;
    memset(&pmc, 0, sizeof pmc);
    pmc.cb = sizeof pmc;
    if (!GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&pmc, sizeof pmc)) return -1.0;
    return (double)pmc.PrivateUsage / (1024.0 * 1024.0);
#else
    return -1.0;
#endif
}

/* Reads every node quantity of every line of the handle and adds up their magnitudes. */
static double read_lines(void *h, int *err)
{
    static const int width[8] = {3, 3, 1, 3, 1, 1, 1, 1}; /* CD_C_LINE_POSITION .. _AZIMUTH */
    double sum = 0.0;
    int n_lines = CableDyn_NObjects(h, CD_C_OBJ_LINE, err), line, quantity, i;

    for (line = 0; line < n_lines && *err == CD_C_OK; ++line) {
        int id, nn, sub;
        double *buf;
        CableDyn_GetObjectInfo(h, CD_C_OBJ_LINE, line, &id, &nn, &sub, err);
        if (*err != CD_C_OK) break;
        buf = (double *)malloc(3 * (size_t)nn * sizeof *buf);
        if (buf == NULL) {
            *err = CD_C_ALLOC_FAIL;
            break;
        }
        for (quantity = 1; quantity <= 8 && *err == CD_C_OK; ++quantity) {
            int n = width[quantity - 1] * nn;
            CableDyn_GetLineValues(h, line, quantity, buf, n, err);
            for (i = 0; i < n && *err == CD_C_OK; ++i) sum += fabs(buf[i]);
        }
        free(buf);
    }
    return sum;
}

/* Initialises `path`, takes n_step steps reading its lines at each, and records the final
 * coupled loads and the sum of the line values read. */
static int step_deck(const char *path, int n_step, double *loads, double *lines, int *ndof_out, char *msg,
                     size_t msg_len)
{
    void *h = NULL;
    int err = -1, ndof, k, n_iter = 0;
    bool converged = false, stalled = false;
    double q[MAX_DOF], v[MAX_DOF], a[MAX_DOF];

    CableDyn_Create(&h, &err);
    if (err != CD_C_OK) return 1;
    if (init_deck(h, path) != CD_C_OK) {
        CableDyn_GetLastError(h, msg, (int)msg_len);
        CableDyn_Close(&h, &err);
        return 1;
    }
    ndof = CableDyn_NCoupledDOF(h, &err);
    if (err != CD_C_OK || ndof < 1 || ndof > MAX_DOF) {
        CableDyn_Close(&h, &err);
        return 1;
    }
    CableDyn_GetCoupledMotion(h, q, v, a, ndof, &err);
    *lines = 0.0;
    for (k = 0; k < n_step && err == CD_C_OK; ++k) {
        /* A slow surge of every coupled x DOF keeps the lines working. */
        int i;
        for (i = 0; i < ndof; i += 3) q[i] += 0.002;
        CableDyn_Step(h, STEP_DT, q, v, a, ndof, &converged, &stalled, &n_iter, &err);
        /* a non-converged or stalled step is a failed trajectory, even a deterministic one */
        if (err == CD_C_OK && (!converged || stalled)) {
            CableDyn_Close(&h, &err);
            return 1;
        }
        if (err == CD_C_OK) *lines += read_lines(h, &err);
    }
    if (err == CD_C_OK) CableDyn_CalcOutput(h, loads, ndof, &err);
    if (err != CD_C_OK) CableDyn_GetLastError(h, msg, (int)msg_len);
    *ndof_out = ndof;
    CableDyn_Close(&h, &err);
    return err != CD_C_OK;
}

/* ------------------------------------------------------------ worker tasks -- */

struct init_job {
    const char *path;
    int repeats;
    int ok;
    int failed;
    char msg[512];
};

static void init_worker(void *raw)
{
    struct init_job *job = (struct init_job *)raw;
    void *h = NULL;
    int err = -1, k;

    CableDyn_Create(&h, &err);
    if (err != CD_C_OK) {
        job->failed = job->repeats;
        return;
    }
    for (k = 0; k < job->repeats; ++k) {
        if (init_deck(h, job->path) == CD_C_OK) {
            ++job->ok;
        } else {
            ++job->failed;
            CableDyn_GetLastError(h, job->msg, (int)sizeof job->msg);
        }
    }
    CableDyn_Close(&h, &err);
}

struct step_job {
    const char *path;
    const char *missing_path;
    int n_step;
    int ndof;
    int failed;
    double loads[MAX_DOF];
    double lines;
    char msg[512];
};

static void step_worker(void *raw)
{
    struct step_job *job = (struct step_job *)raw;
    job->failed = step_deck(job->path, job->n_step, job->loads, &job->lines, &job->ndof, job->msg, sizeof job->msg);
}

static void missing_worker(void *raw)
{
    struct step_job *job = (struct step_job *)raw;
    void *h = NULL;
    int err = -1, k;

    CableDyn_Create(&h, &err);
    for (k = 0; k < 40; ++k) {
        if (init_deck(h, job->missing_path) == CD_C_OK) ++job->failed;
    }
    CableDyn_Close(&h, &err);
}

/* ------------------------------------------------------------------- checks -- */

static int check_blas_and_memory(const char *deck, int expected_threads)
{
    void *h = NULL;
    int err = -1, ndof, k, n_iter = 0;
    bool converged = false, stalled = false;
    double q[MAX_DOF], v[MAX_DOF], a[MAX_DOF], before, after;

    before = private_mb();
    CableDyn_Create(&h, &err);
    if (err != CD_C_OK || init_deck(h, deck) != CD_C_OK) {
        fprintf(stderr, "FAIL memory probe could not initialise %s\n", deck);
        return 1;
    }
    ndof = CableDyn_NCoupledDOF(h, &err);
    CableDyn_GetCoupledMotion(h, q, v, a, ndof, &err);
    for (k = 0; k < 5 && err == CD_C_OK; ++k) {
        CableDyn_Step(h, STEP_DT, q, v, a, ndof, &converged, &stalled, &n_iter, &err);
        if (err == CD_C_OK && (!converged || stalled)) {
            fprintf(stderr, "FAIL memory probe step %d did not converge on %s\n", k, deck);
            CableDyn_Close(&h, &err);
            return 1;
        }
    }
    if (err != CD_C_OK) {
        fprintf(stderr, "FAIL memory probe step failed on %s\n", deck);
        CableDyn_Close(&h, &err);
        return 1;
    }
#if defined(_WIN32)
    if (expected_threads > 0) {
        typedef int(__cdecl * get_threads_fn)(void);
        HMODULE blas = GetModuleHandleW(L"openblas.dll");
        FARPROC proc = blas != NULL ? GetProcAddress(blas, "openblas_get_num_threads") : NULL;
        get_threads_fn get_threads = NULL;
        int threads = -1;

        if (proc != NULL) {
            memcpy(&get_threads, &proc, sizeof get_threads);
            threads = get_threads();
        }
        if (threads != expected_threads) {
            fprintf(stderr, "FAIL OpenBLAS runs %d thread(s) after CableDyn_Create, expected %d\n", threads,
                    expected_threads);
            CableDyn_Close(&h, &err);
            return 1;
        }
    }
    /* OpenBLAS workers commit their buffers asynchronously after the DLL loads. */
    Sleep(300);
#endif
    after = private_mb();
    CableDyn_Close(&h, &err);
    if (before >= 0.0) {
        printf("memory: private bytes %+.1f MB over BLAS load + init + 5 steps\n", after - before);
        /* OpenBLAS commits one work buffer of about 128 MB per thread that calls it: the
         * caller, plus each thread of the per-line OpenMP team (at most 4, see
         * CableDyn_System), so at most 4 buffers whatever the core or OpenMP thread
         * count. A pool of 5 or more OpenBLAS workers exceeds this bound. */
        if (expected_threads > 0 && after - before > 640.0) {
            fprintf(stderr, "FAIL loading and stepping committed %.1f MB of private memory\n", after - before);
            return 1;
        }
    }
    return 0;
}

static int check_concurrent_init(const char *deck, int n, int repeats, const char *label)
{
    struct init_job jobs[MAX_THREADS];
    struct task tasks[MAX_THREADS];
    int i, ok = 0, failed = 0;

    memset(jobs, 0, sizeof jobs);
    for (i = 0; i < n; ++i) {
        jobs[i].path = deck;
        jobs[i].repeats = repeats;
        tasks[i].fn = init_worker;
        tasks[i].arg = &jobs[i];
    }
    if (run_tasks(n, tasks) != 0) {
        fprintf(stderr, "FAIL could not start %s threads\n", label);
        return 1;
    }
    for (i = 0; i < n; ++i) {
        ok += jobs[i].ok;
        failed += jobs[i].failed;
        if (jobs[i].failed) fprintf(stderr, "  thread %d: %s\n", i, jobs[i].msg);
    }
    printf("%s: %d threads x %d InitDeck: ok=%d failed=%d\n", label, n, repeats, ok, failed);
    if (failed != 0) {
        fprintf(stderr, "FAIL concurrent InitDeck (%s)\n", label);
        return 1;
    }
    return 0;
}

static int check_missing_message(void)
{
    void *h = NULL;
    int err = -1;
    char msg[512] = {0};

    CableDyn_Create(&h, &err);
    if (init_deck(h, "this_deck_does_not_exist.dat") != CD_C_BAD_INPUT) {
        fprintf(stderr, "FAIL a missing deck was not rejected as bad input\n");
        return 1;
    }
    CableDyn_GetLastError(h, msg, (int)sizeof msg);
    CableDyn_Close(&h, &err);
    if (strstr(msg, "file not found") == NULL) {
        fprintf(stderr, "FAIL missing-deck diagnostic lacks 'file not found': %s\n", msg);
        return 1;
    }
    return 0;
}

static int check_concurrent_steps(const char *deck)
{
    enum { N_STEPPERS = 24, N_MISSING = 4 };
    static struct step_job jobs[N_STEPPERS + N_MISSING];
    struct task tasks[N_STEPPERS + N_MISSING];
    double reference[MAX_DOF], reference_lines = 0.0;
    char msg[512] = {0};
    int i, j, ndof = 0, failed = 0;

    if (step_deck(deck, N_STEP, reference, &reference_lines, &ndof, msg, sizeof msg) != 0) {
        fprintf(stderr, "FAIL serial reference run: %s\n", msg);
        return 1;
    }
    memset(jobs, 0, sizeof jobs);
    for (i = 0; i < N_STEPPERS + N_MISSING; ++i) {
        jobs[i].path = deck;
        jobs[i].missing_path = "missing_deck_for_thread_test.dat";
        jobs[i].n_step = N_STEP;
        tasks[i].fn = i < N_STEPPERS ? step_worker : missing_worker;
        tasks[i].arg = &jobs[i];
    }
    if (run_tasks(N_STEPPERS + N_MISSING, tasks) != 0) {
        fprintf(stderr, "FAIL could not start stepping threads\n");
        return 1;
    }
    for (i = 0; i < N_STEPPERS + N_MISSING; ++i) {
        if (jobs[i].failed) {
            fprintf(stderr, "  thread %d failed: %s\n", i, jobs[i].msg);
            ++failed;
            continue;
        }
        if (i >= N_STEPPERS) continue;
        if (jobs[i].ndof != ndof) {
            fprintf(stderr, "  thread %d: %d coupled DOFs, reference %d\n", i, jobs[i].ndof, ndof);
            ++failed;
            continue;
        }
        for (j = 0; j < ndof; ++j) {
            if (fabs(jobs[i].loads[j] - reference[j]) > 1.0e-9 * (1.0 + fabs(reference[j]))) {
                fprintf(stderr, "  thread %d: load %d = %.17g, reference %.17g\n", i, j, jobs[i].loads[j],
                        reference[j]);
                ++failed;
                break;
            }
        }
        if (j == ndof && fabs(jobs[i].lines - reference_lines) > 1.0e-9 * (1.0 + fabs(reference_lines))) {
            fprintf(stderr, "  thread %d: line values %.17g, reference %.17g\n", i, jobs[i].lines, reference_lines);
            ++failed;
        }
    }
    printf("concurrent steps: %d threads x %d steps on distinct handles, %d missing-deck threads: failed=%d\n",
           N_STEPPERS, N_STEP, N_MISSING, failed);
    if (failed != 0) {
        fprintf(stderr, "FAIL concurrent Step on distinct handles\n");
        return 1;
    }
    return 0;
}

/* Steps every deck on MAX_THREADS / n_decks threads at once, all decks concurrently, and
 * checks every final coupled load against the deck's serial reference. */
static int check_mixed_steps(int n_decks, char **decks, int n_step)
{
    enum { MAX_DECKS = 8 };
    static struct step_job jobs[MAX_THREADS];
    static double reference[MAX_DECKS][MAX_DOF];
    double reference_lines[MAX_DECKS];
    struct task tasks[MAX_THREADS];
    int ndof[MAX_DECKS];
    char msg[512] = {0};
    int d, i, j, per_deck, n, failed = 0;

    if (n_decks < 1 || n_decks > MAX_DECKS) {
        fprintf(stderr, "FAIL --mixed takes 1 to %d decks\n", MAX_DECKS);
        return 1;
    }
    for (d = 0; d < n_decks; ++d) {
        if (step_deck(decks[d], n_step, reference[d], &reference_lines[d], &ndof[d], msg, sizeof msg) != 0) {
            fprintf(stderr, "FAIL serial reference run of %s: %s\n", decks[d], msg);
            return 1;
        }
    }
    per_deck = MAX_THREADS / n_decks;
    if (per_deck > 6) per_deck = 6;
    n = per_deck * n_decks;
    memset(jobs, 0, sizeof jobs);
    for (i = 0; i < n; ++i) {
        jobs[i].path = decks[i % n_decks];
        jobs[i].n_step = n_step;
        tasks[i].fn = step_worker;
        tasks[i].arg = &jobs[i];
    }
    if (run_tasks(n, tasks) != 0) {
        fprintf(stderr, "FAIL could not start the mixed stepping threads\n");
        return 1;
    }
    for (i = 0; i < n; ++i) {
        d = i % n_decks;
        if (jobs[i].failed || jobs[i].ndof != ndof[d]) {
            fprintf(stderr, "  thread %d (%s) failed: %s\n", i, decks[d], jobs[i].msg);
            ++failed;
            continue;
        }
        for (j = 0; j < ndof[d]; ++j) {
            if (fabs(jobs[i].loads[j] - reference[d][j]) > 1.0e-9 * (1.0 + fabs(reference[d][j]))) {
                fprintf(stderr, "  thread %d (%s): load %d = %.17g, reference %.17g\n", i, decks[d], j,
                        jobs[i].loads[j], reference[d][j]);
                ++failed;
                break;
            }
        }
        if (j == ndof[d] && fabs(jobs[i].lines - reference_lines[d]) > 1.0e-9 * (1.0 + fabs(reference_lines[d]))) {
            fprintf(stderr, "  thread %d (%s): line values %.17g, reference %.17g\n", i, decks[d], jobs[i].lines,
                    reference_lines[d]);
            ++failed;
        }
    }
    printf("mixed concurrent steps: %d decks x %d threads x %d steps: failed=%d\n", n_decks, per_deck, n_step,
           failed);
    if (failed != 0) {
        fprintf(stderr, "FAIL concurrent Step of mixed decks on distinct handles\n");
        return 1;
    }
    return 0;
}

#if defined(_WIN32)
/* ------------------------------------------------------- exit stress (Win32) -- */

/* One host thread of an exit-stress child: a short model life ending in Close. */
static void exit_child_worker(void *raw)
{
    struct step_job *job = (struct step_job *)raw;
    void *h = NULL;
    int err = -1, ndof, k, n_iter = 0;
    bool converged = false, stalled = false;
    double q[MAX_DOF], v[MAX_DOF], a[MAX_DOF];

    job->failed = 1;
    CableDyn_Create(&h, &err);
    if (err != CD_C_OK) return;
    if (init_deck(h, job->path) == CD_C_OK) {
        ndof = CableDyn_NCoupledDOF(h, &err);
        if (err == CD_C_OK && ndof >= 1 && ndof <= MAX_DOF) {
            CableDyn_GetCoupledMotion(h, q, v, a, ndof, &err);
            for (k = 0; k < 10 && err == CD_C_OK; ++k) {
                CableDyn_Step(h, STEP_DT, q, v, a, ndof, &converged, &stalled, &n_iter, &err);
            }
            job->failed = err != CD_C_OK;
        }
    }
    CableDyn_Close(&h, &err);
}

/* Child process: 24 host threads each run a model and close it, are joined, and the
 * process exits at once through the normal C runtime exit path. */
static int exit_child(const char *deck)
{
    enum { N_HOSTS = 24 };
    static struct step_job jobs[N_HOSTS];
    struct task tasks[N_HOSTS];
    int i, failed = 0;

    for (i = 0; i < N_HOSTS; ++i) {
        jobs[i].path = deck;
        tasks[i].fn = exit_child_worker;
        tasks[i].arg = &jobs[i];
    }
    if (run_tasks(N_HOSTS, tasks) != 0) return 1;
    for (i = 0; i < N_HOSTS; ++i) failed += jobs[i].failed;
    return failed != 0;
}

static unsigned __stdcall drain_pipe(void *raw)
{
    char buf[512];
    DWORD n;
    while (ReadFile((HANDLE)raw, buf, (DWORD)sizeof buf, &n, NULL) && n > 0) {
    }
    return 0;
}

/* Runs n_children exit children, 8 at a time. A child counts as finished when its
 * output pipe closes, which happens only once its process has fully ended: a process
 * hung in its exit path keeps it open (and refuses TerminateProcess), so the pipe,
 * not the process handle, detects the hang. Returns 0 when every child finished and
 * exited with 0. */
static int exit_stress(const char *deck, int n_children)
{
    enum { BATCH = 8 };
    DWORD timeout_ms = (DWORD)env_seconds("CABLEDYN_THREAD_TEST_EXIT_TIMEOUT", 120) * 1000;
    char self[MAX_PATH + 1], cmd[4 * MAX_PATH + 64];
    DWORD self_len = GetModuleFileNameA(NULL, self, MAX_PATH);
    int done = 0, bad_exit = 0, i;

    if (self_len == 0 || self_len >= MAX_PATH || strlen(self) + strlen(deck) + 32 > sizeof cmd) return 1;
    /* Only each child's own pipe may be inherited, not this process's std handles. */
    SetHandleInformation(GetStdHandle(STD_INPUT_HANDLE), HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(GetStdHandle(STD_OUTPUT_HANDLE), HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(GetStdHandle(STD_ERROR_HANDLE), HANDLE_FLAG_INHERIT, 0);
    while (done < n_children) {
        HANDLE proc[BATCH], reader[BATCH];
        DWORD pid[BATCH];
        int nb = n_children - done < BATCH ? n_children - done : BATCH;

        for (i = 0; i < nb; ++i) {
            SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
            STARTUPINFOA si;
            PROCESS_INFORMATION pi;
            HANDLE rd, wr;

            if (!CreatePipe(&rd, &wr, &sa, 0)) return 1;
            SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
            memset(&si, 0, sizeof si);
            si.cb = sizeof si;
            si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdInput = NULL;
            si.hStdOutput = wr;
            si.hStdError = wr;
            snprintf(cmd, sizeof cmd, "\"%s\" --exit-child \"%s\"", self, deck);
            if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
                fprintf(stderr, "FAIL could not start an exit-stress child (error %lu)\n", GetLastError());
                return 1;
            }
            CloseHandle(wr);
            CloseHandle(pi.hThread);
            proc[i] = pi.hProcess;
            pid[i] = pi.dwProcessId;
            reader[i] = (HANDLE)_beginthreadex(NULL, 0, drain_pipe, rd, 0, NULL);
            if (reader[i] == NULL) return 1;
        }
        for (i = 0; i < nb; ++i) {
            DWORD code = 1;
            if (WaitForSingleObject(reader[i], timeout_ms) == WAIT_TIMEOUT) {
                fprintf(stderr, "FAIL exit-stress child pid %lu has not ended after %lu s (hung at process exit?)\n",
                        pid[i], timeout_ms / 1000);
                return 1;
            }
            CloseHandle(reader[i]);
            WaitForSingleObject(proc[i], INFINITE);
            if (!GetExitCodeProcess(proc[i], &code) || code != 0) {
                fprintf(stderr, "  exit-stress child pid %lu exited with %lu\n", pid[i], code);
                ++bad_exit;
            }
            CloseHandle(proc[i]);
        }
        done += nb;
    }
    printf("exit stress: %d child processes of 24 host threads each ended; failed=%d\n", n_children, bad_exit);
    return bad_exit != 0;
}
#endif

int main(int argc, char **argv)
{
    const char *locale_name;
    int expected_blas;
    long loop, loops;

#if defined(_WIN32)
    /* test_c_api_threads --exit-stress <deck.dat> <n_children>: hang-at-exit gate. */
    if (argc == 3 && strcmp(argv[1], "--exit-child") == 0) return exit_child(argv[2]);
    if (argc == 4 && strcmp(argv[1], "--exit-stress") == 0) {
        setvbuf(stdout, NULL, _IONBF, 0);
        if (watchdog_start() != 0) return 1;
        current_phase = "exit stress";
        return exit_stress(argv[2], atoi(argv[3]));
    }
#endif
    /* test_c_api_threads --mixed <n_steps> <deck> [<deck> ...]: concurrent steps of mixed decks. */
    if (argc >= 4 && strcmp(argv[1], "--mixed") == 0) {
        setvbuf(stdout, NULL, _IONBF, 0);
        if (watchdog_start() != 0) return 1;
        loops = env_seconds("CABLEDYN_THREAD_TEST_LOOPS", 1);
        if (loops < 1) loops = 1;
        for (loop = 0; loop < loops; ++loop) {
            if (loops > 1) printf("loop %ld of %ld\n", loop + 1, loops);
            current_phase = "concurrent Step (mixed decks)";
            if (check_mixed_steps(argc - 3, argv + 3, atoi(argv[2])) != 0) return 1;
        }
        printf("PASS c_api_threads --mixed\n");
        return 0;
    }
    if (argc != 4) {
        fprintf(stderr, "usage: test_c_api_threads <chain_deck.dat> <syrope_deck.dat> <expected_blas_threads>\n");
        return 2;
    }
    expected_blas = atoi(argv[3]);
    setvbuf(stdout, NULL, _IONBF, 0);
#if defined(_WIN32) && defined(CABLEDYN_BLAS_RUNTIME_LOAD)
    /* The CableDyn DLL loads openblas.dll on first use with a one-thread pool. Mapped
     * already, it was imported at load time with a pool sized from the CPU count. */
    if (GetModuleHandleW(L"openblas.dll") != NULL) {
        fprintf(stderr, "FAIL openblas.dll is loaded before the first CableDyn call\n");
        return 1;
    }
#endif
    if (watchdog_start() != 0) {
        fprintf(stderr, "FAIL could not start the watchdog thread\n");
        return 1;
    }
    loops = env_seconds("CABLEDYN_THREAD_TEST_LOOPS", 1);
    if (loops < 1) loops = 1;
    locale_name = setlocale(LC_ALL, "");
    printf("locale: %s\n", locale_name != NULL ? locale_name : "(unchanged)");

    current_phase = "BLAS policy and memory";
    if (check_blas_and_memory(argv[1], expected_blas) != 0) return 1;
    for (loop = 0; loop < loops; ++loop) {
        if (loops > 1) printf("loop %ld of %ld\n", loop + 1, loops);
        current_phase = "concurrent InitDeck (same deck)";
        if (check_concurrent_init(argv[1], 8, 10, "same deck") != 0) return 1;
        current_phase = "concurrent InitDeck (shared Syrope OWC table)";
        if (check_concurrent_init(argv[2], 8, 2, "shared Syrope OWC table") != 0) return 1;
        current_phase = "missing-deck diagnostic";
        if (check_missing_message() != 0) return 1;
        current_phase = "concurrent Step";
        if (check_concurrent_steps(argv[1]) != 0) return 1;
    }
    current_phase = "exit";
    printf("PASS c_api_threads\n");
    return 0;
}
