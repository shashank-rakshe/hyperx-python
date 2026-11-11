/* File: tests/crt_locale_guard_heap.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Helper for tests/test_crt_locale_guard.f90: return free process-heap pages to the
 * system so that a read of freed heap memory faults instead of passing silently.
 */
void cabledyn_test_release_free_heap(void);

#if defined(_WIN32)
#include <windows.h>

void cabledyn_test_release_free_heap(void)
{
    (void)HeapCompact(GetProcessHeap(), 0);
}

#else

void cabledyn_test_release_free_heap(void)
{
}

#endif
