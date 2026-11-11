<!-- SPDX-License-Identifier: Apache-2.0 -->

# Bodies, rods and shared anchors: reference suite

Cross-code references for the rigid-body, rod and shared-anchor features. Each case has a
CableDyn deck, a MoorDyn-C twin with the same numbers, the stored reference series and the
pass limits that `validation/scripts/bodies_score.py` applies to a CableDyn run (the `gate`
field of each metric in `cases.json`).

## Case matrix

| Case | Family | What is released or driven | Reference | Pass limits (metric: limit) |
| --- | --- | --- | --- | --- |
| V-D1a, V-D1b | Rigid6 buoy on three taut legs (`examples/rigid6_buoy.dat`) | surge 0.5 m / 5 m, 120 s | MoorDyn-C 2.7.1, rk4, converged dt | surge, FairTen1-3 `e_rms` 0.5 %; heave `e_rms` 5 %; surge `e_T` 0.3 %; t = 0 tension 0.5 %; V-D1b adds 14 cross-check metrics against OrcaFlex (Orcina; see below) |
| V-D2a, V-D2b | Free spar rod on four legs (`examples/rod_moored_spar.dat`) | dx 0.1 m, dz 0.1 m, 60 s | MoorDyn-C | rod ends, FairTen1-4 `e_rms` 2 %; t = 0 tension 0.5 % |
| V-D2c, V-D2d | same | dx 2 m, dz 1 m (slack-taut), 10 s | MoorDyn-C (body-fixed-rod twin) | rod ends, FairTen1-4 `e_rms` 5 %; first-extreme `e_pk` 5 %; t = 0 tension 0.5 % |
| V-R3 | same, `CdEnd = CaEnd = 0.6` | dz 0.1 m | MoorDyn-C | heave `e_T` 1 %, `e_rms` 3 % |
| V-SP-heave | Ballasted surface-piercing spar (d 8 m, draft 80 m) | heave +1 m, 200 s | analytic; MoorDyn-C | draft 1e-4 m; heave `e_T` 1 % |
| V-SP-pitch | same | pitch 3 deg, 400 s | analytic; MoorDyn-C (MoorDyn-formulation deck) | pitch `e_T` 2 %; `e_rms` 3 % vs MoorDyn-C |
| V-SPW | Squat spar (d 10 m, draft 20 m, GM 0.41 m): waterplane-term check | pitch 2 deg, 300 s | analytic; MoorDyn-C (MoorDyn-formulation deck) | pitch `e_T` 1 % vs the exact second moment; pitch `e_T` 1 % vs MoorDyn-C |
| V-P1a-c | Dry rod pendulum pinned at End A | 10, 60, 120 deg | analytic (elliptic integral); MoorDyn-C cross-check | `e_T` 0.1 % at h = T/100; angle `e_rms` 1 % |
| V-S1m | Three IEA-15MW VolturnUS-S chains (200 segments) from three turbines to one shared anchor | held; T1 at +10 m; T1 surge 5 m/100 s + heave 2 m/12 s, 300 s | MoorDyn-C (coupled fairleads, coupled every time step) | static symmetry 1e-6, tensions 0.5 %; FairTen and anchor `e_rms*` 2 % |
| V-M1 | Mixed topology (BodiesAndRods style): Free body with a fixed rod and a pinned rod (tether on its End B), three taut legs, a finite-EI cable (EI 1e4 N m²) | surge 3 m, 60 s | MoorDyn-C (pinned-rod tether twin) | body surge/heave/pitch, pinned-rod end, FairTen `e_rms` 5 %; cable static tension 0.5 %; decay ratio 0.5 |
| V-M2 | V-M1 plus a chain through two Free points (buoy, clump); a rest deck adds a free rod | surge 3 m, 60 s; rest 20 s | MoorDyn-C (same twin) | V-M1 limits plus Free-point `e_rms` 5 %; rest drift 5 mm (body), 1 mm (rods) |

Both codes use the same line segmentation: 80 per buoy leg (V-D1a; 320 on V-D1b), 64/80 per spar leg (V-D2,
V-R3; 128/160 on V-D2c, 256/320 on V-D2a) and 200 per chain (V-S1m), so that line
discretisation stays out of the comparisons.
The releases (V-D1, V-D2, V-R3) start from each code's static line equilibrium about the held
body. `FairTen`/`AnchTen` in CableDyn and `TenA`/`TenB` in the MoorDyn-C series are the same
quantity: the magnitude of the force the line exerts on its end point (end-segment tension plus
the end node's weight, buoyancy, drag and seabed load, without the end node's inertia).

