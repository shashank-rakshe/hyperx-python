/* File: tests/test_c_api_host_coupling.c
 * SPDX-License-Identifier: Apache-2.0
 * Host-coupling gate of C ABI 1 minor extension 2, through the public header
 * and the shared library.
 *
 * Usage: test_c_api_host_coupling <box_points.dat> <mixed_chain_cable.dat>
 *                                 <viscoelastic.dat> <syrope.dat> <free_point.dat>
 *
 * box_points.dat is the foamMooring EsfLOWC box (four slack EI=0 lines, point
 * route) whose fairleads sit at z = -0.062 m in the deck while the CFD box
 * starts with them at z = -0.077 m. mixed_chain_cable.dat is an EI=0 chain
 * plus a finite-EI cable (aggregate route, staged steps). viscoelastic.dat is a
 * grounded viscoelastic (ElasticMod 2) catenary, run with seabed friction
 * switched on in a copy; syrope.dat is a taut Syrope line; free_point.dat is a
 * chain with a Free clump weight. The test checks:
 * - CableDyn_InitDeckAt solves the statics at the host positions: on both
 *   routes the result equals CableDyn_InitDeck of the deck moved there bit for
 *   bit; for the box, line 4's fairlead load is the standalone value and held
 *   fairleads stay at rest, while InitDeck at the deck positions followed by
 *   steps at the host positions rings; the full-vector form ignores the Fixed
 *   and Free blocks;
 * - CableDyn_SaveState/RestoreState: a restore followed by steps reproduces a
 *   fresh model taking the same steps bit for bit, on both routes, on a raw-array
 *   (InitLine) handle, with viscoelastic, Syrope and seabed-friction states, and
 *   with point fluid fields changed between the save and the restore; also
 *   after several steps between save and restore and after repeated restores;
 * - the save slot follows the live model: a failed InitDeck/InitDeckAt keeps
 *   it, a failed InitLine/InitLines drops it on a point-route handle and keeps
 *   it on an aggregate handle, and a successful initialization drops it;
 * - CableDyn_GetCoupledLayout reports anchors and fairleads on the point route
 *   and only the Coupled points on the aggregate route;
 * - the fail-closed rejections of the new calls, including a point shared by an
 *   EI=0 and a finite-EI line given two positions and a line End A moved below
 *   its Fixed anchor.
 * The decks this test writes are removed on every exit path.
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

/* CHECK for functions that release resources at their label done. */
#define REQUIRE(condition, message)                      \
    do {                                                 \
        if (!(condition)) {                              \
            fprintf(stderr, "FAIL: %s\n", (message));    \
            goto done;                                   \
        }                                                \
    } while (0)

#define BOX_NDOF 24  /* 8 line-bound points: 4 Fixed anchors, 4 Coupled fairleads */
#define BOX_NHOST 12 /* the 4 Coupled fairleads */
#define BOX_DT 1.0e-3
#define BOX_NSTEP 1000 /* 1 s */
#define DECK_Z (-0.062)
#define HOST_Z (-0.077)

#define MIX_NDOF 6 /* the chain and the cable fairleads; the anchors are not coupled */
#define MIX_DT 0.01

#define RAW_NODES 6
#define RAW_ELEM 5

static const char *g_box;
static const char *g_mixed;
static const char *g_visco;
static const char *g_syrope;
static const char *g_free;

/* Every deck the test writes (into the working directory); removed on every exit path. */
#define BOX_MOVED "capi_host_box_moved.dat"
#define MIXED_HALF "capi_host_mixed_half.dat"
#define MIXED_MOVED "capi_host_mixed_moved.dat"
#define MIXED_SHARED_HALF "capi_host_mixed_shared_half.dat"
#define MIXED_SHARED "capi_host_mixed_shared.dat"
#define VISCO_FRICTION "capi_host_visco_friction.dat"
static const char *const g_written[] = {BOX_MOVED,         MIXED_HALF,   MIXED_MOVED,
                                        MIXED_SHARED_HALF, MIXED_SHARED, VISCO_FRICTION};

static void remove_written_decks(void)
{
    for (size_t i = 0; i < sizeof g_written / sizeof g_written[0]; ++i) remove(g_written[i]);
}

static void report(void *h, const char *where, int err)
{
    char msg[1025];
    CableDyn_GetLastError(h, msg, (int)sizeof msg);
    fprintf(stderr, "FAIL: %s (status %d): %s\n", where, err, msg);
}

static int init_deck(void **h, const char *deck)
{
    int err = -1;
    CableDyn_Create(h, &err);
    CHECK(err == CD_C_OK, "create");
    CableDyn_InitDeck(*h, deck, (int)strlen(deck), &err);
    if (err != CD_C_OK) {
        report(*h, "InitDeck", err);
        return 1;
    }
    return 0;
}

static int init_deck_at(void **h, const char *deck, const double *q0, int n_q0)
{
    int err = -1;
    CableDyn_Create(h, &err);
    CHECK(err == CD_C_OK, "create");
    CableDyn_InitDeckAt(*h, deck, (int)strlen(deck), q0, n_q0, &err);
    if (err != CD_C_OK) {
        report(*h, "InitDeckAt", err);
        return 1;
    }
    return 0;
}

static int step(void *h, double dt, const double *q, const double *v, const double *a, int n)
{
    bool converged = false, stalled = true;
    int n_iter = 0, err = -1;
    CableDyn_Step(h, dt, q, v, a, n, &converged, &stalled, &n_iter, &err);
    if (err != CD_C_OK || !converged) {
        report(h, "Step", err);
        return 1;
    }
    return 0;
}

static int loads(void *h, double *f, int n)
{
    int err = -1;
    CableDyn_CalcOutput(h, f, n, &err);
    if (err != CD_C_OK) {
        report(h, "CalcOutput", err);
        return 1;
    }
    return 0;
}

