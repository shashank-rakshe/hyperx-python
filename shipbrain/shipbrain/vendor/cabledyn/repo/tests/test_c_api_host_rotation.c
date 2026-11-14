/* File: tests/test_c_api_host_rotation.c
 * SPDX-License-Identifier: Apache-2.0
 * Host-rotation gate of C ABI 1 minor extension 3, through the public header
 * and the shared library.
 *
 * Usage: test_c_api_host_rotation <box_points.dat>
 *
 * The test writes the straight neutral torsion line of test_coupled_torsion
 * (GJ 5e4 N m^2, 100 m along +x from the Coupled fairlead (0, 0, -50) to a
 * Fixed anchor, 40 elements, both ends clamped and restrained in torsion, a
 * negligible polar inertia: the quasi-static torsion) and checks:
 * - CableDyn_InitDeck refuses the deck and names CableDyn_InitDeckRotating,
 *   which accepts it (statics at the deck positions, rotations at rest);
 * - feedthrough: CableDyn_UpdateRotations with a 20 deg roll about the line
 *   axis, then CableDyn_UpdateStates, twists the end element alone (Twist1 =
 *   -20 deg); CableDyn_GetCoupledMoments returns its torque GJ phi / l_e about
 *   the line axis, resisting the roll, and no bending moment;
 * - march: a roll at 60 deg/s gives Twist1 = -phi(t) and the quasi-static
 *   torque GJ phi / L at both ends and as the coupled moment, at every step;
 * - SaveState/RestoreState carry the rotations: a restore after other
 *   rotations were set steps bit-identically to the step from the save;
 * - the rejections are all or nothing: a wrong block count, a null pointer, a
 *   DCM that is not proper orthogonal and a non-finite rate leave the handle
 *   stepping bit-identically to one that never saw them;
 * - a handle initialised without rotations refuses CableDyn_UpdateRotations;
 *   the EI = 0 point route (box_points.dat) takes rotations and ignores them,
 *   and its coupled moments are zero.
 * - the host fluid calls of extension 4 link and run through the public header.
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

#define PI 3.14159265358979323846
#define DEG (PI / 180.0)
#define GJ 5.0e4
#define LEN 100.0
#define NSEG 40
#define DT 0.05

static const char *g_box;

#define TORSION_DECK "capi_rot_torsion.dat"
#define FREE_DECK "capi_rot_free.dat"
static const char *const g_written[] = {TORSION_DECK, FREE_DECK};

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

static int last_error_has(void *h, const char *text)
{
    char msg[4097];
    CableDyn_GetLastError(h, msg, (int)sizeof msg);
    return strstr(msg, text) != NULL;
}

/* The straight neutral torsion line; tors = "Rigid" (restrained) or "Free". */
static int write_deck(const char *path, const char *tors)
{
    FILE *f = fopen(path, "w");
    if (!f) return 1;
    fputs("host rotation gate\n--- LINE TYPES ---\n", f);
    fputs("Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat\n", f);
    fputs("(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)\n", f);
    fprintf(f, "cab 0.2 %.16e 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-9 0.0 0.0 0.0 0.0\n", 1025.0 * 0.25 * PI * 0.04);
    fputs("--- POINTS ---\nID Type X Y Z Mass Vol CdA Ca\n(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)\n", f);
    fputs("1 Coupled 0.0 0.0 -50.0 0 0 0 0\n2 Fixed 100.0 0.0 -50.0 0 0 0 0\n", f);
    fputs("--- LINES ---\nID NodeA NodeB Outputs\n(-) (-) (-) (-)\n1 1 2 -\n", f);
    fputs("--- SECTIONS ---\nLineID LineType Length NumSegs\n(-) (-) (m) (-)\n1 cab 100.0 40\n", f);
    fputs("--- END CONNECTIONS ---\nLineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist\n", f);
    fputs("(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)\n", f);
    fprintf(f, "1 A Rigid 1 0 0 %s 0 0 1 0\n1 B Rigid 1 0 0 %s 0 0 1 0\n", tors, tors);
    fputs("--- OPTIONS ---\n9.80665 g\n1025.0 rhoW\n0.05 dtM\n0.0 TMax\n", f);
    fputs(strcmp(tors, "Free") == 0 ? "--- OUTPUTS ---\nFairTen1\n--- END ---\n"
                                    : "--- OUTPUTS ---\nTorq1N1\nTorq1N41\nTwist1\n--- END ---\n",
          f);
    return fclose(f) != 0;
}

