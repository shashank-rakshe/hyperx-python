<!-- SPDX-License-Identifier: Apache-2.0 -->

# Same-host wall-clock records (L5)

This directory records the same-host wall-clock measurements behind the L5 rows of
[`VALIDATION.md`](../../VALIDATION.md): the matched lazy-wave spans (L5-DPC), the one-hour
VolturnUS-S mooring (L5-V) and the tension-only chain (L5-wc). Every figure comes from
[`validation/scripts/performance_records.py`](../scripts/performance_records.py), which builds the
models, runs and times each code and writes the files below.

| File | Contents |
| --- | --- |
| `performance_summary.csv` | L5-DPC: per span, code and build, the mesh, time step, wall and CPU times, memory and solver counts |
| `wallclock_summary.csv` | L5-V and L5-wc in the same columns |
| `performance_metrics.json` | The same rows, the code versions and builds, the host, the date, the responses each timed model reproduced, the MoorDyn-F step checks and the CableDyn driver notes |
| [`PERFORMANCE_AUDIT.md`](PERFORMANCE_AUDIT.md) | Wall times with their ranges, and the timing definitions |
| [`ORCAFLEX_MESH_CONVERGENCE.md`](ORCAFLEX_MESH_CONVERGENCE.md) | 800 m OrcaFlex segment-length study; data in `orcaflex_mesh_convergence.csv` |

## Cases

- **L5-DPC.** The matched 80, 200 and 800 m suspended spans of the L3-6 protocol: hang-off at
  (0, 0, −14) m heaved 3 sin(2πt/12) m, touchdown pinned at the static touchdown point, no
  seabed in reach, still water, Cdn 1.2, Cdt 0.1, Can 1.0, Cat 0; static initialisation and
  60 s of dynamics.
  - CableDyn: driver decks with 240, 480 and 960 cubic-Hermite elements, aligned with the
    sections, dt 0.05 s, the default solver settings with the Newton tolerance `1e-4` of the
    shipped Lozon decks. The hang-off motion starts at full velocity, as in the L3-6 gate.
  - OrcaFlex: the models of `orcaflex_lazywave_dynamic_reference.py`, 0.75 m segments (179, 350
    and 1227 segments; [`ORCAFLEX_MESH_CONVERGENCE.md`](ORCAFLEX_MESH_CONVERGENCE.md)), implicit
    dt 0.05 s, a 12 s build-up and 48 s.
  - MoorDyn-F: the decks of `moordyn_lazywave_dynamic_reference.py` with the native meshes
    refined fourfold (208, 224 and 232 segments), RK4, dtM 0.125 ms at 80 and 200 m and 0.5 ms
    at 800 m, its dynamic-relaxation initialisation (`threshIC` 1e-5, `TmaxIC` 900 s) and
    61.5 s of dynamics. These steps are the largest at which halving the step moves every
    scored response by less than 0.01 %; the tool re-checks this with `--step-check`
    (`moordyn_f_step_checks` in the JSON). The resolved bending modes of the contact-free
    cable, not seabed stiffness, set this explicit step.
- **L5-V.** One IEA-15MW VolturnUS-S chain (850 m, 50 elements or segments, 200 m water) with
  the fairlead driven for one hour by 5 sin(2πt/90) m of surge and 2 sin(2πt/12) m of heave.
  CableDyn runs `examples/iea15mw_volturnus_mooring.dat` with the drive of the
  `l3_longduration_mooring` gate (a 100 s half-cosine ramp, dt 0.1 s, 3600 s, no seabed
  damping) as a motion file; OrcaFlex runs the model of `orcaflex_longduration_mooring.py`
  (implicit dt 0.1 s, 200 s build-up and 3600 s).
- **L5-wc.** The WD0050 grounded chain of `examples/wd0050_chain.dat` (410 m, 41 elements or
  segments, 50 m water) under the L2-2 A1 fairlead heave 2 sin(2πt/10) m for 80 s: the 60 s
  warm-up and the 20 s scored window of `l2_2_dynamic_parity`. CableDyn runs the deck at
  dt 0.05 s. MoorDyn-C runs the same chain through `moordyn_c_driver.cpp` (explicit RK2,
  dtM 1 ms, coupling step 0.1 s, its dynamic-relaxation initialisation).

