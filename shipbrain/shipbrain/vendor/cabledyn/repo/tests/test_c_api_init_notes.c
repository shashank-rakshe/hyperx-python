/* File: tests/test_c_api_init_notes.c
 * SPDX-License-Identifier: Apache-2.0
 * CableDyn_GetInitNotes through the public header and the shared library.
 *
 * The test writes a chain with a grounded run on a seabed without friction and checks:
 * - the point route, in a deck current: the seabed drift note, once, naming the line; in still
 *   water no such note;
 * - the aggregate route, the same chain with bending stiffness;
 * - a host fluid field: the deck's steady current is known at initialisation, so the note stays
 *   on the aggregate; a deck with no current of its own has none, whatever the host applies later;
 * - the buffer: a NULL buffer gives the length, a short buffer is truncated and NUL-terminated,
 *   a whole one holds exactly that length, and a bad handle gives -1 and an empty string;
 * - a failed initialisation replaces the notes, and a raw-line one has none.
 * The decks this test writes are removed on every exit path.
 */
#include "CableDyn_CAPI.h"

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

static const char DRIFT[] = "on the seabed at the static start with no seabed friction";
static const char DECK_PATH[] = "c_api_init_notes.dat";

static int write_deck(double ei, const char *options)
{
    FILE *f = fopen(DECK_PATH, "w");
    if (f == NULL) return 1;
    fprintf(f, "--- CableDyn Input File ---\n");
    fprintf(f, "a grounded chain\n--- LINE TYPES ---\n");
    fprintf(f, "Name Diam Mass EA BA EI Cdn Cdt Can Cat\n");
    fprintf(f, "chain 0.252 390.0 1.674e9 -1.0 %g 1.37 0.64 1.0 0.0\n", ei);
    fprintf(f, "--- POINTS ---\nID Type X Y Z Mass Vol CdA Ca\n");
    fprintf(f, "1 Fixed 400.0 0.0 -50.0 0 0 0 0\n2 Coupled 0.0 0.0 0.0 0 0 0 0\n");
    fprintf(f, "--- LINES ---\nID NodeA NodeB Outputs\n1 2 1 -\n");
    fprintf(f, "--- SECTIONS ---\nLineID LineType Length NumSegs\n1 chain 410.0 41\n");
    fprintf(f, "--- OPTIONS ---\n9.80665 g\n1025.0 rhoW\n50.0 WtrDpth\n0.05 dtM\n10.0 TMax\n%s\n", options);
    fprintf(f, "--- OUTPUTS ---\nFairTen1\n--- need this line ---\n");
    return fclose(f) != 0;
}

/* How many times the drift note appears in the notes of h, or -1 when they cannot be read. */
static int drift_notes(void *h)
{
    int count = 0;
    const int size = CableDyn_GetInitNotes(h, NULL, 0);
    char *text;
    const char *at;
    if (size < 0) return -1;
    text = (char *)malloc((size_t)size + 1);
    if (text == NULL) return -1;
    if (CableDyn_GetInitNotes(h, text, size + 1) != size || (int)strlen(text) != size) {
        free(text);
        return -1;
    }
    for (at = strstr(text, DRIFT); at != NULL; at = strstr(at + 1, DRIFT)) ++count;
    if (count > 0 && strstr(text, "line 1 lies") == NULL) count = -1;
    free(text);
    return count;
}

/* Initialise a new handle from the deck and count its drift notes. */
static int notes_of_deck(double ei, const char *options, int host_fluid)
{
    void *h = NULL;
    int err = -1, count;
    if (write_deck(ei, options) != 0) return -1;
    CableDyn_Create(&h, &err);
    if (err != CD_C_OK) return -1;
    if (host_fluid) CableDyn_SetHostFluid(h, 1, &err);
    CableDyn_InitDeck(h, DECK_PATH, (int)strlen(DECK_PATH), &err);
    count = err == CD_C_OK ? drift_notes(h) : -1;
    CableDyn_Close(&h, &err);
    return count;
}