/* OpenFAST mesh orientation (global to local) of a roll phi about +x, row-major. */
static void roll_dcm(double phi, double *r)
{
    const double c = cos(phi), s = sin(phi);
    const double m[9] = {1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c};
    memcpy(r, m, sizeof m);
}

static int channel(void *h, const char *token, double *value)
{
    int err = -1;
    CableDyn_EvalChannel(h, token, (int)strlen(token), value, &err);
    if (err != CD_C_OK) {
        report(h, token, err);
        return 1;
    }
    return 0;
}

static int rotate(void *h, double phi, double rate)
{
    double r[9];
    const double om[3] = {rate, 0.0, 0.0}, al[3] = {0.0, 0.0, 0.0};
    int err = -1;
    roll_dcm(phi, r);
    CableDyn_UpdateRotations(h, r, om, al, 1, &err);
    if (err != CD_C_OK) {
        report(h, "UpdateRotations", err);
        return 1;
    }
    return 0;
}

static int step_at_deck(void *h)
{
    const double q[3] = {0.0, 0.0, -50.0}, z[3] = {0.0, 0.0, 0.0};
    bool converged = false, stalled = false;
    int n_iter = 0, err = -1;
    CableDyn_Step(h, DT, q, z, z, 3, &converged, &stalled, &n_iter, &err);
    if (err != CD_C_OK || !converged) {
        report(h, "Step", err);
        return 1;
    }
    return 0;
}

static int moments(void *h, double *m)
{
    int err = -1;
    CableDyn_GetCoupledMoments(h, m, 3, &err);
    if (err != CD_C_OK) {
        report(h, "GetCoupledMoments", err);
        return 1;
    }
    return 0;
}

static int init_rotating(void **h, const char *deck)
{
    int err = -1;
    CableDyn_Create(h, &err);
    CHECK(err == CD_C_OK, "create");
    CableDyn_InitDeckRotating(*h, deck, (int)strlen(deck), NULL, 0, &err);
    if (err != CD_C_OK) {
        report(*h, "InitDeckRotating", err);
        return 1;
    }
    return 0;
}

static void close_handle(void **h)
{
    int err;
    if (*h) CableDyn_Close(h, &err);
    *h = NULL;
}

static int check_init(void)
{
    void *h = NULL;
    int err = -1, failed = 1;
    CHECK(CableDyn_GetAbiMinor() >= 3, "the library declares ABI minor 3");
    CableDyn_Create(&h, &err);
    REQUIRE(err == CD_C_OK, "create");
    CableDyn_InitDeck(h, TORSION_DECK, (int)strlen(TORSION_DECK), &err);
    if (err != CD_C_BAD_INPUT || !last_error_has(h, "CableDyn_InitDeckRotating")) {
        report(h, "InitDeck refuses a line restrained in torsion, naming CableDyn_InitDeckRotating", err);
        goto done;
    }
    close_handle(&h);
    if (init_rotating(&h, TORSION_DECK)) goto done;
    REQUIRE(CableDyn_NCoupledDOF(h, &err) == 3 && err == CD_C_OK, "one coupled point");
    {
        double ta, tw, m[3];
        if (channel(h, "Torq1N1", &ta) || channel(h, "Twist1", &tw) || moments(h, m)) goto done;
        REQUIRE(fabs(ta) <= 1.0e-6 && fabs(tw) <= 1.0e-9, "no pretwist, no torque at rest");
        REQUIRE(fabs(m[0]) <= 1.0e-6, "no coupled torque at rest");
    }
    /* a handle without rotations refuses them */
    close_handle(&h);
    CableDyn_Create(&h, &err);
    REQUIRE(err == CD_C_OK, "create");
    CableDyn_InitDeck(h, FREE_DECK, (int)strlen(FREE_DECK), &err);
    if (err != CD_C_OK) {
        report(h, "InitDeck (torsion free)", err);
        goto done;
    }
    {
        double r[9];
        const double z[3] = {0.0, 0.0, 0.0};
        roll_dcm(0.1, r);
        CableDyn_UpdateRotations(h, r, z, z, 1, &err);
        REQUIRE(err == CD_C_BAD_INPUT && last_error_has(h, "CableDyn_InitDeckRotating"),
                "a handle initialised by CableDyn_InitDeck refuses rotations");
    }
    puts("init: InitDeck refuses the torsion deck, InitDeckRotating takes it at rest");
    failed = 0;
done:
    close_handle(&h);
    return failed;
}

