<!-- SPDX-License-Identifier: Apache-2.0 -->

# Wall time at equal accuracy: CableDyn 0.1.0, MoorDyn-C and MoorDyn-F

This page is for users who want to know how long CableDyn 0.1.0 takes on typical mooring and
cable problems. It compares CableDyn with MoorDyn-C and MoorDyn-F on the same host. Each code
runs at the cheapest mesh and time step that reproduce its own converged solution to within 1 %.

The timings are specific to these five cases, this host and these settings. The codes have
different design goals. MoorDyn's explicit lumped-mass scheme is inexpensive per step and very
robust. CableDyn's implicit scheme costs more per step but can take larger steps. Which is
faster overall depends on the step each scheme needs for the required accuracy, and so on the
problem and on the accuracy criterion.

MoorDyn (Hall et al.) and OpenFAST, maintained by NLR (National Laboratory of the Rockies,
formerly NREL), are open-source codes. This comparison and CableDyn's coupling to OpenFAST both
build directly on them, and we thank their developers.

## Codes and host

| Code | Build | Time integration and initial condition |
| --- | --- | --- |
| CableDyn 0.1.0 | release `CableDyn_driver.exe` and `openfast.exe` (IFX 2025.3.2, `/Qipo`, static runtime, reference LAPACK 3.12.1) | implicit generalised-α with Newton iterations, default settings; Newton static equilibrium |
| MoorDyn-C 2.7.1 | MSVC 19.44, CMake `Release`, driven through its C API; the coupled points are updated every 0.01 s (0.005 s in case B) | explicit RK2 (RK4 in case B); dynamic relaxation |
| MoorDyn-F v2.3.8 | `moordyn_driver` from OpenFAST `dev` (`0b1979810`, 25 September 2026), IFX 2025.3.2, `Release`, double precision; coupled points sampled as for MoorDyn-C | as MoorDyn-C |
| MoorDyn-F v2.3.8 in OpenFAST | the release `openfast.exe`, `CompMooring = 3` | RK2; dynamic relaxation |

All runs used one performance core of an Intel Core i9-13900K at high priority on an otherwise
idle machine.

## Cases

| Case | Model | Loading | Simulated (scored) |
| --- | --- | --- | --- |
| A1 | IEA-15MW VolturnUS-S mooring: three 850 m R4 chains in 200 m of water | platform surge 4 m / 60 s plus 1.5 m / 12 s, and heave 1.5 m / 12 s, in still water | 300 s (60–299 s) |
| A2 | as A1 | the A1 motion plus a JONSWAP sea with Hs 6 m, Tp 12 s and 80 components | 300 s (60–299 s) |
| B | Lozon et al. (2025) Gulf of Mexico 80 m lazy-wave power cable, 170 m long, with a buoyancy section and touchdown | hang-off heave of 3 m / 12 s | 96 s (24–96 s) |
| C | `Rigid6` buoy of 20 t on three taut polyester legs in 100 m of water | release from a 0.5 m surge offset | 120 s (0.5–119.5 s) |
| D | the complete OpenFAST IEA-15MW VolturnUS-S model without wind; `CompMooring = 5` and `= 3` with the shipped decks (50 segments per line) and a glue step of 0.025 s | JONSWAP sea with Hs 6 m and Tp 12 s | 300 s (60–300 s) |

## Protocol

- **Reference.** Each code's reference is its own finest mesh at its smallest time step. Every
  reference differs by at most 0.23 % from the next-coarser mesh and, where that step is
  stable, from the next-larger time step.
- **Accuracy criterion.** A configuration passes when, on every scored fairlead tension, the
  standard deviation and the peak excursion (maximum minus reference mean) are within 1 % of the
  code's own reference. In case B the peak dynamic curvature must also be within 1 %. The peak
  curvature is taken over all interior nodes and over the scoring window. End nodes are left
  out because curvature is not defined at a pinned end, where MoorDyn-F writes a placeholder
  value.
- **Robust selection.** A time step passes only if every smaller step tried on the same mesh also
  passes. A mesh passes only if every finer mesh has a passing step. In case B, CableDyn meshes
  below 48 elements are excluded because its tensile monitor records axial compression there,
  which the shipped deck (`tensile_safety True`) rejects.