static int last_error_has(void *h, const char *text)
{
    char msg[1025];
    CableDyn_GetLastError(h, msg, (int)sizeof msg);
    return strstr(msg, text) != NULL;
}

/* The box fairlead positions (deck x, y) at height z, as the 4 Coupled blocks. */
static void box_fairleads(double z, double *q_host)
{
    static const double xy[4][2] = {{-0.1, 0.1}, {-0.1, -0.1}, {0.1, 0.1}, {0.1, -0.1}};
    for (int p = 0; p < 4; ++p) {
        q_host[3 * p + 0] = xy[p][0];
        q_host[3 * p + 1] = xy[p][1];
        q_host[3 * p + 2] = z;
    }
}

/* Copy a deck with one text replaced: on every line that contains old_text (and row_key, unless
 * row_key is NULL), the first old_text becomes new_text; n_expected such lines must be found. */
static int edit_deck(const char *in_path, const char *out_path, const char *old_text, const char *new_text,
                     const char *row_key, int n_expected)
{
    FILE *in = fopen(in_path, "r"), *out = NULL;
    char line[512], edited[1024];
    int n = 0;

    if (in == NULL) {
        fprintf(stderr, "FAIL: open the deck %s\n", in_path);
        return 1;
    }
    out = fopen(out_path, "w");
    if (out == NULL) {
        fclose(in);
        fprintf(stderr, "FAIL: write the deck %s\n", out_path);
        return 1;
    }
    while (fgets(line, (int)sizeof line, in) != NULL) {
        char *at = strstr(line, old_text);
        if (at != NULL && (row_key == NULL || strstr(line, row_key) != NULL)) {
            snprintf(edited, sizeof edited, "%.*s%s%s", (int)(at - line), line, new_text, at + strlen(old_text));
            fputs(edited, out);
            ++n;
        } else {
            fputs(line, out);
        }
    }
    fclose(in);
    fclose(out);
    if (n != n_expected) {
        fprintf(stderr, "FAIL: %s: %d lines with \"%s\", expected %d\n", in_path, n, old_text, n_expected);
        return 1;
    }
    return 0;
}

static int check_version(void)
{
    CHECK(CABLEDYN_CAPI_ABI_MINOR >= 2 && CableDyn_GetAbiMinor() == CABLEDYN_CAPI_ABI_MINOR,
          "ABI minor level 2 or later");
    return 0;
}

static int check_point_layout(void)
{
    void *h = NULL;
    int err = -1, ids[8], types[8], n;
    if (init_deck(&h, g_box)) return 1;
    n = CableDyn_NCoupledDOF(h, &err);
    CHECK(err == CD_C_OK && n == BOX_NDOF, "the box coupled vector has 8 blocks");
    CableDyn_GetCoupledLayout(h, ids, types, n / 3, &err);
    CHECK(err == CD_C_OK, "layout query");
    for (int k = 0; k < 8; ++k) {
        CHECK(ids[k] == k + 1, "point-route blocks follow the POINTS table");
        CHECK(types[k] == (k < 4 ? CD_C_POINT_FIXED : CD_C_POINT_COUPLED),
              "point-route blocks: 4 Fixed anchors, then 4 Coupled fairleads");
    }
    CableDyn_GetCoupledLayout(h, NULL, types, n / 3, &err);
    CHECK(err == CD_C_OK && types[7] == CD_C_POINT_COUPLED, "a NULL output is skipped");
    CableDyn_GetCoupledLayout(h, ids, types, n / 3 - 1, &err);
    CHECK(err == CD_C_BAD_INPUT, "a wrong block count is rejected");
    CableDyn_Close(&h, &err);
    return 0;
}

/* A taut raw-array line: RAW_NODES nodes 2 m apart on the x axis, 1 % pretension, both end
 * nodes fixed (the coupled vector: node 1, then node RAW_NODES). */
static void init_raw_line(void *h, double l0_each, double rho_inf, int *err)
{
    double q0[3 * RAW_NODES] = {0.0}, v0[3 * RAW_NODES] = {0.0}, l0[RAW_ELEM], ea[RAW_ELEM], rho_a[RAW_ELEM];
    int elem_conn[2 * RAW_ELEM];
    const int fixed[6] = {1, 2, 3, 3 * RAW_NODES - 2, 3 * RAW_NODES - 1, 3 * RAW_NODES};
    for (int i = 0; i < RAW_NODES; ++i) q0[3 * i] = 2.0 * i;
    for (int e = 0; e < RAW_ELEM; ++e) {
        elem_conn[2 * e] = e + 1;
        elem_conn[2 * e + 1] = e + 2;
        l0[e] = l0_each;
        ea[e] = 1.0e6;
        rho_a[e] = 10.0;
    }
    CableDyn_InitLine(h, RAW_NODES, RAW_ELEM, q0, v0, elem_conn, l0, ea, rho_a, fixed, 6, 1, rho_inf, err);
}

/* CableDyn_InitLines rejected before it reads any array (no line). */
static void init_no_lines(void *h, int *err)
{
    const int counts[1] = {0};
    CableDyn_InitLines(h, 0, counts, counts, counts, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0, 1, 0.8,
                       err);
}

