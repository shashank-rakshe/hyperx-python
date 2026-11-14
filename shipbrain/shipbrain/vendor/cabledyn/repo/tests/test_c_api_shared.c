/* File: tests/test_c_api_shared.c
 * SPDX-License-Identifier: Apache-2.0
 * Public-header/shared-library production ABI gate.
 *
 * Usage: test_c_api_shared <deck.dat> <wave_deck.dat>
 * Exercises the exported C ABI through the installed-style header: version
 * identity, handle lifecycle, diagnostics buffer contract, deck
 * initialization, one coupled step, atomic re-initialization, and
 * fail-closed rejection of invalid raw-line and wave-deck input.
 */
#include "CableDyn_CAPI.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition, message)                        \
    do {                                                 \
        if (!(condition)) {                              \
            fprintf(stderr, "FAIL: %s\n", (message));    \
            return 1;                                    \
        }                                                \
    } while (0)

static int check_version(void)
{
    int major = -1, minor = -1, patch = -1, abi = -1;
    char version[64];

    CableDyn_GetVersion(&major, &minor, &patch, &abi);
    CHECK(major == CABLEDYN_CAPI_VERSION_MAJOR && minor == CABLEDYN_CAPI_VERSION_MINOR &&
              patch == CABLEDYN_CAPI_VERSION_PATCH && abi == CABLEDYN_CAPI_ABI_VERSION,
          "C header/library version mismatch");

    memset(version, 'x', sizeof version);
    CableDyn_GetVersionString(version, (int)sizeof version);
    CHECK(memchr(version, '\0', sizeof version) != NULL, "version string is not NUL-terminated");
    {
        /* the expected text follows the header macros, so a release bump needs no test edit */
        char expected[64], abi_text[32];
        snprintf(expected, sizeof expected, "CableDyn %d.%d.%d", CABLEDYN_CAPI_VERSION_MAJOR,
                 CABLEDYN_CAPI_VERSION_MINOR, CABLEDYN_CAPI_VERSION_PATCH);
        snprintf(abi_text, sizeof abi_text, "C-ABI %d", CABLEDYN_CAPI_ABI_VERSION);
        CHECK(strstr(version, expected) != NULL && strstr(version, abi_text) != NULL,
              "version string is invalid");
    }
    return 0;
}

static int check_diagnostics_buffer(void)
{
    int bogus = 0;
    char message[128];
    char tiny[4];

    /* A foreign pointer is reported, never dereferenced. */
    memset(message, 'x', sizeof message);
    CableDyn_GetLastError(&bogus, message, (int)sizeof message);
    CHECK(strstr(message, "bad handle") != NULL, "foreign handle diagnostic missing");

    memset(tiny, 'x', sizeof tiny);
    CableDyn_GetLastError(&bogus, tiny, (int)sizeof tiny);
    CHECK(tiny[3] == '\0' && strlen(tiny) == 3, "diagnostic truncation contract failed");
    return 0;
}

static int check_lifecycle(void)
{
    void *handle = NULL;
    void *copy = NULL;
    int err = -1;
    int bogus = 0;
    void *foreign = &bogus;

    CableDyn_Create(&handle, &err);
    CHECK(err == CD_C_OK && handle != NULL && !CableDyn_IsInitialized(handle),
          "create contract failed");
    copy = handle;
    CableDyn_Close(&handle, &err);
    CHECK(err == CD_C_OK && handle == NULL, "close contract failed");
    CableDyn_Close(&copy, &err);
    CHECK(err == CD_C_BAD_HANDLE && copy != NULL, "double close was not rejected");
    CableDyn_Close(&foreign, &err);
    CHECK(err == CD_C_BAD_HANDLE, "foreign close was not rejected");
    handle = NULL;
    CableDyn_Close(&handle, &err);
    CHECK(err == CD_C_OK, "closing NULL must be a no-op");
    return 0;
}

