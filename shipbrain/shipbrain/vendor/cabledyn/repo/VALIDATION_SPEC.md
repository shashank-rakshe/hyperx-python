<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn validation specification

This file maps the L1 analytical case identifiers used in
[VALIDATION.md](VALIDATION.md) to their CTest names and acceptance rules. The test
programs are the authority for the numerical limits.

## L1 analytical cases

| ID | CTest name | Scope | Acceptance |
| --- | --- | --- | --- |
| L1-1 | `l1_axial_patch` | `EI = 0` axial patch test against `EA * strain` | Relative force error below `1.0e-10` |
| L1-2 | `l1_bending_patch` | Hermite finite-EI bending/axial patch against constant-stretch and constant-curvature solutions | Axial energy relative error below `1.0e-12`; finest-mesh bending-energy relative error below `1.0e-6`; bending-energy convergence order at least `3.5` |
| L1-3 | `l1_cantilever` | Hermite cantilever static deflection against Euler-Bernoulli theory | Tip-deflection relative error below `1.0e-3` |
| L1-4 | `l1_large_deflection` | Hermite large-deflection elastica | Tip-position errors below `1.0e-3` against the planar elastica |
| L1-5 | `l1_string` | `EI = 0` transverse string period against the analytical first mode | Period relative error below `1.0e-3` |
| L1-6 | `l1_euler_beam` | Hermite beam vibration against the Euler-Bernoulli first bending mode | Frequency relative error below `1.0e-3` |
| L1-7 | `l1_catenary` | Static `EI = 0` catenary against the inextensible analytical catenary | Normalised position L2 error below `1.0e-3` |
| L1-8 | `l1_energy_stability` | Dynamic energy stability of the finite-EI Hermite beam | For `rho_inf = 0.8`, every per-period peak stays below `E0 * (1 + 1.0e-6)` and the last-five-period mean does not exceed the first-five-period mean by more than `1.0e-9`; for `rho_inf = 1.0`, the 10-period energy band is below `5.0e-3 * E0` |
| L1-9 | `l1_seabed` | Seabed reaction profile and `EI = 0` small-EI-limit consistency | Reaction-profile L2 error below `1.0e-3` |
| L1-10 | `l1_convergence_order` | Hermite static convergence order under mesh refinement | Finest-interval order at least `3.5` |

```bash
ctest --test-dir build -L l1 --output-on-failure
```

## WaterKin and SeaState tests

The `hydro`, `deck_driver`, `openfast_aggregate`, and `openfast_shell` tests cover
the seven wave/current mode combinations listed in VALIDATION.md, the CurrMod-1
steady-current formula, rejection of unsupported user currents, and the
WaveKinMod-1 record handling (a contaminated record longer than `TMax`, an exact
final sample, implicit versus explicit zero padding, a shared padded time base, and
host-supplied `TMax` when the deck omits it). `src/openfast/CableDyn_OF.f90` is not
built by this repository's CMake; a release also requires it to compile against
the supported OpenFAST SeaState API (see [RELEASE.md](RELEASE.md)).

## Release rule

A release candidate must pass all L1 cases and the full Fortran suite:

```bash
ctest --test-dir build -L fortran --output-on-failure
```