Before a model is recorded, the tool checks its response against the reference: on L5-DPC the
hang-off tension mean, minimum and maximum over 24–60 s against the OrcaFlex values of the
L3-6 gate (within 2 %), and on L5-V the fairlead tension statistics over 200–3600 s against the
OrcaFlex values of the L3-7 gate (within that gate's bands). The responses are in
`performance_metrics.json`.

## Protocol

- One thread: `OMP_NUM_THREADS = OPENBLAS_NUM_THREADS = 1`, and OrcaFlex `threadCount = 1`.
- Each process at high priority; one warm-up run, then three timed runs. The median and the
  range are recorded.
- CableDyn, MoorDyn-F and MoorDyn-C: the wall time of the whole process (input, initial
  condition, dynamics and output). OrcaFlex: `CalculateStatics` plus `RunSimulation`, in a
  fresh Python process for each run.
- CableDyn's static and dynamic split and its solver counts come from one further run with
  `CABLEDYN_PROFILE`. `newton_per_step` is the linear solves per step for the finite-EI spans
  and the Newton iterations per line step for the chains. MoorDyn-C's dynamic time is the
  stepping loop timed by its driver.
- `host_busy_median` is the busy fraction of all host processors during the timed runs. Other
  work was running on the host; the ranges show its effect.

## Provenance

Measured on an AMD Ryzen Threadripper PRO 7965WX (24 cores), Windows 11 Pro: OrcaFlex, MoorDyn-F and
MoorDyn-C on 2026-11-08, CableDyn 0.4.2 on 2026-11-09.

| Code | Build |
| --- | --- |
| CableDyn `ifx-release-0.4.2` | the v0.4.2 release `CableDyn_driver.exe` (IFX 2025.3.2, static, `/fp:precise /arch:CORE-AVX2 /Qfma-`, reference LAPACK 3.12.1) |
| CableDyn `gnu-release-0.4.2` | the v0.4.2 source (`release/0.4.2` at `25bdfc1`): GNU Fortran 16.2.0 (conda-forge), CMake `Release` (`-O3`), baseline x86-64, OpenBLAS 0.3.33 |
| OrcaFlex | OrcaFlex 11.6d (OrcFxAPI DLL 11.6d) from Python, `threadCount = 1` |
| MoorDyn-F | MoorDyn v2.3.8 in the OpenFAST v5.0.0 MoorDyn driver: GNU Fortran 16.2.0, CMake `Release` (`-O3`), `DOUBLE_PRECISION=OFF` |
| MoorDyn-C | v2.7.2 release source: `libmoordyn` by GNU g++ 16.2.0, CMake `Release` (`-O3`); `moordyn_c_driver.cpp` by `g++ -O2` |

The JSON records the driver hashes. The earlier L5-wc figure used MoorDyn-C v2.6.1 through the
same driver (the trace committed in `tests/data/l2_2_external_refs`). Its deck settings were not
recorded, so v2.7.2 runs the deck written by `performance_models.py`; over the scored window it
differs from the committed v2.6.1 trace by 0.37 % in mean and 1.19 % in maximum tension.

## Reproduce

From the repository root, with numpy, the OrcFxAPI Python interface on `PYTHONPATH`, the
OpenFAST MoorDyn driver and a MoorDyn-C build:

```text
python validation/scripts/performance_records.py run --codes cabledyn \
    --cabledyn-driver <CableDyn_driver.exe> --cabledyn-label <label> --cabledyn-build "<text>"
python validation/scripts/performance_records.py run --cases dpc v --codes orcaflex
python validation/scripts/performance_records.py run --cases dpc --codes moordyn-f --step-check \
    --moordyn-f-driver <moordyn_driver.exe> --moordyn-f-build "<text>"
python validation/scripts/performance_records.py run --cases wc --codes moordyn-c \
    --mdc-src <MoorDyn source> --mdc-build <MoorDyn build> --gxx <g++> --moordyn-c-build "<text>"
python validation/scripts/performance_records.py write
```

The results accumulate in `build/performance/results.json`; `write` regenerates the three
record files. The figures apply to this host, these models and these settings.