static int check_raw_layout(void)
{
    void *h = NULL;
    int err = -1, ids[2], types[2], bogus = 0;
    const double q0[6] = {0.0, 0.0, 0.0, 10.0, 0.0, 0.0}, v0[6] = {0.0};
    const int elem_conn[2] = {1, 2}, fixed[6] = {1, 2, 3, 4, 5, 6};
    const double l0[1] = {10.0}, ea[1] = {1.0e6}, rho_a[1] = {10.0};

    CableDyn_Create(&h, &err);
    CableDyn_GetCoupledLayout(h, ids, types, 2, &err);
    CHECK(err == CD_C_NOT_INITIALIZED, "layout of an uninitialized handle");
    CableDyn_SaveState(h, &err);
    CHECK(err == CD_C_NOT_INITIALIZED, "save on an uninitialized handle");
    CableDyn_RestoreState(h, &err);
    CHECK(err == CD_C_NOT_INITIALIZED, "restore on an uninitialized handle");
    CableDyn_InitLine(h, 2, 1, q0, v0, elem_conn, l0, ea, rho_a, fixed, 6, 1, 0.8, &err);
    CHECK(err == CD_C_OK, "raw line init");
    CableDyn_GetCoupledLayout(h, ids, types, 2, &err);
    CHECK(err == CD_C_BAD_INPUT && last_error_has(h, "raw arrays"), "a raw-array handle has no layout");
    CableDyn_GetCoupledLayout((void *)&bogus, ids, types, 2, &err);
    CHECK(err == CD_C_BAD_HANDLE, "foreign handle");
    CableDyn_Close(&h, &err);
    return 0;
}

/* The raw line's far end swinging sideways: amplitude amp, sample time t. */
static void raw_motion(const double *q0, double amp, double t, double *q, double *v, double *a)
{
    const double w = 2.0 * acos(-1.0);
    memcpy(q, q0, 6 * sizeof *q);
    memset(v, 0, 6 * sizeof *v);
    memset(a, 0, 6 * sizeof *a);
    q[4] += amp * sin(w * t);
    v[4] = amp * w * cos(w * t);
    a[4] = -amp * w * w * sin(w * t);
}

/* Save/restore on a raw-array (InitLine) handle: two trial correctors, restore, steps; bit for
 * bit a fresh line taking the same steps. A successful InitLine drops the save. */