Metric definitions: `e_rms` is the RMS difference over the
largest reference excursion from its final value, `e_rms*` is the RMS difference over the
reference standard deviation, `e_T` compares periods from upward zero crossings, and `e_pk`
compares the first extreme after release, measured from the late-time mean. The code is in
`validation/scripts/bodies_metrics.py`. `e_rms` and `e_rms*` compare the two series at the
reference's own sample times (CableDyn interpolated onto them), so a coarse reference's
interpolation error on sharp events is not scored as a CableDyn difference.

## Layout

```text
cases.json                  case matrix: reference runs, scored channels, metrics, pass limits
cases/<ID>/cabledyn*.dat    CableDyn decks (target dialect: MoorDyn v2 rows, 7-column ROD TYPES
                            with CdEnd/CaEnd, 14-column BODY rows, R<N>A/B line ends, TURBINES)
cases/<ID>/moordyn*.txt     MoorDyn-C twins; *_mdc.txt are MoorDyn-C host motions
references/<ID>/<code>.*    reference series (CSV, gzip when large) + provenance JSON
```

Decks that compare with MoorDyn switch CableDyn's extensions to the MoorDyn formulations
(`bodyWetting moordyn`, `bodyHydro moordyn`, `rodHydro moordyn`); `cabledyn.dat` of the
surface spars keeps the default hydrostatics and is scored against the analytic solution.

The MoorDyn-C 2.7.1 twins are set up to account for the following observed differences, so
that both codes model the same physical system. Each is reproducible from the twin decks.

* **Rod initial orientation.** A free or pinned rod's initial orientation, and the initial
  shape of lines attached to it, are built from End B's position vector. Twins put End B on
  the ray from the origin through End A (the free spar has End A on top and moves its anchors
  instead of the rod).
* **Body drag-area entries.** MoorDyn-C 2.7.1 reads a 3- or 6-entry bar list for a body `CdA`
  from its second entry, so twins give 1 or 2 entries.
* **Rod waterplane moment.** The rod waterplane moment applies with End A below the surface,
  so the surface spars have End A at the bottom.
* **Free-rod rotational terms.** A free rod's equations (reference End A) do not include the
  centripetal and gyroscopic terms, which matter in releases with large rotation. The
  free-spar twins (`moordyn.txt`) therefore fix the rod to a massless Free body at its centre,
  whose equations include them; the plain free-rod twin is kept as `moordyn_freerod.txt`. On
  V-D2c the two MoorDyn-C forms give a first bottom-end extreme of -3.58 m and -4.17 m for the
  same physical system.

Further observations behind these choices:

* **Waterplane moment.** A cylinder's hydrostatic pitch stiffness from the exact waterplane
  second moment uses `pi d^4/64`. MoorDyn-C adds `(pi d^4/16) rho g sin(phi) cos(phi)` and
  applies the submerged end-cap pressure moment with the opposite sign; the net stiffness is
  the exact one plus `rho g pi d^4/32`. On V-SPW MoorDyn-C's pitch period is 12.97 s against
  the exact 20.54 s and 12.95 s predicted for the `+pi d^4/32` term. The spars are therefore
  scored against the analytic solution, with a MoorDyn-formulation deck (`rodHydro moordyn`)
  for the MoorDyn-C comparison.
* **Release initial condition.** `MoorDyn_Init_NoIC` starts the lines from MoorDyn-C's
  quasi-static catenary seed, which is not in equilibrium for a slack or seabed-touching line:
  V-D1b line 1 starts at 3179 N against the 3320 N equilibrium, and V-D2c line 1 at 941 N
  against 697 N (CableDyn: 3324 N and 697 N). The `--settle` option of the MoorDyn-C driver
  program (`bodies_mdc_runner.cpp`) starts the lines (and the Free points and free or pinned
  rods) from MoorDyn-C's own dynamic-relaxation equilibrium about the held bodies instead.
* **Coupling step.** MoorDyn-C moves a coupled point linearly with the velocity given at the
  start of each coupling step. The velocity change `a*cdt` over a step at a fairlead produces
  a mesh-independent tension difference `sqrt(EA m) a cdt`; on V-S1m at `cdt = 0.01 s` this is
  2.7 % of the heave tension amplitude, in phase with the heave acceleration and confined to the
  first few segments. V-S1m therefore couples at every MoorDyn-C time step.