static int check_feedthrough(void)
{
    void *h = NULL;
    int err = -1, failed = 1;
    const double phi = 20.0 * DEG, le = LEN / NSEG, m_ref = GJ * phi / le;
    const double q[3] = {0.0, 0.0, -50.0}, z[3] = {0.0, 0.0, 0.0};
    double ta, tb, tw, m[3];
    if (init_rotating(&h, TORSION_DECK)) goto done;
    if (rotate(h, phi, 0.0)) goto done;
    CableDyn_UpdateStates(h, q, z, z, 3, &err);
    if (err != CD_C_OK) {
        report(h, "UpdateStates", err);
        goto done;
    }
    if (channel(h, "Torq1N1", &ta) || channel(h, "Torq1N41", &tb) || channel(h, "Twist1", &tw) || moments(h, m))
        goto done;
    printf("feedthrough: Twist1 %.9f deg, Torq1N1 %.6e (ref %.6e), coupled moment %.6e %.3e %.3e\n", tw, ta,
           -m_ref, m[0], m[1], m[2]);
    REQUIRE(fabs(tw + 20.0) <= 1.0e-6, "feedthrough: Twist1 = -roll");
    REQUIRE(fabs(ta + m_ref) <= 1.0e-6 * m_ref && fabs(tb) <= 1.0e-9 * m_ref,
            "feedthrough: the end element alone takes the twist");
    REQUIRE(fabs(fabs(m[0]) - m_ref) <= 1.0e-6 * m_ref, "feedthrough: the coupled moment is the torque");
    REQUIRE(m[0] * phi < 0.0, "feedthrough: the moment on the host resists its roll");
    REQUIRE(fmax(fabs(m[1]), fabs(m[2])) <= 1.0e-6 * m_ref, "feedthrough: a straight line has no bending moment");
    failed = 0;
done:
    close_handle(&h);
    return failed;
}

static int check_march(void)
{
    void *h = NULL;
    int failed = 1;
    const double rate = 60.0 * DEG;
    double werr = 0.0, terr = 0.0, merr = 0.0;
    if (init_rotating(&h, TORSION_DECK)) goto done;
    for (int k = 1; k <= 10; ++k) {
        const double phi = rate * DT * k;
        double ta, tb, tw, m[3];
        if (rotate(h, phi, rate) || step_at_deck(h)) goto done;
        if (channel(h, "Torq1N1", &ta) || channel(h, "Torq1N41", &tb) || channel(h, "Twist1", &tw) || moments(h, m))
            goto done;
        werr = fmax(werr, fabs(tw + phi / DEG));
        terr = fmax(terr, fmax(fabs(ta + GJ * phi / LEN), fabs(tb - ta)));
        merr = fmax(merr, fmax(fabs(m[0] + GJ * phi / LEN), fmax(fabs(m[1]), fabs(m[2]))));
    }
    printf("march: Twist1 error %.3e deg, torque error %.3e N m, coupled moment error %.3e N m\n", werr, terr, merr);
    REQUIRE(werr <= 1.0e-6, "march: Twist1 = -roll(t) at every step");
    REQUIRE(terr <= 1.0e-6 * GJ, "march: Torq = GJ Twist / L at both ends at every step");
    REQUIRE(merr <= 1.0e-6 * GJ, "march: the coupled moment is the restoring torque at every step");
    failed = 0;
done:
    close_handle(&h);
    return failed;
}

