/* File: tests/blas_config_probe.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * The OpenBLAS build configuration and kernel (openblas_get_config) of the runtime this test
 * process loaded, for its log: a failure that depends on the host CPU then names the kernel
 * it ran. Windows GNU builds only (openblas.dll is loaded at run time); elsewhere, or when
 * the library is not OpenBLAS, the text is empty.
 */
#include <string.h>

int cabledyn_test_blas_config(char *text, int capacity);

#if defined(_WIN32)
#include <windows.h>

typedef char *(__cdecl *config_fn)(void);

int cabledyn_test_blas_config(char *text, int capacity)
{
    HMODULE blas = GetModuleHandleA("openblas.dll");
    FARPROC proc;
    config_fn config;
    const char *value;
    size_t n;
    if (text == NULL || capacity < 1) {
        return 0;
    }
    text[0] = '\0';
    if (blas == NULL) {
        return 0;
    }
    proc = GetProcAddress(blas, "openblas_get_config");
    if (proc == NULL) {
        return 0;
    }
    /* A FARPROC converted without a function-pointer cast (as in src/cabledyn_blas.c). */
    memcpy(&config, &proc, sizeof config);
    value = config();
    if (value == NULL) {
        return 0;
    }
    n = strlen(value);
    if (n > (size_t)(capacity - 1)) {
        n = (size_t)(capacity - 1);
    }
    memcpy(text, value, n);
    text[n] = '\0';
    return (int)n;
}
#else
int cabledyn_test_blas_config(char *text, int capacity)
{
    if (text != NULL && capacity > 0) {
        text[0] = '\0';
    }
    return 0;
}
#endif