- **Search.** The meshes are refined by factors of about two. On each mesh the time step is
  reduced from values at which the code misses the criterion or does not run to completion.
- **Timing.** The time is the wall time of the whole process: input, initial condition,
  simulation and output. It is the median of three runs after one warm-up. Runs longer than a
  minute have no warm-up.
- **Same model in every code.** The line properties, hydrodynamic coefficients, seabed contact,
  prescribed motion and wave components are the same in all three codes.
  - In MoorDyn, `BA < 0` sets a damping ratio per segment, so the axial damping would change with
    the mesh. Cases A, B and C therefore use a fixed axial damping of 2.5×10⁷, 2.0×10⁵ and
    3.0×10⁴ N·s. These values are critically damped at the shipped meshes.
  - The prescribed motions start with a 12 s smooth ramp.
  - In case C the legs start from each code's equilibrium about the held buoy. CableDyn uses its
    static solution, MoorDyn-C 60 s of dynamic relaxation, and MoorDyn-F its quasi-static
    catenary, because its dynamic relaxation would also move the free buoy.

### Setting choices

- **Waves in case A2.**
  - CableDyn evaluates the wave components at the nodes.
  - MoorDyn-C uses its FFT wave grid (`WaveKin 2`) and MoorDyn-F its elevation-record grid
    (`WaveKinMod 1`). Both grids have 5 m spacing and 21 levels.
  - MoorDyn-C's grid mode applies each component with a cosine and its node-by-node mode
    (`WaveKin 7`) with a sine, so each mode was given matching phases to represent the same sea.
    The node-by-node mode gave the same tension statistics to 0.01 % in 130 s instead of 4.2 s.
- **MoorDyn initial condition in case B.** The MoorDyn references use `threshIC = 1e-5`.
  `threshIC = 1e-3` gave the same accuracy at the selected configurations, and the faster of the
  two settings is reported.
- **CableDyn settings.** Case B uses the dynamic-solver tolerance of `1e-4` from the shipped
  Lozon decks. Every other CableDyn setting is the default.
- **Coupled case D.** Only the mooring time step varies. Both codes apply the SeaState wave
  kinematics to the lines.

## Results

Mesh is in elements (CableDyn) or segments (MoorDyn) per line. The errors are the largest over
the scored lines, relative to the code's own reference. The wall time is the median of three
runs, with their range.

| Case | Code | Mesh | Step | Tension std error | Peak error | Curvature error | Wall time |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| A1 | CableDyn | 50 | 0.05 s | 0.79 % | 0.75 % | — | 2.17 s (2.17–2.18) |
| A1 | MoorDyn-C | 200 | 0.2 ms | 0.04 % | 0.12 % | — | 93.2 s (93.2–93.9) |
| A1 | MoorDyn-F | 200 | 0.2 ms | 0.03 % | 0.07 % | — | 245.3 s (242.4–364.5) |
| A2 | CableDyn | 50 | 0.2 s | 0.64 % | 0.93 % | — | 1.64 s (1.59–1.65) |
| A2 | MoorDyn-C | 200 | 0.2 ms | 0.04 % | 0.23 % | — | 605 s (289–648) ¹ |
| A2 | MoorDyn-F | 50 | 5 ms | 0.33 % | 0.88 % | — | 9.26 s (9.18–9.85) |
| B | CableDyn | 48 | 0.1 s | 0.42 % | 0.10 % | 0.95 % | 0.31 s (0.31–0.31) |
| B | MoorDyn-C | 68 | 0.8 ms | 0.18 % | 0.15 % | 0.34 % | 6.86 s (6.85–6.86) |
| B | MoorDyn-F | 68 | 0.8 ms | 0.19 % | 0.14 % | 0.34 % | 8.80 s (8.36–8.82) ² |
| C | CableDyn | 20 | 0.1 s | 0.30 % | 0.56 % | — | 0.72 s (0.72–0.72) |
| C | MoorDyn-C | 40 | 1 ms | 0.56 % | 0.14 % | — | 2.60 s (2.58–2.61) |
| C | MoorDyn-F | 40 | 1 ms | 0.56 % | 0.14 % | — | 4.25 s (4.22–4.26) |
| D | CableDyn in `openfast.exe` | 50 | 0.2 s | 0.37 % | 0.83 % | — | 12.2 s (12.2–12.4) |
| D | MoorDyn-F in `openfast.exe` | 50 | 6.25 ms | 0.20 % | 0.12 % | — | 36.3 s (35.9–41.5) |