static int run_routes(void)
{
    const char *current = "uniform 0.5 0 0 current";
    CHECK(notes_of_deck(0.0, current, 0) == 1, "point route: one drift note in the deck current");
    CHECK(notes_of_deck(0.0, "", 0) == 0, "point route: no drift note in still water");
    CHECK(notes_of_deck(0.0, "uniform 0.5 0 0 current\n0.5 frictionMu", 0) == 0,
          "point route: no drift note with friction");
    CHECK(notes_of_deck(1.0e6, current, 0) == 1, "aggregate route: one drift note in the deck current");
    CHECK(notes_of_deck(1.0e6, "", 0) == 0, "aggregate route: no drift note in still water");
    CHECK(notes_of_deck(0.0, current, 1) == 1, "host field, EI = 0: the deck's steady current is known");
    CHECK(notes_of_deck(1.0e6, current, 1) == 1, "host field, finite EI: the deck's steady current is known");
    CHECK(notes_of_deck(0.0, "", 1) == 0, "host field: a current applied later is not known at initialisation");
    return 0;
}

static int run_buffer(void)
{
    void *h = NULL;
    int err = -1, size;
    char small[9], *whole;

    CHECK(write_deck(0.0, "uniform 0.5 0 0 current") == 0, "write the deck");
    CableDyn_Create(&h, &err);
    CHECK(err == CD_C_OK, "create");
    CHECK(CableDyn_GetInitNotes(h, NULL, 0) == 0, "no notes before an initialisation");
    CableDyn_InitDeck(h, DECK_PATH, (int)strlen(DECK_PATH), &err);
    CHECK(err == CD_C_OK, "initialise");
    size = CableDyn_GetInitNotes(h, NULL, 0);
    CHECK(size > (int)sizeof small, "a NULL buffer gives the length");
    memset(small, 'x', sizeof small);
    CHECK(CableDyn_GetInitNotes(h, small, (int)sizeof small) == size, "a short buffer still gives the length");
    CHECK(strlen(small) == sizeof small - 1, "a short buffer is truncated and NUL-terminated");
    whole = (char *)malloc((size_t)size + 1);
    CHECK(whole != NULL, "allocate");
    CHECK(CableDyn_GetInitNotes(h, whole, size + 1) == size && (int)strlen(whole) == size, "a whole buffer");
    CHECK(whole[size - 1] == '\n', "every note ends with a new line");
    CHECK(strncmp(whole, small, sizeof small - 1) == 0, "truncation keeps the start");
    free(whole);

    {
        /* a failed initialisation replaces the notes */
        static const char missing[] = "c_api_init_notes_missing.dat";
        CableDyn_InitDeck(h, missing, (int)strlen(missing), &err);
        CHECK(err != CD_C_OK, "a missing deck fails");
        CHECK(CableDyn_GetInitNotes(h, NULL, 0) == 0, "a failed initialisation replaces the notes");
    }
    {
        /* a raw-line initialisation has no notes */
        const double q0[6] = {0.0, 0.0, 0.0, 10.0, 0.0, 0.0}, v0[6] = {0.0};
        const double l0[1] = {10.0}, ea[1] = {1.0e6}, rho_a[1] = {10.0};
        const int elem_conn[2] = {1, 2}, fixed[6] = {1, 2, 3, 4, 5, 6};
        CableDyn_InitDeck(h, DECK_PATH, (int)strlen(DECK_PATH), &err);
        CHECK(err == CD_C_OK && CableDyn_GetInitNotes(h, NULL, 0) == size, "the deck again gives its notes");
        CableDyn_InitLine(h, 2, 1, q0, v0, elem_conn, l0, ea, rho_a, fixed, 6, 1, 0.8, &err);
        CHECK(err == CD_C_OK, "raw line");
        CHECK(CableDyn_GetInitNotes(h, NULL, 0) == 0, "a raw-line initialisation has no notes");
    }
    CableDyn_Close(&h, &err);

    /* a bad handle: the closed handle is NULL here */
    small[0] = 'x';
    CHECK(CableDyn_GetInitNotes(h, small, (int)sizeof small) == -1, "a bad handle gives -1");
    CHECK(small[0] == '\0', "and an empty string");
    CHECK(CableDyn_GetInitNotes(h, NULL, 0) == -1, "with or without a buffer");
    return 0;
}

int main(void)
{
    int failed;
    CHECK(CableDyn_GetAbiMinor() >= 4, "ABI minor 4");
    failed = run_routes();
    if (failed == 0) failed = run_buffer();
    remove(DECK_PATH);
    if (failed == 0) printf("c_api_init_notes: OK\n");
    return failed;
}
