/* File: tests/test_c_api_blas_missing.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Usage: test_c_api_blas_missing <deck.dat>
 *
 * Run by tests/check_blas_missing_runtime.cmake from a directory holding the CableDyn
 * DLL without openblas.dll. Prints the CableDyn_Create and CableDyn_InitDeck statuses
 * and the handle's diagnostic; the script asserts on them.
 */
#include "CableDyn_CAPI.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    void *h = NULL;
    int create_err = -1, init_err = -1, close_err = -1;
    char msg[2048] = {0};

    if (argc != 2) {
        fprintf(stderr, "usage: test_c_api_blas_missing <deck.dat>\n");
        return 2;
    }
    CableDyn_Create(&h, &create_err);
    printf("create: %d\n", create_err);
    if (create_err != CD_C_OK) return 1;
    CableDyn_InitDeck(h, argv[1], (int)strlen(argv[1]), &init_err);
    CableDyn_GetLastError(h, msg, (int)sizeof msg);
    printf("init: %d\n", init_err);
    printf("message: %s\n", msg);
    CableDyn_Close(&h, &close_err);
    return 0;
}