static int check_deck_step(const char *deck)
{
    void *m = NULL;
    int err = -1, ndof, n_iter = 0, i, status = 1;
    bool converged = false, stalled = true;
    double *q = NULL, *v = NULL, *a = NULL, *loads = NULL;
    const char *missing = "no_such_deck_anywhere.dat";

    CableDyn_Create(&m, &err);
    CHECK(err == CD_C_OK, "create failed");
    CableDyn_InitDeck(m, deck, (int)strlen(deck), &err);
    if (err != CD_C_OK) {
        char message[1025];
        CableDyn_GetLastError(m, message, (int)sizeof message);
        fprintf(stderr, "FAIL: deck initialization: %s\n", message);
        CableDyn_Close(&m, &err);
        return 1;
    }
    ndof = CableDyn_NCoupledDOF(m, &err);
    if (err != CD_C_OK || ndof <= 0) {
        fputs("FAIL: coupled DOF query\n", stderr);
        goto done;
    }
    q = calloc((size_t)ndof, sizeof *q);
    v = calloc((size_t)ndof, sizeof *v);
    a = calloc((size_t)ndof, sizeof *a);
    loads = calloc((size_t)ndof, sizeof *loads);
    if (!q || !v || !a || !loads) {
        fputs("FAIL: allocation\n", stderr);
        goto done;
    }
    CableDyn_GetCoupledMotion(m, q, v, a, ndof, &err);
    if (err != CD_C_OK) {
        fputs("FAIL: coupled motion query\n", stderr);
        goto done;
    }
    CableDyn_Step(m, 0.1, q, v, a, ndof, &converged, &stalled, &n_iter, &err);
    if (err != CD_C_OK || !converged || stalled) {
        fputs("FAIL: held-platform step did not converge\n", stderr);
        goto done;
    }
    CableDyn_CalcOutput(m, loads, ndof, &err);
    if (err != CD_C_OK) {
        fputs("FAIL: output\n", stderr);
        goto done;
    }
    for (i = 0; i < ndof; ++i) {
        if (!isfinite(loads[i])) {
            fputs("FAIL: non-finite coupled load\n", stderr);
            goto done;
        }
    }

    /* ABI 1 minor extension 1: object queries through the public header. */
    {
        int nl, np, id = 0, nn = 0, sub = -1;
        double *xyz = NULL, *seg = NULL, pos[3], force[3], fair = 0.0, ten0 = 0.0;
        const char *token = "FairTen1";

        CHECK(CableDyn_GetAbiMinor() >= 1 && CableDyn_GetAbiMinor() == CABLEDYN_CAPI_ABI_MINOR,
              "ABI minor level");
        nl = CableDyn_NObjects(m, CD_C_OBJ_LINE, &err);
        CHECK(err == CD_C_OK && nl == CableDyn_NLines(m, &err), "line inventory");
        np = CableDyn_NObjects(m, CD_C_OBJ_POINT, &err);
        CHECK(err == CD_C_OK && np == CableDyn_NPoints(m, &err), "point inventory");
        CHECK(CableDyn_NObjects(m, CD_C_OBJ_BODY, &err) == 0 && err == CD_C_OK, "body inventory");
        CableDyn_GetObjectInfo(m, CD_C_OBJ_LINE, 0, &id, &nn, &sub, &err);
        CHECK(err == CD_C_OK && id == 1 && nn > 1 && sub == 0, "line info");
        CableDyn_GetObjectInfo(m, CD_C_OBJ_LINE, nl, &id, &nn, &sub, &err);
        CHECK(err == CD_C_BAD_INPUT, "out-of-range line index accepted");
        CableDyn_GetObjectInfo(m, CD_C_OBJ_LINE, 0, &id, &nn, &sub, &err);
        xyz = calloc((size_t)(3 * nn), sizeof *xyz);
        seg = calloc((size_t)(nn - 1), sizeof *seg);
        CHECK(xyz && seg, "allocation");
        CableDyn_GetLineValues(m, 0, CD_C_LINE_POSITION, xyz, 3 * nn, &err);
        CHECK(err == CD_C_OK && isfinite(xyz[3 * nn - 1]), "line positions");
        CableDyn_GetLineValues(m, 0, CD_C_LINE_POSITION, xyz, nn, &err);
        CHECK(err == CD_C_BAD_INPUT, "mis-sized line buffer accepted");
        CableDyn_GetLineValues(m, 0, CD_C_LINE_SEGMENT_TENSION, seg, nn - 1, &err);
        CHECK(err == CD_C_OK && seg[0] > 0.0, "segment tensions");
        /* an EI = 0 line is meshed as the deck: mesh node k is deck node k */
        CableDyn_GetLineValues(m, 0, CD_C_LINE_DECK_NODE, xyz, nn, &err);
        CHECK(err == CD_C_OK && xyz[0] == 1.0 && xyz[nn - 1] == (double)nn, "deck nodes of a line");
        CableDyn_GetLineValues(m, 0, CD_C_LINE_TENSION, xyz, nn, &err);
        ten0 = xyz[0];
        CableDyn_EvalChannel(m, token, (int)strlen(token), &fair, &err);
        CHECK(err == CD_C_OK && fair == ten0, "FairTen1 differs from the End A node tension");
        CableDyn_EvalChannel(m, "L1Nfoo", 6, &fair, &err);
        CHECK(err == CD_C_BAD_INPUT, "malformed channel token accepted");
        CableDyn_GetPointState(m, 0, pos, NULL, force, &err);
        CHECK(err == CD_C_OK && isfinite(pos[2]) && isfinite(force[2]), "point state");
        free(xyz);
        free(seg);
    }

    /* A failed re-initialization keeps the existing model. */
    CableDyn_InitDeck(m, missing, (int)strlen(missing), &err);
    if (err == CD_C_OK || !CableDyn_IsInitialized(m) || CableDyn_NCoupledDOF(m, &err) != ndof) {
        fputs("FAIL: failed re-initialization replaced the model\n", stderr);
        goto done;
    }
    status = 0;

done:
    free(q);
    free(v);
    free(a);
    free(loads);
    CableDyn_Close(&m, &err);
    return status;
}

