// File: validation/scripts/moordyn_c_driver.cpp
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
//
// Standalone MoorDyn-C v2 reference driver for the L2 dynamic comparison.
// Drives a single coupled fairlead through a prescribed sinusoidal heave and
// records the fairlead tension time series. The fairlead tension is read with
// MoorDyn_GetLineNodeTen(line, 0): node 0 is the coupled fairlead end in these
// decks, whose lines run from the fairlead (end A) to the anchor (end B), whereas
// the fairlead-tension helpers of the API refer to the other line end for this
// ordering. The node-0 value agrees with the closed-form catenary and CableDyn
// (static fairlead 996.6 kN against 1001.7 kN, within 0.5%).
//
// Build (Strawberry g++, against the MoorDyn-C build):
//   g++ -O2 validation/scripts/moordyn_c_driver.cpp -I <MoorDyn>/source \
//       -L <MoorDyn>/build/source -lmoordyn -o moordyn_c_driver
// Usage: moordyn_c_driver <deck> <amp_m> <period_s> <warmup_s> <score_s> <odt_s> <out>
#include "MoorDyn2.h"
#include "Line.h"
#include <cstdio>
#include <cmath>
#include <chrono>
static double fairlead_tension(MoorDynLine line) {  // node 0 = coupled fairlead end
  double t[3] = {0, 0, 0};
  MoorDyn_GetLineNodeTen(line, 0, t);
  return std::sqrt(t[0] * t[0] + t[1] * t[1] + t[2] * t[2]);
}
int main(int argc, char** argv) {
  if (argc < 8) { printf("usage: moordyn_c_driver <deck> <amp> <period> <warmup> <score> <odt> <out>\n"); return 1; }
  const char* infile = argv[1];
  double amp = atof(argv[2]), period = atof(argv[3]);
  double warmup = atof(argv[4]), score = atof(argv[5]), odt = atof(argv[6]);
  const char* outpath = argv[7];
  double w = 2.0 * M_PI / period;
  MoorDyn s = MoorDyn_Create(infile);
  if (!s) { printf("Create failed\n"); return 2; }
  double x[3] = {0, 0, 0}, xd[3] = {0, 0, 0}, f[3] = {0, 0, 0};
  if (MoorDyn_Init(s, x, xd) != 0) { printf("Init failed\n"); return 3; }
  MoorDynLine line = MoorDyn_GetLine(s, 1);
  FILE* out = fopen(outpath, "w");
  double t = -warmup;
  long nstep = (long)llround((warmup + score) / odt);
  auto t0 = std::chrono::steady_clock::now();
  for (long k = 1; k <= nstep; k++) {
    double tn = -warmup + (double)k * odt, hz = amp * sin(w * tn), vz = amp * w * cos(w * tn);
    x[2] = hz; xd[2] = vz;
    double tt = t, dt = odt;
    if (MoorDyn_Step(s, x, xd, f, &tt, &dt) != 0) { printf("Step failed t=%g\n", tn); return 4; }
    t = tn;
    if (tn >= -1e-9) fprintf(out, "%.4f %.6f\n", tn, fairlead_tension(line) * 1e-3);
  }
  auto t1 = std::chrono::steady_clock::now();
  fprintf(stderr, "wall-clock %.3f s\n", std::chrono::duration<double>(t1 - t0).count());
  fclose(out); MoorDyn_Close(s); return 0;
}
