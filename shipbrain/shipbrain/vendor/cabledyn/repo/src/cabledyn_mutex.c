/* File: src/cabledyn_mutex.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Process-local locks for the CableDyn C ABI.
 *
 * - The live-handle registry lock guards the handle table. Its critical sections
 *   are a few loads and stores, so it is a C11 atomic flag that keeps registry
 *   correctness independent of the optional OpenMP runtime.
 * - The input lock serialises deck parsing and handle initialisation
 *   (CableDyn_InitDeck, CableDyn_InitLine, CableDyn_InitLines). These run file
 *   OPEN/READ/CLOSE and formatted internal I/O through the Fortran runtime, which
 *   is not safe to run concurrently: gfortran refuses to connect a file that is
 *   already connected to another unit (two threads reading the same deck, or two
 *   decks sharing a Syrope OWC table, fail to open it), and the MinGW-w64
 *   libgfortran unit table and per-statement setlocale() toggling race between
 *   threads. An initialisation can take seconds, so waiters block on an OS mutex
 *   instead of spinning.
 */
#include <stdatomic.h>

#if defined(_WIN32)
#include <windows.h>
#define CABLEDYN_YIELD() SwitchToThread()
#else
#include <pthread.h>
#include <sched.h>
#define CABLEDYN_YIELD() sched_yield()
#endif

void cabledyn_registry_lock(void);
void cabledyn_registry_unlock(void);
void cabledyn_input_lock(void);
void cabledyn_input_unlock(void);

static atomic_flag cabledyn_registry_mutex = ATOMIC_FLAG_INIT;

void cabledyn_registry_lock(void)
{
    /* Critical sections are short, but the holder can be preempted (for example
     * inside the allocator while the registry grows). Yield instead of burning a
     * core per waiting thread. */
    while (atomic_flag_test_and_set_explicit(&cabledyn_registry_mutex, memory_order_acquire)) {
        CABLEDYN_YIELD();
    }
}

void cabledyn_registry_unlock(void)
{
    atomic_flag_clear_explicit(&cabledyn_registry_mutex, memory_order_release);
}

#if defined(_WIN32)
/* A slim reader/writer lock needs no initialisation or teardown and parks waiters
 * in the kernel. It is not recursive: the input lock is never re-entered. */
static SRWLOCK cabledyn_input_mutex = SRWLOCK_INIT;

void cabledyn_input_lock(void)
{
    AcquireSRWLockExclusive(&cabledyn_input_mutex);
}

void cabledyn_input_unlock(void)
{
    ReleaseSRWLockExclusive(&cabledyn_input_mutex);
}
#else
static pthread_mutex_t cabledyn_input_mutex = PTHREAD_MUTEX_INITIALIZER;

void cabledyn_input_lock(void)
{
    (void)pthread_mutex_lock(&cabledyn_input_mutex);
}

void cabledyn_input_unlock(void)
{
    (void)pthread_mutex_unlock(&cabledyn_input_mutex);
}
#endif