¹ The run times of this configuration fall into two groups, near 290 s and near 600 s. On the
previous day the three runs took 291, 306 and 589 s.
² With `threshIC = 1e-3`; with `1e-5` the median is 27.4 s.

### Sensitivity to the accuracy target

Several configurations lie close to the 1 % criterion. In cases A1 and A2, MoorDyn with 50
segments misses by a small margin: the MoorDyn-C peak errors are 1.87 % and 1.11 %. It therefore
needs 200 segments and a 0.2 ms step. With a 2 % criterion the selections and wall
times are:

| Case, 2 % target | CableDyn | MoorDyn-C | MoorDyn-F |
| --- | ---: | ---: | ---: |
| A1 | 0.94 s (50, 0.2 s) | 1.33 s (50, 5 ms) | 4.12 s (50, 5 ms) |
| A2 | 1.64 s (50, 0.2 s) | 4.08 s (50, 5 ms) | 9.26 s (50, 5 ms) |
| B | 0.24 s (48, 0.4 s) | 1.77 s (34, 1 ms) ² | 3.91 s (34, 1 ms) ² |
| C | 0.40 s (10, 0.1 s) | 2.60 s (40, 1 ms) | 4.25 s (40, 1 ms) |
| D | 12.2 s (0.2 s) | — | 36.3 s (6.25 ms) |

## Notes

- **Where MoorDyn is faster.**
  - Per step, MoorDyn is much cheaper. In case A1 at 50 segments, a MoorDyn-C step takes about
    20 µs and a CableDyn step about 360 µs.
  - Where a problem needs a small time step anyway, the explicit scheme is the faster choice. An
    example is the short tension-only chain under snap loading in
    [`VALIDATION.md`](../VALIDATION.md), which MoorDyn-C runs in about 0.03 s and CableDyn in
    about 0.26 s.
  - With the 2 % criterion in case A1, the two codes are within 0.4 s of each other.
- **Time step.** In these cases the differences come from the time step each scheme needs.
  CableDyn's step is limited by accuracy: in case D a step of 0.2 s meets the criterion and
  0.4 s does not. MoorDyn's explicit step is limited by stability: in case D 6.25 ms is the
  largest step that ran to completion.
- **Curvature in case B.** MoorDyn's node-angle curvature converges well on this cable. The peak
  dynamic curvature is within 1.3 % of the reference at 34 segments and 0.34 % at 68 segments.
  The criterion is met from 68 segments.
- **Coupled times include OpenFAST.** In case D both totals include ElastoDyn, HydroDyn and
  SeaState.
- **Agreement between the codes.** In tension standard deviation, the references of the three
  codes agree to within 1.8 % in cases A, C and D and to within 6 % in case B. In case B their
  peak dynamic curvatures, 0.1033 m⁻¹, agree to 0.04 %.

## Reproduce

The measurements were made in September 2026 with the builds listed under "Codes and host";
their file hashes were not recorded with the timings.

The coupled case D uses the files in [`examples/openfast`](../examples/openfast/README.md) with
the pose reset described there. Cases A–C are built from shipped models: A1 and A2 from the
mooring of `examples/openfast/CableDyn_UMaine.dat` with prescribed platform motion, B from
`examples/lozon_gomex80_power_cable_motion.dat`, and C from the bodies case V-D1a
(`validation/bodies/cases/V-D1a/`). The mesh and time-step variants of cases A–C, and the
reduced form of [`validation/scripts/bodies_mdc_runner.cpp`](scripts/bodies_mdc_runner.cpp)
that drives MoorDyn-C in them, are not included in the repository; the settings above define
them.