static int check_raw_save_restore(void)
{
    void *h = NULL, *ref = NULL;
    double q0[6], q[6], v[6], a[6], f[6], f_ref[6], mq[6], mv[6], ma[6], rq[6], rv[6], ra[6];
    int err = -1, status = 1, n;
    const double dt = 1.0e-3;

    CableDyn_Create(&h, &err);
    REQUIRE(err == CD_C_OK, "create");
    CableDyn_Create(&ref, &err);
    REQUIRE(err == CD_C_OK, "create");
    init_raw_line(h, 1.98, 0.8, &err);
    REQUIRE(err == CD_C_OK, "raw line init");
    init_raw_line(ref, 1.98, 0.8, &err);
    REQUIRE(err == CD_C_OK, "raw line init");
    n = CableDyn_NCoupledDOF(h, &err);
    REQUIRE(err == CD_C_OK && n == 6, "the raw coupled vector is the fixed-DOF list");
    CableDyn_GetCoupledMotion(h, q0, v, a, n, &err);
    REQUIRE(err == CD_C_OK, "raw coupled motion");
    CableDyn_SaveState(h, &err);
    REQUIRE(err == CD_C_OK, "raw save");
    for (int corrector = 1; corrector <= 2; ++corrector) {
        for (int s = 1; s <= 6; ++s) {
            raw_motion(q0, 0.1 * corrector, s * dt, q, v, a);
            if (step(h, dt, q, v, a, n)) goto done;
        }
        CableDyn_RestoreState(h, &err);
        REQUIRE(err == CD_C_OK, "raw restore");
    }
    for (int s = 1; s <= 20; ++s) {
        raw_motion(q0, 0.05, s * dt, q, v, a);
        if (step(h, dt, q, v, a, n) || step(ref, dt, q, v, a, n)) goto done;
        if (loads(h, f, n) || loads(ref, f_ref, n)) goto done;
        CableDyn_GetCoupledMotion(h, mq, mv, ma, n, &err);
        CableDyn_GetCoupledMotion(ref, rq, rv, ra, n, &err);
        REQUIRE(memcmp(f, f_ref, sizeof f) == 0 && memcmp(mq, rq, sizeof mq) == 0 &&
                    memcmp(mv, rv, sizeof mv) == 0 && memcmp(ma, ra, sizeof ma) == 0,
                "raw-array route: restore + steps equal the fresh line bit for bit");
    }
    REQUIRE(fabs(f[4]) > 1.0e-3, "the swinging end loads the raw line sideways");
    printf("raw-array route: 6 trial steps x 2 correctors, restore, 20 steps: bit-identical to the fresh "
           "line\n");
    init_raw_line(h, 1.98, 0.8, &err);
    REQUIRE(err == CD_C_OK, "raw line re-initialization");
    CableDyn_RestoreState(h, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a successful InitLine drops the save");
    status = 0;

done:
    CableDyn_Close(&h, &err);
    CableDyn_Close(&ref, &err);
    return status;
}

/* The save follows the live model: a failed InitLine/InitLines drops it on a point-route handle
 * (whose point model those calls rebuild in place) and keeps it on an aggregate handle, whose
 * model stays live; the aggregate then goes on bit for bit from the restored state. */
static int check_save_after_failed_raw_init(void)
{
    void *h = NULL, *ref = NULL;
    double q0[MIX_NDOF], q[MIX_NDOF], v[MIX_NDOF] = {0.0}, a[MIX_NDOF] = {0.0}, f[MIX_NDOF], f_ref[MIX_NDOF];
    int err = -1, status = 1;

    /* point route */
    if (init_deck(&h, g_box)) goto done;
    CableDyn_SaveState(h, &err);
    REQUIRE(err == CD_C_OK, "point-route save");
    init_raw_line(h, 1.98, 2.0, &err); /* rho_inf out of range */
    REQUIRE(err == CD_C_BAD_INPUT, "a failed InitLine");
    CableDyn_RestoreState(h, &err);
    REQUIRE(err == CD_C_BAD_INPUT && last_error_has(h, "no state has been saved"),
            "a failed InitLine drops the save of a point-route handle");
    CableDyn_SaveState(h, &err);
    REQUIRE(err == CD_C_OK, "point-route save");
    init_no_lines(h, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a failed InitLines");
    CableDyn_RestoreState(h, &err);
    REQUIRE(err == CD_C_BAD_INPUT && last_error_has(h, "no state has been saved"),
            "a failed InitLines drops the save of a point-route handle");
    CableDyn_Close(&h, &err);

    /* aggregate route */
    if (init_deck(&h, g_mixed) || init_deck(&ref, g_mixed)) goto done;
    CableDyn_GetCoupledMotion(h, q0, v, a, MIX_NDOF, &err);
    REQUIRE(err == CD_C_OK, "aggregate coupled motion");
    CableDyn_SaveState(h, &err);
    REQUIRE(err == CD_C_OK, "aggregate save");
    memcpy(q, q0, sizeof q);
    q[0] -= 0.3;
    q[3] += 0.3;
    if (step(h, MIX_DT, q, v, a, MIX_NDOF)) goto done;
    init_raw_line(h, 1.98, 2.0, &err); /* rejected by the argument checks */
    REQUIRE(err == CD_C_BAD_INPUT, "a failed InitLine on the aggregate handle");
    init_raw_line(h, 0.0, 0.8, &err); /* rejected by the line model */
    REQUIRE(err != CD_C_OK, "a failed InitLine (zero length) on the aggregate handle");
    init_no_lines(h, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a failed InitLines on the aggregate handle");
    REQUIRE(CableDyn_IsInitialized(h) && CableDyn_NCoupledDOF(h, &err) == MIX_NDOF,
            "the aggregate model stays live");
    CableDyn_RestoreState(h, &err);
    REQUIRE(err == CD_C_OK, "a failed InitLine/InitLines keeps the save of an aggregate handle");
    memcpy(q, q0, sizeof q);
    q[0] -= 0.05;
    if (step(h, MIX_DT, q, v, a, MIX_NDOF) || step(ref, MIX_DT, q, v, a, MIX_NDOF)) goto done;
    if (loads(h, f, MIX_NDOF) || loads(ref, f_ref, MIX_NDOF)) goto done;
    REQUIRE(memcmp(f, f_ref, sizeof f) == 0, "the restored aggregate steps as the fresh model");
    status = 0;

done:
    CableDyn_Close(&h, &err);
    CableDyn_Close(&ref, &err);
    return status;
}

static int check_init_at(void)
{
    void *at = NULL, *full = NULL, *moved = NULL, *plain = NULL;
    double q_host[BOX_NHOST], q_full[BOX_NDOF], q[BOX_NDOF], v[BOX_NDOF] = {0.0}, a[BOX_NDOF] = {0.0};
    double f_at[BOX_NDOF], f_full[BOX_NDOF], f_moved[BOX_NDOF], f[BOX_NDOF], f_plain0[BOX_NDOF];
    double drift = 0.0, ring = 0.0, ring_end = 0.0;
    int err = -1, n = BOX_NDOF, ids[8], types[8], status = 1;
    /* standalone CableDyn with the deck moved to z = -0.077 (MoorDyn: 0.3034, -0.0763, -0.4136) */
    const double f4_ref[3] = {0.3026, -0.0761, -0.4114};

    box_fairleads(HOST_Z, q_host);
    if (init_deck_at(&at, g_box, q_host, BOX_NHOST)) goto done;
    n = CableDyn_NCoupledDOF(at, &err);
    REQUIRE(err == CD_C_OK && n == BOX_NDOF, "InitDeckAt keeps the route's coupled vector");
    CableDyn_GetCoupledLayout(at, ids, types, 8, &err);
    REQUIRE(err == CD_C_OK && ids[7] == 8 && types[7] == CD_C_POINT_COUPLED, "layout after InitDeckAt");
    CableDyn_GetCoupledMotion(at, q, v, a, n, &err);
    REQUIRE(err == CD_C_OK, "coupled motion after InitDeckAt");
    for (int p = 0; p < 4; ++p) {
        REQUIRE(q[3 * p + 2] == -0.5, "the anchors stay at the deck coordinates");
        REQUIRE(memcmp(&q[12 + 3 * p], &q_host[3 * p], 3 * sizeof(double)) == 0,
                "the fairleads start exactly at q0");
    }
    for (int i = 0; i < n; ++i) REQUIRE(v[i] == 0.0 && a[i] == 0.0, "the statics start at rest");
    if (loads(at, f_at, n)) goto done;
    printf("InitDeckAt z=%.3f: line 4 fairlead load (%.4f, %.4f, %.4f) N\n", HOST_Z, f_at[21], f_at[22],
           f_at[23]);
    for (int c = 0; c < 3; ++c)
        REQUIRE(fabs(f_at[21 + c] - f4_ref[c]) < 1.0e-4, "line 4 fairlead load matches the standalone statics");

    /* The full-vector form: the Fixed blocks are not read. */
    memcpy(q_full, q, sizeof q_full);
    for (int i = 0; i < 12; ++i) q_full[i] = 1.0e3;
    if (init_deck_at(&full, g_box, q_full, BOX_NDOF)) goto done;
    if (loads(full, f_full, n)) goto done;
    REQUIRE(memcmp(f_full, f_at, sizeof f_at) == 0, "full and Coupled-only q0 give the same statics");
    CableDyn_GetCoupledMotion(full, q_full, v, a, n, &err);
    REQUIRE(err == CD_C_OK && memcmp(q_full, q, sizeof q) == 0, "the full form ignores the Fixed blocks");

    /* Bit for bit the statics of the deck moved to the host positions. */
    if (edit_deck(g_box, BOX_MOVED, "-0.062", "-0.077", "Coupled", 4)) goto done;
    if (init_deck(&moved, BOX_MOVED)) goto done;
    if (loads(moved, f_moved, n)) goto done;
    REQUIRE(memcmp(f_moved, f_at, sizeof f_at) == 0, "InitDeckAt equals InitDeck of the moved deck");

    /* Held at the host positions, the InitDeckAt model stays at equilibrium for 1 s. */
    memset(v, 0, sizeof v);
    memset(a, 0, sizeof a);
    for (int s = 1; s <= BOX_NSTEP; ++s) {
        if (step(at, BOX_DT, q, v, a, n) || loads(at, f, n)) goto done;
        for (int i = 12; i < n; ++i) drift = fmax(drift, fabs(f[i] - f_at[i]));
    }
    printf("InitDeckAt, fairleads held 1 s: max fairlead load change %.3e N\n", drift);
    REQUIRE(drift < 1.0e-6, "no start-up transient after InitDeckAt");

    /* InitDeck at the deck positions, then held at the host positions: the start-up transient. */
    if (init_deck(&plain, g_box)) goto done;
    if (loads(plain, f_plain0, n)) goto done;
    for (int s = 1; s <= BOX_NSTEP; ++s) {
        if (step(plain, BOX_DT, q, v, a, n) || loads(plain, f, n)) goto done;
        for (int i = 12; i < n; ++i) {
            ring = fmax(ring, fabs(f[i] - f_at[i]));
            if (s == BOX_NSTEP) ring_end = fmax(ring_end, fabs(f[i] - f_at[i]));
        }
    }
    printf("InitDeck z=%.3f: line 4 fairlead load (%.4f, %.4f, %.4f) N\n", DECK_Z, f_plain0[21], f_plain0[22],
           f_plain0[23]);
    printf("InitDeck, then held at z=%.3f for 1 s: max deviation from the equilibrium %.3e N "
           "(%.3e N at 1 s)\n",
           HOST_Z, ring, ring_end);
    REQUIRE(ring > 1.0e4 * drift && ring > 1.0e-2, "the plain start rings");

    /* Rejections keep the previous model. */
    CableDyn_InitDeckAt(at, g_box, (int)strlen(g_box), q_host, 9, &err);
    REQUIRE(err == CD_C_BAD_INPUT && last_error_has(at, "coupled_positions"), "a wrong q0 length is rejected");
    CableDyn_InitDeckAt(at, g_box, (int)strlen(g_box), q_host, 13, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a q0 length that is not a multiple of 3 is rejected");
    CableDyn_InitDeckAt(at, g_box, (int)strlen(g_box), NULL, BOX_NHOST, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a NULL q0 is rejected");
    q_host[5] = NAN;
    CableDyn_InitDeckAt(at, g_box, (int)strlen(g_box), q_host, BOX_NHOST, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a non-finite q0 is rejected");
    CableDyn_InitDeckAt(at, g_box, (int)strlen(g_box), NULL, 0, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "an empty q0 is rejected for a deck with Coupled points");
    REQUIRE(CableDyn_IsInitialized(at) && CableDyn_NCoupledDOF(at, &err) == BOX_NDOF,
            "a rejected InitDeckAt keeps the model");
    status = 0;

done:
    CableDyn_Close(&at, &err);
    CableDyn_Close(&full, &err);
    CableDyn_Close(&moved, &err);
    CableDyn_Close(&plain, &err);
    return status;
}

/* The full-vector form on a deck with a Free point: the Free block is not read, and the Free
 * point is solved to its static balance. */
static int check_free_point_full_form(void)
{
    void *only = NULL, *full = NULL;
    const double q_host[3] = {0.5, 0.0, -0.5};
    double q[6], v[6], a[6], q_full[6], f[6], f_full[6];
    int err = -1, ids[2], types[2], status = 1;

    if (init_deck_at(&only, g_free, q_host, 3)) goto done;
    REQUIRE(CableDyn_NCoupledDOF(only, &err) == 6, "the Coupled and the Free point have a block each");
    CableDyn_GetCoupledLayout(only, ids, types, 2, &err);
    REQUIRE(err == CD_C_OK && ids[0] == 1 && types[0] == CD_C_POINT_COUPLED && ids[1] == 2 &&
                types[1] == CD_C_POINT_FREE,
            "free-point deck layout: the Coupled point, then the Free point");
    CableDyn_GetCoupledMotion(only, q, v, a, 6, &err);
    REQUIRE(err == CD_C_OK && memcmp(q, q_host, sizeof q_host) == 0, "the Coupled point starts at q0");
    if (loads(only, f, 6)) goto done;
    memcpy(q_full, q, sizeof q);
    q_full[3] = q_full[4] = q_full[5] = 1.0e3;
    if (init_deck_at(&full, g_free, q_full, 6)) goto done;
    if (loads(full, f_full, 6)) goto done;
    CableDyn_GetCoupledMotion(full, q_full, v, a, 6, &err);
    REQUIRE(err == CD_C_OK && memcmp(q_full, q, sizeof q) == 0 && memcmp(f_full, f, sizeof f) == 0,
            "the full form ignores the Free block and equals the Coupled-only form");
    status = 0;

done:
    CableDyn_Close(&only, &err);
    CableDyn_Close(&full, &err);
    return status;
}

/* A point shared by an EI=0 and a finite-EI line has two blocks on the aggregate route; q0 must
 * give both the same position. The mixed deck is edited so that the cable hangs from the chain
 * fairlead 2 (its anchor moved so that the cable keeps its geometry). */
static int check_shared_point(void)
{
    void *h = NULL;
    double q[MIX_NDOF], v[MIX_NDOF], a[MIX_NDOF];
    int err = -1, n, ids[2], types[2], status = 1;

    if (edit_deck(g_mixed, MIXED_SHARED_HALF, "2    4      3", "2    2      3", NULL, 1) ||
        edit_deck(MIXED_SHARED_HALF, MIXED_SHARED, "3    Fixed     95.0", "3    Fixed     85.0", NULL, 1) ||
        init_deck(&h, MIXED_SHARED))
        goto done;
    n = CableDyn_NCoupledDOF(h, &err);
    REQUIRE(err == CD_C_OK && n == MIX_NDOF, "the shared fairlead has a block on each route");
    CableDyn_GetCoupledLayout(h, ids, types, 2, &err);
    REQUIRE(err == CD_C_OK && ids[0] == 2 && ids[1] == 2, "both blocks belong to point 2");
    CableDyn_GetCoupledMotion(h, q, v, a, n, &err);
    REQUIRE(err == CD_C_OK && memcmp(q, q + 3, 3 * sizeof *q) == 0, "the two blocks start together");
    q[0] -= 0.5;
    q[3] -= 0.5;
    CableDyn_InitDeckAt(h, MIXED_SHARED, (int)strlen(MIXED_SHARED), q, n, &err);
    if (err != CD_C_OK) report(h, "InitDeckAt with one position in both blocks", err);
    REQUIRE(err == CD_C_OK, "one position in both blocks of the shared point is accepted");
    q[3] -= 0.5;
    CableDyn_InitDeckAt(h, MIXED_SHARED, (int)strlen(MIXED_SHARED), q, n, &err);
    REQUIRE(err == CD_C_BAD_INPUT && last_error_has(h, "same position in both"),
            "two positions for the shared point are rejected");
    REQUIRE(CableDyn_IsInitialized(h) && CableDyn_NCoupledDOF(h, &err) == MIX_NDOF,
            "the rejection keeps the model");
    status = 0;

done:
    CableDyn_Close(&h, &err);
    return status;
}

/* On a deck without Free or Connect points, q0 may not move a line's End A below its Fixed
 * End B anchor (the Syrope line runs from the Vessel fairlead 2 to the anchor 1, both at z = 0). */
static int check_end_a_below_anchor(void)
{
    void *h = NULL;
    double q_host[3] = {20.5, 0.0, 0.0};
    int err = -1, status = 1;

    if (init_deck_at(&h, g_syrope, q_host, 3)) goto done;
    q_host[2] = -1.0;
    CableDyn_InitDeckAt(h, g_syrope, (int)strlen(g_syrope), q_host, 3, &err);
    REQUIRE(err == CD_C_BAD_INPUT && last_error_has(h, "coupled_positions displaces a LINE End A"),
            "an End A moved below its Fixed anchor is rejected");
    REQUIRE(CableDyn_IsInitialized(h) && CableDyn_NCoupledDOF(h, &err) == 6, "the rejection keeps the model");
    status = 0;

done:
    CableDyn_Close(&h, &err);
    return status;
}

/* A smooth host motion of the Coupled blocks: amplitude amp, sample time t. */
static void host_motion(const int *types, int nb, const double *q0, double amp, double t, double *q, double *v,
                        double *a)
{
    const double w = 2.0 * acos(-1.0);
    for (int k = 0; k < nb; ++k) {
        for (int c = 0; c < 3; ++c) {
            q[3 * k + c] = q0[3 * k + c];
            v[3 * k + c] = 0.0;
            a[3 * k + c] = 0.0;
        }
        if (types[k] != CD_C_POINT_COUPLED) continue;
        q[3 * k + 0] += amp * sin(w * t);
        v[3 * k + 0] = amp * w * cos(w * t);
        a[3 * k + 0] = -amp * w * w * sin(w * t);
        q[3 * k + 2] += 0.5 * amp * (1.0 - cos(w * t));
        v[3 * k + 2] = 0.5 * amp * w * sin(w * t);
        a[3 * k + 2] = 0.5 * amp * w * w * cos(w * t);
    }
}

/* A uniform current at every deck point (the point fluid fields), or still water. */
static int set_fluid(void *h, double u)
{
    int err = -1, np = CableDyn_NPoints(h, &err);
    double *vel = calloc((size_t)(3 * np), sizeof *vel), *acc = calloc((size_t)(3 * np), sizeof *acc);
    double *zw = calloc((size_t)np, sizeof *zw);
    if (vel != NULL && acc != NULL && zw != NULL) {
        for (int p = 0; p < np; ++p) vel[3 * p] = u;
        CableDyn_UpdatePointFluidFields(h, vel, acc, zw, np, 1025.0, &err);
    }
    free(vel);
    free(acc);
    free(zw);
    if (err != CD_C_OK) {
        report(h, "UpdatePointFluidFields", err);
        return 1;
    }
    return 0;
}

/* Save, take n_trial trial steps, restore (n_restore times) and take n_steps steps; the result must
 * equal a fresh model taking the same n_steps steps, bit for bit. Between the save and the second
 * restore, a failed InitDeck and a failed InitDeckAt must keep the save. With fluid set, the trial
 * passes run in a current (CableDyn_UpdatePointFluidFields) the reference model never sees. */
static int check_save_restore(const char *deck, const double *q_host, int n_host, double dt, double amp,
                              int n_trial, int n_steps, int fluid, const char *route)
{
    void *h = NULL, *ref = NULL;
    double *q0 = NULL, *q = NULL, *v = NULL, *a = NULL, *f = NULL, *f_ref = NULL, *mq = NULL, *mv = NULL;
    double *ma = NULL, *rq = NULL, *rv = NULL, *ra = NULL, *xh = NULL, *xr = NULL;
    int err = -1, n, *ids = NULL, *types = NULL, status = 1, n_lines;
    const char *missing = "capi_host_missing.dat";
    char label[160];

    if (init_deck_at(&h, deck, q_host, n_host) || init_deck_at(&ref, deck, q_host, n_host)) goto done;
    n = CableDyn_NCoupledDOF(h, &err);
    n_lines = CableDyn_NLines(h, &err);
    q0 = calloc((size_t)n, sizeof *q0);
    q = calloc((size_t)n, sizeof *q);
    v = calloc((size_t)n, sizeof *v);
    a = calloc((size_t)n, sizeof *a);
    f = calloc((size_t)n, sizeof *f);
    f_ref = calloc((size_t)n, sizeof *f_ref);
    mq = calloc((size_t)n, sizeof *mq);
    mv = calloc((size_t)n, sizeof *mv);
    ma = calloc((size_t)n, sizeof *ma);
    rq = calloc((size_t)n, sizeof *rq);
    rv = calloc((size_t)n, sizeof *rv);
    ra = calloc((size_t)n, sizeof *ra);
    ids = calloc((size_t)(n / 3), sizeof *ids);
    types = calloc((size_t)(n / 3), sizeof *types);
    REQUIRE(q0 && q && v && a && f && f_ref && mq && mv && ma && rq && rv && ra && ids && types, "allocation");
    CableDyn_GetCoupledMotion(h, q0, v, a, n, &err);
    CableDyn_GetCoupledLayout(h, ids, types, n / 3, &err);
    REQUIRE(err == CD_C_OK, "layout");

    CableDyn_RestoreState(h, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "restore without a save is rejected");
    CableDyn_SaveState(h, &err);
    REQUIRE(err == CD_C_OK, "save");
    /* Two outer correctors that take other (larger) trial motions before the final pass. */
    for (int corrector = 0; corrector < 2; ++corrector) {
        if (fluid && set_fluid(h, 0.5 * (corrector + 1))) goto done;
        for (int s = 1; s <= n_trial; ++s) {
            host_motion(types, n / 3, q0, 2.0 * amp * (corrector + 1), s * dt, q, v, a);
            if (step(h, dt, q, v, a, n)) goto done;
        }
        if (corrector == 1) {
            /* Failed re-initializations keep the model and its save. */
            CableDyn_InitDeck(h, missing, (int)strlen(missing), &err);
            REQUIRE(err != CD_C_OK, "InitDeck of a missing deck fails");
            CableDyn_InitDeckAt(h, deck, (int)strlen(deck), q_host, n_host - 3, &err);
            REQUIRE(err == CD_C_BAD_INPUT, "InitDeckAt with a q0 that fits neither form fails");
        }
        CableDyn_RestoreState(h, &err);
        snprintf(label, sizeof label, "%s: restore (after failed re-initializations on the second)", route);
        REQUIRE(err == CD_C_OK, label);
    }
    for (int s = 1; s <= n_steps; ++s) {
        host_motion(types, n / 3, q0, amp, s * dt, q, v, a);
        if (step(h, dt, q, v, a, n) || step(ref, dt, q, v, a, n)) goto done;
        if (loads(h, f, n) || loads(ref, f_ref, n)) goto done;
        CableDyn_GetCoupledMotion(h, mq, mv, ma, n, &err);
        CableDyn_GetCoupledMotion(ref, rq, rv, ra, n, &err);
        snprintf(label, sizeof label, "%s: restore + step %d equals the fresh model bit for bit", route, s);
        REQUIRE(memcmp(f, f_ref, (size_t)n * sizeof *f) == 0, label);
        REQUIRE(memcmp(mq, rq, (size_t)n * sizeof *mq) == 0 && memcmp(mv, rv, (size_t)n * sizeof *mv) == 0 &&
                    memcmp(ma, ra, (size_t)n * sizeof *ma) == 0,
                label);
    }
    /* Every line node agrees too. */
    for (int l = 0; l < n_lines; ++l) {
        int id = 0, nn = 0, sub = 0;
        CableDyn_GetObjectInfo(h, CD_C_OBJ_LINE, l, &id, &nn, &sub, &err);
        xh = calloc((size_t)(3 * nn), sizeof *xh);
        xr = calloc((size_t)(3 * nn), sizeof *xr);
        REQUIRE(xh && xr, "allocation");
        CableDyn_GetLineValues(h, l, CD_C_LINE_POSITION, xh, 3 * nn, &err);
        CableDyn_GetLineValues(ref, l, CD_C_LINE_POSITION, xr, 3 * nn, &err);
        snprintf(label, sizeof label, "%s: line %d nodes after the restore equal the fresh model", route, id);
        REQUIRE(err == CD_C_OK && memcmp(xh, xr, (size_t)(3 * nn) * sizeof *xh) == 0, label);
        free(xh);
        free(xr);
        xh = xr = NULL;
    }
    printf("%s: %d trial steps x 2 correctors%s, restore, %d steps: bit-identical to the fresh model\n", route,
           n_trial, fluid ? " in a current" : "", n_steps);

    /* A successful initialization discards the save. */
    CableDyn_InitDeckAt(h, deck, (int)strlen(deck), q_host, n_host, &err);
    REQUIRE(err == CD_C_OK, "re-initialization");
    CableDyn_RestoreState(h, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a re-initialization discards the save");
    status = 0;

done:
    free(q0);
    free(q);
    free(v);
    free(a);
    free(f);
    free(f_ref);
    free(mq);
    free(mv);
    free(ma);
    free(rq);
    free(rv);
    free(ra);
    free(ids);
    free(types);
    free(xh);
    free(xr);
    CableDyn_Close(&h, &err);
    CableDyn_Close(&ref, &err);
    return status;
}

static int check_aggregate(void)
{
    void *h = NULL, *moved = NULL;
    int err = -1, n = MIX_NDOF, ids[2], types[2], status = 1;
    double q[MIX_NDOF], v[MIX_NDOF], a[MIX_NDOF], q_host[MIX_NDOF], f[MIX_NDOF], f_moved[MIX_NDOF];

    if (init_deck(&h, g_mixed)) goto done;
    n = CableDyn_NCoupledDOF(h, &err);
    REQUIRE(err == CD_C_OK && n == MIX_NDOF, "the aggregate coupled vector holds the two fairleads only");
    CableDyn_GetCoupledLayout(h, ids, types, 2, &err);
    REQUIRE(err == CD_C_OK && ids[0] == 2 && ids[1] == 4, "aggregate blocks: the chain, then the cable fairlead");
    REQUIRE(types[0] == CD_C_POINT_COUPLED && types[1] == CD_C_POINT_COUPLED, "aggregate blocks are Coupled");
    CableDyn_GetCoupledMotion(h, q, v, a, n, &err);
    REQUIRE(err == CD_C_OK, "aggregate coupled motion");

    /* InitDeckAt on the aggregate: the fairleads 1 m outward and 0.5 m down. */
    memcpy(q_host, q, sizeof q);
    q_host[0] -= 1.0;
    q_host[2] -= 0.5;
    q_host[3] += 1.0;
    q_host[5] -= 0.5;
    CableDyn_InitDeckAt(h, g_mixed, (int)strlen(g_mixed), q_host, MIX_NDOF, &err);
    if (err != CD_C_OK) report(h, "aggregate InitDeckAt", err);
    REQUIRE(err == CD_C_OK, "aggregate InitDeckAt");
    CableDyn_GetCoupledMotion(h, q, v, a, n, &err);
    REQUIRE(err == CD_C_OK && memcmp(q, q_host, sizeof q) == 0, "aggregate fairleads start exactly at q0");
    if (loads(h, f, n)) goto done;
    printf("aggregate InitDeckAt: fairlead loads (%.1f, %.1f, %.1f) N and (%.1f, %.1f, %.1f) N\n", f[0], f[1],
           f[2], f[3], f[4], f[5]);

    /* Bit for bit the statics of the deck with both fairleads moved to q0. */
    REQUIRE(q_host[0] == -6.0 && q_host[2] == -5.5 && q_host[3] == 6.0 && q_host[5] == -5.5,
            "the mixed deck fairleads start at (-5, 0, -5) and (5, 0, -5)");
    if (edit_deck(g_mixed, MIXED_HALF, "-5.0      0.0     -5.0", "-6.0      0.0     -5.5", "Coupled", 1) ||
        edit_deck(MIXED_HALF, MIXED_MOVED, " 5.0      0.0     -5.0", " 6.0      0.0     -5.5", "Coupled", 1) ||
        init_deck(&moved, MIXED_MOVED) || loads(moved, f_moved, n))
        goto done;
    REQUIRE(memcmp(f_moved, f, sizeof f) == 0, "aggregate InitDeckAt equals InitDeck of the moved deck");

    CableDyn_InitDeckAt(h, g_mixed, (int)strlen(g_mixed), q_host, 3, &err);
    REQUIRE(err == CD_C_BAD_INPUT && last_error_has(h, "coupled_positions"),
            "a wrong aggregate q0 length is rejected");
    CableDyn_Close(&h, &err);
    CableDyn_Close(&moved, &err);

    status = check_save_restore(g_mixed, q_host, MIX_NDOF, MIX_DT, 0.2, 5, 10, 0, "aggregate route");

done:
    CableDyn_Close(&h, &err);
    CableDyn_Close(&moved, &err);
    return status;
}

/* Viscoelastic, Syrope and seabed-friction states, and point fluid fields, through the save. */
static int check_state_models(void)
{
    /* the viscoelastic catenary's fairlead (deck: 58, 0, -14) and the Syrope fairlead (deck) */
    const double q_visco[3] = {58.5, 0.0, -14.2}, q_syrope[3] = {20.5, 0.0, 0.0};
    const double q_free[3] = {0.5, 0.0, -0.5};

    /* seabed friction needs a dynamic deck: dtM and TMax come with it */
    if (edit_deck(g_visco, VISCO_FRICTION, "none      frictionMu",
                  "0.02      dtM\n10.0      TMax\n0.5       frictionMu", NULL, 1))
        return 1;
    return check_save_restore(VISCO_FRICTION, q_visco, 3, 0.02, 0.2, 4, 10, 0,
                              "point route, viscoelastic with seabed friction") ||
           check_save_restore(g_syrope, q_syrope, 3, 0.01, 0.01, 4, 10, 0, "point route, Syrope") ||
           check_save_restore(g_free, q_free, 3, 0.01, 0.1, 4, 10, 1, "point route, Free point");
}

static int run(void)
{
    double q_host[BOX_NHOST];
    box_fairleads(HOST_Z, q_host);
    return check_version() || check_point_layout() || check_raw_layout() || check_init_at() ||
           check_free_point_full_form() || check_shared_point() || check_end_a_below_anchor() ||
           check_save_restore(g_box, q_host, BOX_NHOST, BOX_DT, 0.005, 7, 20, 0, "point route") ||
           check_aggregate() || check_raw_save_restore() || check_save_after_failed_raw_init() ||
           check_state_models();
}

int main(int argc, char **argv)
{
    int failed;

    if (argc != 6) {
        fputs("usage: test_c_api_host_coupling <box_points.dat> <mixed_chain_cable.dat> <viscoelastic.dat> "
              "<syrope.dat> <free_point.dat>\n",
              stderr);
        return 2;
    }
    g_box = argv[1];
    g_mixed = argv[2];
    g_visco = argv[3];
    g_syrope = argv[4];
    g_free = argv[5];
    remove_written_decks();
    failed = run();
    remove_written_decks();
    if (failed) return 1;
    puts("PASS: CableDyn C API host coupling");
    return 0;
}