* **V-D2a line mesh.** In the first seconds of the dx release the side legs nearly go slack
  (230 N at t = 0.6 s) and snap taut. At 64/80 segments the two codes' line mass
  discretisations (CableDyn consistent, MoorDyn-C lumped) differ by up to 3 % there
  (`endA` 2.7 %, FairTen3/4 2.8 %), and each code is up to 2.5 % from its own 4x-refined
  solution; the difference is not static (both codes end at the same equilibrium, a rigid shift)
  and does not depend on the time step, `rho_inf`, rod drag, added mass or seabed. At 256/320
  segments the codes agree within 0.9 % on every channel, so V-D2a uses that mesh.
* **Pinned rods on a body.** MoorDyn-C adds every rod attached to a body, pinned or not, to the
  body's equations with its full force, moment and 6x6 mass (`Body::doRHS`,
  `Rod::getNetForceAndMass`): a `Body<N>Pinned` rod passes its moment about the pin and its
  rotational inertia to the body, and its own rotation equation drops the pin acceleration
  (`Rod::getStateDeriv`). The V-M twins (`pinned_rod_twin`) carry each pinned rod on a massless
  Free body at its centre, hung from the parent by a 1 mm, EA 1e9 N tether that transmits the
  pin force and no moment; the plain `Body1Pinned` twin is kept as `moordyn_bodypinned.txt`.
  CableDyn's `Body1Pinned` rod and the tether twin agree within 0.02 % (rod end) and 0.5 %
  (body pitch) on V-M1 without the chain.
* **Free points in a moving chain (V-M2).** The chain runs through two `Free` points, which
  the monolithic implicit step solves together with their lines and the body; V-M2 agrees
  within 0.13 % (Free point) and 0.02-0.64 % (body).
* **Slack-taut line resolution.** The V-D2c snap needs four times the deck's line segments:
  the first extreme moves from -4.17 m (16/20 segments) to -4.44, -4.54 and -4.58 m, a
  Richardson limit near -4.59 m. The V-D2 and V-R3 cases use 64/80 segments in both codes.
  The tension of V-D2c's snap-loaded slack leg needs twice that: MoorDyn-C's own FairTen1
  moves by 11 % (`e_rms`) between 64/80 and 128/160 segments, and at 64/80 the codes differ by
  6-10 % depending on CableDyn's `dtM`; at 128/160 they agree within 2.2-3.7 % from `dtM`
  0.0005 to 0.002 s, so V-D2c uses that mesh.
