/* File: tests/test_c_api_concurrency.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 */
#include "CableDyn_CAPI.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>
#include <sched.h>

enum { NTHREAD = 8, NITER = 500 };

struct close_arg {
    void *handle;
    atomic_int *ready;
    atomic_bool *go;
    atomic_int *closed;
    atomic_int *rejected;
};

static void *create_close_worker(void *unused)
{
    int i;
    (void)unused;
    for (i = 0; i < NITER; ++i) {
        void *handle = NULL;
        int err = -1;
        CableDyn_Create(&handle, &err);
        if (err != CD_C_OK || handle == NULL) return (void *)(intptr_t)1;
        CableDyn_Close(&handle, &err);
        if (err != CD_C_OK || handle != NULL) return (void *)(intptr_t)1;
    }
    return NULL;
}

static void *competing_close_worker(void *raw)
{
    struct close_arg *arg = (struct close_arg *)raw;
    void *copy = arg->handle;
    int err = -1;
    atomic_fetch_add_explicit(arg->ready, 1, memory_order_release);
    while (!atomic_load_explicit(arg->go, memory_order_acquire)) sched_yield();
    CableDyn_Close(&copy, &err);
    if (err == CD_C_OK) {
        atomic_fetch_add(arg->closed, 1);
    } else if (err == CD_C_BAD_HANDLE) {
        atomic_fetch_add(arg->rejected, 1);
    } else {
        return (void *)(intptr_t)1;
    }
    return NULL;
}

int main(void)
{
    pthread_t threads[NTHREAD];
    struct close_arg args[NTHREAD];
    atomic_int ready = 0, closed = 0, rejected = 0;
    atomic_bool go = false;
    void *shared = NULL;
    int i, err = -1;
    void *result;

    for (i = 0; i < NTHREAD; ++i) {
        if (pthread_create(&threads[i], NULL, create_close_worker, NULL) != 0) return 1;
    }
    for (i = 0; i < NTHREAD; ++i) {
        if (pthread_join(threads[i], &result) != 0 || result != NULL) return 1;
    }

    CableDyn_Create(&shared, &err);
    if (err != CD_C_OK || shared == NULL) return 1;
    for (i = 0; i < NTHREAD; ++i) {
        args[i] = (struct close_arg){shared, &ready, &go, &closed, &rejected};
        if (pthread_create(&threads[i], NULL, competing_close_worker, &args[i]) != 0) return 1;
    }
    while (atomic_load_explicit(&ready, memory_order_acquire) != NTHREAD) sched_yield();
    atomic_store_explicit(&go, true, memory_order_release);
    for (i = 0; i < NTHREAD; ++i) {
        if (pthread_join(threads[i], &result) != 0 || result != NULL) return 1;
    }
    if (atomic_load(&closed) != 1 || atomic_load(&rejected) != NTHREAD - 1) return 1;

    puts("PASS: CableDyn C API handle registry is thread-safe without relying on OpenMP");
    return 0;
}