static int check_save_restore(void)
{
    void *h = NULL;
    int err = -1, failed = 1;
    const double rate = 60.0 * DEG;
    double m1[3], m2[3], tw1, tw2;
    if (init_rotating(&h, TORSION_DECK)) goto done;
    for (int k = 1; k <= 4; ++k)
        if (rotate(h, rate * DT * k, rate) || step_at_deck(h)) goto done;
    if (rotate(h, rate * DT * 5, rate)) goto done;
    CableDyn_SaveState(h, &err);
    REQUIRE(err == CD_C_OK, "SaveState");
    if (step_at_deck(h) || moments(h, m1) || channel(h, "Twist1", &tw1)) goto done;
    /* other rotations set and stepped before the restore */
    if (rotate(h, rate * DT * 9, 3.0 * rate) || step_at_deck(h)) goto done;
    CableDyn_RestoreState(h, &err);
    REQUIRE(err == CD_C_OK, "RestoreState");
    if (step_at_deck(h) || moments(h, m2) || channel(h, "Twist1", &tw2)) goto done;
    printf("save/restore: coupled torque %.9e and %.9e\n", m1[0], m2[0]);
    REQUIRE(memcmp(m1, m2, sizeof m1) == 0 && tw1 == tw2,
            "a restore brings back the saved rotations and steps bit-identically");
    failed = 0;
done:
    close_handle(&h);
    return failed;
}

static int check_rejections(void)
{
    void *a = NULL, *b = NULL;
    int err = -1, failed = 1;
    const double rate = 60.0 * DEG;
    double r[9], ma[3], mb[3];
    const double z[3] = {0.0, 0.0, 0.0};
    if (init_rotating(&a, TORSION_DECK) || init_rotating(&b, TORSION_DECK)) goto done;
    for (int k = 1; k <= 3; ++k) {
        const double phi = rate * DT * k;
        if (rotate(a, phi, rate) || rotate(b, phi, rate)) goto done;
        /* rejected updates on a only */
        roll_dcm(phi + 0.5, r);
        CableDyn_UpdateRotations(a, r, z, z, 2, &err);
        REQUIRE(err == CD_C_BAD_INPUT && last_error_has(a, "n_block"), "a wrong block count is refused");
        CableDyn_UpdateRotations(a, r, NULL, z, 1, &err);
        REQUIRE(err == CD_C_BAD_INPUT && last_error_has(a, "null"), "a null pointer is refused");
        for (int i = 0; i < 9; ++i) r[i] *= 1.01;
        CableDyn_UpdateRotations(a, r, z, z, 1, &err);
        REQUIRE(err == CD_C_BAD_INPUT && last_error_has(a, "proper orthogonal"),
                "a DCM that is not proper orthogonal is refused");
        roll_dcm(phi + 0.5, r);
        {
            const double nan_rate[3] = {NAN, 0.0, 0.0};
            CableDyn_UpdateRotations(a, r, nan_rate, z, 1, &err);
            REQUIRE(err == CD_C_BAD_INPUT && last_error_has(a, "finite"), "a non-finite rate is refused");
        }
        if (step_at_deck(a) || step_at_deck(b)) goto done;
    }
    if (moments(a, ma) || moments(b, mb)) goto done;
    REQUIRE(memcmp(ma, mb, sizeof ma) == 0, "rejected rotations leave the handle unchanged");
    puts("rejections: block count, null pointer, DCM, rate refused; the handle steps unchanged");
    failed = 0;
done:
    close_handle(&a);
    close_handle(&b);
    return failed;
}