* **V-D1b slack-snap leg (OrcaFlex cross-check).** At the deck's 80 segments CableDyn's FairTen1
  is 0.6-0.7 % (`e_rms`) from MoorDyn-C, and MoorDyn-C moves by 1.4 % (80 to 160) and 0.8 %
  (160 to 320) under its own refinement. `validation/scripts/orcaflex_vd1b_reference.py`
  builds the case in OrcaFlex 11.6d as a third code (320 segments, implicit dt 0.25 ms;
  committed as summary values in `references/V-D1b/orcaflex.json`, the series itself is not
  redistributed). Its held-body tensions equal MoorDyn-C's (3329 N,
  793.2 kN) once the seabed is placed OD/2 below 100 m and the anchors are fixed at
  z = -100 m: OrcaFlex takes contact at the line surface and puts an anchored end OD/2
  above the seabed, which shortens the taut legs and drops their tension by 4 %. Against it
  (t = 0.5-120 s, 0.01 s grid), FairTen1 differs by 1.6/1.2/0.54 % for CableDyn and
  2.4/1.2/0.77 % for MoorDyn-C at 80/160/320 segments, and
  both codes converge towards the same answer: at 320 segments (CableDyn `dtM` 1 ms) they
  agree within 0.25 %. The snaps set the difference. At 320 segments, MoorDyn-C's snap peaks
  at 1.9 s and 3.3 s are 20 % and 8 % below CableDyn and OrcaFlex, which agree with each other
  within 4 %.
  The difference is line-mesh discretisation, not a convention difference. The
  tangential drag area (pi d in all three codes; L3-6a), the added mass on slack segments,
  the end-node lumping and the seabed damping (dropping `cBot` moves FairTen1 by 0.25 %) do
  not explain it. OrcaFlex is used as a cross-check rather than the pass/fail reference, because
  at this snap-loaded slack leg all three codes, OrcaFlex included, settle only to about 0.5 %
  at 320 segments, and the OrcaFlex series has a short slack-leg release transient at
  t = 0.17-0.24 s that changes with refinement (29-126 kN; 1-3 kN in the other codes), so
  comparisons start at t = 0.5 s. The `of_*` metrics of V-D1b score a run against the OrcaFlex
  summary values over t = 0.5-120 s: surge period, minimum and standard deviation, heave
  standard deviation, FairTen1-2 mean, standard deviation, maximum and dominant harmonic
  (about 0.92 Hz), and the FairTen1 snap maxima at 1.95 s and 2.59 s. At 320 segments CableDyn
  is within 0.001-3.5 % of OrcaFlex on these; a run with 12.5 % more body drag area fails
  eight of them and one with 5 % lower line EA fails twelve.
  The 0.5 % limit stays; V-D1b uses 320 segments in both codes, as V-D2a and V-D2c do
  (MoorDyn-C rk4 at 12.5 µs, 7e-7 from 25 µs). At 320 segments CableDyn's FairTen1 is 0.51,
  0.25, 0.36 and 0.58 % from MoorDyn-C at `dtM` 2.5, 1, 0.5 and 0.25 ms, and the CableDyn
  levels differ from each other by 0.4-0.6 %: the snap tension does not converge in `dtM`
  below the limit, as OrcaFlex's does not converge below about 0.5 % in dt and mesh. The deck
  keeps `dtM` 1 ms; the pass/fail result at 320 segments depends on `dtM`. The cause is the
  segment-scale axial content the snaps excite (up to about 2c/l, 13,000-23,000 rad/s at 320
  segments): generalised-alpha reaches its second-order range only for `dtM` below about
  30 µs there. Line 1 alone with its fairlead prescribed shows the same behaviour and
  converges at order 1.7 at 80 segments once `dtM` reaches 0.125 ms. Newton tolerance, the
  body coupling, seabed contact, numerical damping and mass lumping were ruled out, and
  event sub-stepping at the slack-taut switch does not remove it. See the snap-load guidance
  in `doc/modeling.rst`.

## Regenerating the references

Requirements: Python with NumPy and SciPy, a MoorDyn-C source tree and its CMake build
(`libmoordyn.dll`/`.so`), and g++.

```text
python validation/scripts/bodies_cases.py          # decks + cases.json
python validation/scripts/bodies_analytic.py       # analytic references
set CD_MDC_SRC=<MoorDyn source>  CD_MDC_BUILD=<its build tree>  CD_BODIES_WORK=<scratch>
python validation/scripts/bodies_run_moordyn_c.py [ID ...]
python validation/scripts/orcaflex_vd1b_reference.py ref --nseg 320 --dt 0.00025 --out <dir>
```

The OrcaFlex twin of V-D1b needs an OrcaFlex licence and OrcFxAPI; it writes the summary values
into `references/V-D1b/orcaflex.json` and keeps the full series in `<dir>`.

`bodies_run_moordyn_c.py` compiles `bodies_mdc_runner.cpp` against the library, runs each
deck at every `dt_levels` entry with rk4, and stores the finest level. The provenance JSON
records the MoorDyn-C tag, commit and library hash, the scheme, the initialisation
(`MoorDyn_Init_NoIC` with the lines settled about the held bodies for releases), the coupling
step, the `e_rms` of every level against the finest one, and the
t = 0 rod-end positions against the deck.

## Scoring a CableDyn run

V-S1m reads the turbine motion record `cases/V-S1m/motion_turbines.txt`, which is not stored in
the repository; write it (with every case deck and `cases.json`) first:

```text
python validation/scripts/bodies_cases.py
```

Then run each case's `cabledyn.dat` (and `cabledyn_static*.dat` for V-S1m) with the output root
named after the case, and collect the main `.out` files in one directory as `<ID>.out` or
`<ID>/cabledyn.out`; the MoorDyn-formulation runs `cabledyn_mdparity.dat` of the surface spars go
in as `<ID>_mdparity.out` or `<ID>/cabledyn_mdparity.out`. The driver does not create folders,
so make the output directory first (for example `mkdir -p <outdir>`). Then:

```text
python validation/scripts/bodies_score.py <outdir> [ID ...] [--json scores.json]
```

The script prints each metric with its limit and exits with status 1 when a metric fails. Metrics
whose channel is not written yet are listed as not evaluated.