static int check_rejections(const char *wave_deck)
{
    void *m = NULL;
    int err = -1;
    /* Two nodes, one element, both ends fixed; only rho_inf is invalid. */
    const double q0[6] = {0.0, 0.0, 0.0, 10.0, 0.0, 0.0};
    const double v0[6] = {0.0};
    const int elem_conn[2] = {1, 2};
    const double l0[1] = {10.0}, ea[1] = {1.0e6}, rho_a[1] = {10.0};
    const int fixed[6] = {1, 2, 3, 4, 5, 6};

    CableDyn_Create(&m, &err);
    CHECK(err == CD_C_OK, "create failed");
    CableDyn_InitLine(m, 2, 1, q0, v0, elem_conn, l0, ea, rho_a, fixed, 6, 1, 2.0, &err);
    CHECK(err == CD_C_BAD_INPUT && !CableDyn_IsInitialized(m), "rho_inf outside [0, 1] was accepted");

    /* Deck waves cannot be evaluated without a simulation clock and must be rejected. */
    CableDyn_InitDeck(m, wave_deck, (int)strlen(wave_deck), &err);
    CHECK(err == CD_C_BAD_INPUT && !CableDyn_IsInitialized(m), "a deck with waves was accepted");
    CableDyn_Close(&m, &err);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fputs("usage: test_c_api_shared <deck.dat> <wave_deck.dat>\n", stderr);
        return 2;
    }
    if (check_version() || check_diagnostics_buffer() || check_lifecycle() ||
        check_deck_step(argv[1]) || check_rejections(argv[2])) {
        return 1;
    }
    puts("PASS: CableDyn public C header and shared ABI product");
    return 0;
}