static int check_point_route(void)
{
    void *h = NULL;
    int err = -1, failed = 1, n, nb;
    double *dcm = NULL, *om = NULL, *m = NULL;
    if (init_rotating(&h, g_box)) goto done;
    n = CableDyn_NCoupledDOF(h, &err);
    REQUIRE(err == CD_C_OK && n > 0 && n % 3 == 0, "the box has coupled blocks");
    nb = n / 3;
    dcm = calloc((size_t)(9 * nb), sizeof *dcm);
    om = calloc((size_t)(3 * nb), sizeof *om);
    m = malloc((size_t)n * sizeof *m);
    REQUIRE(dcm && om && m, "allocation");
    for (int k = 0; k < nb; ++k) roll_dcm(0.3, dcm + 9 * k);
    CableDyn_UpdateRotations(h, dcm, om, om, nb, &err);
    REQUIRE(err == CD_C_OK, "the point route takes rotations");
    for (int i = 0; i < n; ++i) m[i] = 1.0;
    CableDyn_GetCoupledMoments(h, m, n, &err);
    REQUIRE(err == CD_C_OK, "GetCoupledMoments on the point route");
    for (int i = 0; i < n; ++i) REQUIRE(m[i] == 0.0, "EI = 0 lines apply no moment");
    puts("point route: rotations taken and unused, moments zero");
    failed = 0;
done:
    free(dcm);
    free(om);
    free(m);
    close_handle(&h);
    return failed;
}

static int check_host_fluid(void)
{
    enum { MAX_NODES = NSEG + 1 };
    static double xyz[3 * MAX_NODES], vel[3 * MAX_NODES], acc[3 * MAX_NODES], eta[MAX_NODES];
    const double q[3] = {0.0, 0.0, -50.0}, z[3] = {0.0, 0.0, 0.0};
    bool converged = false, stalled = false;
    void *h = NULL;
    int err = -1, failed = 1, n, n_iter = 0;
    CHECK(CableDyn_GetAbiMinor() >= 4, "the library declares ABI minor 4");
    CableDyn_Create(&h, &err);
    REQUIRE(err == CD_C_OK, "create");
    CableDyn_SetHostFluid(h, 1, &err);
    REQUIRE(err == CD_C_OK, "SetHostFluid");
    CableDyn_InitDeckRotating(h, TORSION_DECK, (int)strlen(TORSION_DECK), NULL, 0, &err);
    REQUIRE(err == CD_C_OK, "InitDeckRotating with a host fluid field");
    n = CableDyn_NFluidNodes(h, &err);
    REQUIRE(err == CD_C_OK && n == MAX_NODES, "one fluid node per line node");
    CableDyn_GetFluidNodePositions(h, xyz, n, &err);
    REQUIRE(err == CD_C_OK && xyz[3 * (n - 1) + 2] < 0.0, "the node positions");
    CableDyn_GetFluidNodePositions(h, xyz, n - 1, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a wrong node count is refused");
    CableDyn_Step(h, DT, q, z, z, 3, &converged, &stalled, &n_iter, &err);
    REQUIRE(err == CD_C_BAD_INPUT && last_error_has(h, "before the first step"),
            "a step before the first field is refused");
    CableDyn_UpdateFluidFields(h, vel, acc, eta, NULL, n, &err);
    REQUIRE(err == CD_C_OK, "UpdateFluidFields");
    CableDyn_UpdateFluidFields(h, NULL, acc, eta, NULL, n, &err);
    REQUIRE(err == CD_C_BAD_INPUT, "a null field is refused");
    REQUIRE(step_at_deck(h) == 0, "a step in the held field");
    failed = 0;
done:
    close_handle(&h);
    return failed;
}

int main(int argc, char **argv)
{
    int failed;
    if (argc != 2) {
        fputs("usage: test_c_api_host_rotation <box_points.dat>\n", stderr);
        return 2;
    }
    g_box = argv[1];
    remove_written_decks();
    if (write_deck(TORSION_DECK, "Rigid") || write_deck(FREE_DECK, "Free")) {
        fputs("FAIL: writing the decks\n", stderr);
        remove_written_decks();
        return 1;
    }
    failed = check_init() || check_feedthrough() || check_march() || check_save_restore() || check_rejections() ||
             check_point_route() || check_host_fluid();
    remove_written_decks();
    if (failed) return 1;
    puts("PASS: CableDyn C API host rotations");
    return 0;
}
