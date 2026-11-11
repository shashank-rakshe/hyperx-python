/* File: tests/test_c_api_raw_small_dt.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * A raw-array, tension-only line with no external load (f_ext = 0) stepped at very
 * small dt must report convergence: without an external load the Newton residual's
 * force scale must not be the round-off-sized initial residual, or steps sitting on
 * the inertia round-off floor would be reported unconverged and retried with dt/64.
 */
#include "CableDyn_CAPI.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

enum { NN = 21, NE = NN - 1, NDOF = 6, NSTEP = 50 };

int main(void)
{
    const double pi = 3.14159265358979323846, span = 100.0, z = -50.0, prestrain = 0.01;
    const double dts[] = {1.0e-3, 1.0e-5, 1.0e-7};
    double q0[3 * NN], v0[3 * NN], l0[NE], ea[NE], rho[NE];
    int conn[2 * NE], fixed[6] = {1, 2, 3, 3 * NN - 2, 3 * NN - 1, 3 * NN};
    int i, e, k, d;

    memset(q0, 0, sizeof q0);
    memset(v0, 0, sizeof v0);
    for (i = 0; i < NN; ++i) {
        q0[3 * i] = span * i / NE;
        q0[3 * i + 2] = z;
    }
    for (e = 0; e < NE; ++e) {
        conn[2 * e] = e + 1;
        conn[2 * e + 1] = e + 2;
        l0[e] = (1.0 - prestrain) * span / NE;
        ea[e] = 1.0e8;
        rho[e] = 100.0;
    }
    for (d = 0; d < (int)(sizeof dts / sizeof dts[0]); ++d) {
        void *h = NULL;
        int err = -1, n, converged_steps = 0;
        double q[NDOF], v[NDOF], a[NDOF], qs[NDOF], t = 0.0, w = 2.0 * pi / 10.0;
        char msg[256];

        CableDyn_Create(&h, &err);
        CableDyn_InitLine(h, NN, NE, q0, v0, conn, l0, ea, rho, fixed, 6, 1, 0.8, &err);
        if (err != CD_C_OK) {
            CableDyn_GetLastError(h, msg, (int)sizeof msg);
            fprintf(stderr, "FAIL InitLine: %s\n", msg);
            return 1;
        }
        n = CableDyn_NCoupledDOF(h, &err);
        if (n != NDOF) {
            fprintf(stderr, "FAIL expected %d coupled DOFs, got %d\n", NDOF, n);
            return 1;
        }
        CableDyn_GetCoupledMotion(h, qs, v, a, n, &err);
        for (k = 0; k < NSTEP; ++k) {
            bool converged = false, stalled = false;
            int n_iter = 0;
            t += dts[d];
            for (i = 0; i < n; ++i) {
                q[i] = qs[i];
                v[i] = 0.0;
                a[i] = 0.0;
            }
            /* 0.5 m surge amplitude at a 10 s period on both ends. */
            for (i = 0; i < n; i += 3) {
                q[i] = qs[i] + 0.5 * sin(w * t);
                v[i] = 0.5 * w * cos(w * t);
                a[i] = -0.5 * w * w * sin(w * t);
            }
            CableDyn_Step(h, dts[d], q, v, a, n, &converged, &stalled, &n_iter, &err);
            if (err != CD_C_OK) {
                CableDyn_GetLastError(h, msg, (int)sizeof msg);
                fprintf(stderr, "FAIL dt=%g step %d: %s\n", dts[d], k, msg);
                return 1;
            }
            converged_steps += converged ? 1 : 0;
        }
        CableDyn_Close(&h, &err);
        printf("dt=%g: %d of %d steps converged\n", dts[d], converged_steps, NSTEP);
        if (converged_steps != NSTEP) {
            fprintf(stderr, "FAIL dt=%g reported %d unconverged steps\n", dts[d], NSTEP - converged_steps);
            return 1;
        }
    }
    printf("PASS c_api_raw_small_dt\n");
    return 0;
}
