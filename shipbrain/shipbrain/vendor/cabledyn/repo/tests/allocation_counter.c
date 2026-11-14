/* File: tests/allocation_counter.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Heap-allocation counter for allocation-count tests. The test executable is linked with
 * GNU ld --wrap=malloc,--wrap=calloc,--wrap=realloc, which routes every allocation made by
 * the statically linked core (ALLOCATE, run-time-sized automatic arrays, and heap array
 * temporaries) through these wrappers. Counting is switched on and off by the test. */
#include <stddef.h>

void *__real_malloc(size_t n);
void *__real_calloc(size_t n, size_t size);
void *__real_realloc(void *p, size_t n);

static long long allocation_count = 0;
static int counting = 0;

void *__wrap_malloc(size_t n)
{
    if (counting) allocation_count++;
    return __real_malloc(n);
}

void *__wrap_calloc(size_t n, size_t size)
{
    if (counting) allocation_count++;
    return __real_calloc(n, size);
}

void *__wrap_realloc(void *p, size_t n)
{
    if (counting) allocation_count++;
    return __real_realloc(p, n);
}

long long cd_test_allocation_count(void) { return allocation_count; }

void cd_test_allocation_counting(int on) { counting = on; }
