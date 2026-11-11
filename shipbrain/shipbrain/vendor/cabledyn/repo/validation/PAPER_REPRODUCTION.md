<!-- SPDX-License-Identifier: Apache-2.0 -->

# Reproduction of the journal article

This record is for readers of the CableDyn journal article (Seo et al., *Ocean Engineering*
368 (Part 2), 128332, 2026) who want to know whether the current release reproduces its numbers. The article
records the formulation as published. CableDyn keeps developing, and its defaults follow the
most accurate and robust methods available. The article's methods stay selectable. The table
lists every quantitative result in the article that CableDyn computes, re-run in two modes, first
with the v0.1.0 release and again with the development source at revision 71158d5; the table
gives the 71158d5 values.

| Mode | Settings |
| --- | --- |
| Paper mode | `False alpha_force_blend`: forces evaluated at the generalised-α blended configuration, as in the article. `sequenced cable_statics`: the mesh-sequenced static route runs first. `element OutputRecovery`: node tensions are element-mean axial forces and curvatures the geometric Hermite curvature, as in the article. End tensions are the end element's axial tension. |
| Defaults | Force-blended generalised-α (`True alpha_force_blend`). Static route starts from a catenary with continuation of the bending stiffness (`continuation cable_statics`). `FairTen`/`AnchTen` report the end force: the end element's force including axial damping, plus the end node's share of weight, seabed contact and drag at the actual velocity, without the end node's inertia. |

`alpha_force_blend` also selects the generalised-α scheme of tension-only (EI = 0) lines, so
moorings differ between the modes as well; `False alpha_force_blend` gives the article's EI = 0
scheme. In paper mode every EI = 0 and finite-EI result at 71158d5 equals the v0.1.0 one in every
printed digit, except the two-point axial rule row. Reference values from OrcaFlex, MoorDyn and
closed-form solutions are the fixed values used in the article; they were not re-run. The
source revision recorded in the article's provenance files, built with the same toolchain,
regenerates the article's data files exactly, so any difference in the paper-mode column comes
from a change in CableDyn itself.

**Outcome.** Of the 58 results, paper mode reproduces 53 within the article's printed
precision. Three differ because of later robustness fixes, one of them only in the last
printed digit. Two cannot be reproduced from the
recorded inputs, even with the article's own source: the 800 m pretension and the count of
subdivided mooring motions. With the defaults, 20 results change because of a changed
default. One robustness result is worse with the defaults; see
[Known difference](#known-difference). For moorings, the defaults column also shows the
end-force channel where the article reported the end element's tension. For the dynamic
mooring cases, the end force is evaluated on the same run from the documented `FairTen`
definition. All runs used the
article's full durations, including the one-hour mooring case.

Status codes in the notes: **R** reproduced; **D** changed by an intentional default (paper
mode reproduces); **F** changed by a robustness fix; **X** not reproducible from the recorded
inputs; **W** worse agreement or robustness with the defaults.

| Quantity | Paper | 71158d5, paper mode | 71158d5, defaults | Reference | Note |
| --- | --- | --- | --- | --- | --- |
| Axial patch force error | 1.10e-13 | 1.10e-13 | 1.10e-13 | closed form | R |
| Circular-arc energy convergence order | 4.00 | 4.00 | 4.00 | 4 | R |
| Distributed-load cantilever convergence order | 3.99 | 3.99 | 3.99 | 4 | R |
| End-moment cantilever displacement error | 5.90e-5 | 5.90e-5 | 5.90e-5 | closed form | R |
| Largest elastica tip-coordinate error | 1.86e-6 | 1.86e-6 | 1.86e-6 | Bisshopp–Drucker | R |
| String / beam period error | 4.11e-4 / 8.16e-5 | 4.11e-4 / 8.16e-5 | 4.11e-4 / 8.16e-5 | closed form | R |
| Catenary position / seabed reaction error | 2.10e-4 / 4.05e-4 | 2.10e-4 / 4.05e-4 | 2.10e-4 / 4.05e-4 | closed form | R |
| Energy band over ten periods, ρ∞ = 1 | 1.12e-8 | 1.12e-8 | 2.28e-8 | 0 | D: force blend; still non-growing at ρ∞ = 0.8 |
| Grounded-chain fairlead difference, 50/200/600 m | ≤ 0.51 % | 0.50 / 0.28 / 0.16 % | same; `FairTen` 1.41 / 0.31 / 0.09 % | MoorDyn-C quasi-static | R; `FairTen` adds the end node's weight share |
| Grounded-chain anchor difference | ≤ 1.59 % | 1.59 / 0.39 / 0.13 % | same; `AnchTen` 1.63 / 0.41 / 0.14 % | MoorDyn-C quasi-static | R |
| Heave variation measure, six cases, max | 0.116 (OrcaFlex), 0.142 (MoorDyn-C) | 0.116, 0.142 | same; end force 0.117, 0.142 | OrcaFlex, MoorDyn-C | R |
| Chain in 1 m/s current, end differences | 0.07–0.67 % | 0.07–0.67 % | same; `FairTen`/`AnchTen` 0.60–0.80 % | OrcaFlex end tension | R |
| 80 m pretension | 727.1 kN; 2.72 % and 3.86 % low | 727.1 kN | `FairTen` 742.7 kN | design 748, OrcaFlex 747.4, MoorDyn-F 756.3 kN | R; D for `FairTen`. The article's 2.72 % is relative to OrcaFlex (2.79 % relative to design) |
| 200 m pretension; four-way band | 1206.2 kN; 1.1 % | 1206.2 kN; 1.1 % | 1206.2 kN; example-deck `FairTen` 1205.4 kN | design 1205, OrcaFlex 1199.2, MoorDyn-F 1212.0 kN | R |
| 800 m pretension; three-solver spread; above design | 1868.8 kN; 0.7 %; ≈ 10 % | 1875.6 kN; 0.3 %; 10.1 % | `FairTen` 1881.5 kN; 0.3 %; 10.4 % | OrcaFlex 1881.5, MoorDyn-F 1875.9, design 1704 kN | X: the article's value came from an earlier, unrecorded mesh; the article's own source gives 1875.6 kN on the published deck; the conclusion is unchanged |
| Mooring equilibrium profiles (Fig. 9) | — | identical geometry and element tensions | end node reports the end force | — | R |
| One-hour VolturnUS-S mean / SD / min / max | 1.41 / 0.26 / 1.81 / 1.04 % | 1.41 / 0.26 / 1.81 / 1.04 % | 1.41 / 0.27 / 1.46 / 1.05 %; end force 0.27 / 0.26 / 0.50 / 0.43 % | OrcaFlex 2439.39 / 206.08 / 2057.86 / 2850.91 kN | D: force-blended EI = 0 step; the mean is unchanged |
| One-hour Fourier amplitude, 90 s / 12 s | 0.83 / 2.10 % | 0.83 / 2.10 % | same; end force 0.27 / 1.14 % | OrcaFlex 228.57 / 178.80 kN | R |
| Series-Kelvin cases | 12 recover stiffness; derivatives within 5e-6 | pass | pass | analytical, central differences | R |
| Series-Kelvin 0.30 MBL ramp differences | 0.121 / 0.053 / 0.026 / 0.009 / < 0.001 % | same | same | MoorDyn | R |
| Syrope residual, 14 cases | 0.70–1.16e-9 N | 0.70–1.16e-9 N | 0.70–1.16e-9 N | independent NumPy implementation | R |
| 80 m static peak curvature and position | 0.09683 /m at s̄ = 0.3412 | 0.09683 /m at 0.3412 | 0.09683 /m at 0.3412 | — | R |
| 80 m first grounded node; hang-off tension | 0.7967; 9.32 kN | 0.7967; 9.32 kN | 0.7967; 9.32 kN | — | R |
| Static continuous axial minima, 80/200/800 m | 1.28 / 1.39 / 3.73 kN | 1.28 / 1.39 / 3.73 kN | 1.28 / 1.39 / 3.73 kN | tensile | R |
| Static axial minimum over refinement | −25.33→1.28, −25.53→1.39, −4.69→3.73 kN | same | same | — | R |
| Static peak-curvature change over refinement | 0.09 / 0.68 / 0.06 % | 0.09 / 0.68 / 0.06 % | 0.09 / 0.68 / 0.06 % | — | R |
| 200 m cable on 238/357/476 elements | intended branch | intended branch | intended branch | — | R |
| 800 m cable solved directly on the final mesh | folded equilibria | mesh sequencing reaches the branch | continuation on the final mesh reaches the same branch | — | D: continuation-first static route |
| Equal-order quadrature curvature change | ≤ 0.0020 % | 0.0020 % | 0.0020 % | six-point rule | R |
| Three-point axial rule, negative minimum 80 / 800 m | 56.15 / 5.81 kN | 56.15 / 5.81 kN | 56.15 / 5.81 kN | — | R |
| Two-point axial rule | 937 / 820 kN; 800 m fails | −922.7 / −810.3 kN; 800 m converges (−264.4 kN) | same | — | F: the continuation route, also the fallback in paper mode, establishes the 800 m equilibrium; the values moved with the seabed anchor-end weight-moment fix (v0.1.0: −937 / −820 / −280.5 kN). The large spurious compression under under-integration stands |
| Converged dynamic meshes, 80/200/800 m | 240 / 480 / 960 | 240 / 480 / 960 | 480 / 480 / 960 | tensile | D: with the force blend the 240-element 80 m mesh reaches −0.15 kN |
| Dynamic continuous axial minima | 0.037 / 0.562 / 1.76 kN | 0.037 / 0.563 / 1.76 kN | 0.94 / 0.54 / 1.24 kN | tensile | F at 200 m (same fix as the 200 m subdivision row); D with the defaults |
| Dynamic peak curvature | 0.10254 / 0.08844 / 0.03899 /m | 0.10254 / 0.08844 / 0.03899 /m | 0.10247 / 0.08844 / 0.03899 /m | OrcaFlex 0.10279 / 0.08823 / 0.03881 /m | D (80 m) |
| Dynamic peak curvature, difference from OrcaFlex | 0.24 / 0.24 / 0.46 % | 0.24 / 0.24 / 0.46 % | 0.32 / 0.24 / 0.45 % | OrcaFlex | D |
| Curvature-amplification difference, max | ≤ 0.11 % | 0.10 % | 0.07 % | OrcaFlex | D |
| Hang-off tension mean/min/max, nine comparisons | ≤ 0.38 % | 0.37 % | 0.16 % | OrcaFlex | D |
| Peak bend moment; peak MBR utilisation | 2.04 / 1.76 / 0.776 kN·m; 0.247 / 0.213 / 0.094 | same | same | — | R |
| 80 m module pitch / sag-bend radius | 1.14 (radius 10.4 m) | 1.14 | 1.14 | — | R |
| 800 m dynamic peak on 240/480/960 elements | 0.038854 / 0.038963 / 0.038987 /m | same | 0.038849 / 0.038964 / 0.038986 /m | — | D |
| 800 m last mesh doubling | 0.061 % | 0.061 % | 0.057 % | — | D |
| 800 m peak station; offset from OrcaFlex | 368.17→364.34 m; 0.24 m | same | same | OrcaFlex station | R |
| 800 m hang-off tension change, last doubling | ≤ 0.04 % | 0.04 % | 0.01 % | — | D |
| 800 m intervals needing subdivision | 1 of 1200 | 1 of 1200 | 0 of 1200 | — | D |
| 200 m intervals needing subdivision (Fig. 20 data) | 1 | 0 | 0 | — | F: step-quality gate now measures deformation, not rigid translation; peak changes by 3e-6 relative |
| Boundary-layer screen η_b, hang-off / far end | 0.382 / 0.614 / 1.632; 0 / 0.133 / 0.685 | same | 0.191 / 0.614 / 1.632; 0.069 / 0.133 / 0.685 | — | D: follows the 480-element 80 m mesh |
| 800 m curvature profile (Fig. 13) | — | within 5e-7 /m | within 0.5 % of the peak away from the ends | OrcaFlex, MoorDyn-F | D |
| Elliptical 3D hang-off motion, peak curvature | 0.52 % | 0.52 % | 0.52 % | OrcaFlex | R |
| 16-harmonic coupled trajectory, peak curvature | 0.23–1.01 % | 0.23 / 0.36 / 1.01 % | 0.24 / 0.35 / 1.01 % | OrcaFlex | D |
| Moving touchdown (qualitative) | curvature and tension retained | peak curvature 0.58 % | 0.58 % | OrcaFlex | R |
| Regular-wave chain, mean / swing | 0.30 / 8.41 % | 0.30 / 8.41 % | same; `FairTen` 1.20 / 10.6 % | OrcaFlex effective tension | R |
| Irregular-wave cable peak curvature | 0.215 % | 0.215 % | 0.215 % | OrcaFlex | R |
| Irregular-wave hang-off tension mean/min/max | 0.192 / 0.186 / 0.108 % | 0.192 / 0.186 / 0.108 % | 0.214 / 0.198 / 0.158 % | OrcaFlex | D |
| Slack-to-taut Δt_CFL; peaks at 0.5–20 ms | 3.155 ms; 10.2248 … 10.5068 MN | same | 3.155 ms; 10.2246 … 10.3821 MN | 0.5 ms solution | D: force-blended EI = 0 step |
| Slack-to-taut changes; apparent order; 20 ms | 0.0048–2.7576 %; 2.69; 6.34 Δt_CFL | same | 0.0010–1.5410 %; not defined; 6.34 Δt_CFL | 0.5 ms solution | D: see below the table |
| 800 m curvature at 50 ms | 0.03899 /m | 0.03899 /m | 0.03899 /m | OrcaFlex 0.03881 /m | R |
| Cable motion envelope at 0.05 s, 30 gated cases | all complete | 30 of 30 complete | 28 of 30 with plain steps; 30 of 30 with subdivision | — | W: see [Known difference](#known-difference) |
| Mooring motion envelope at 0.1 s | subdivision only for the two most severe semitaut motions | subdivision for three semitaut motions (6 m/12 s, 10 m/14 s, 5 m/7 s) | a different set; severe-motion peaks changed | — | X: the article's source gives the same three; all-chain needs none. D with the defaults: see [Known difference](#known-difference) |

With the default force blend the slack-to-taut peaks lie within 1.55 % of the 0.5 ms solution at
every step from 0.5 to 20 ms (within 0.05 % up to 5 ms), without a monotone trend; both blends
converge to the same 0.25 ms peak (10.2246 MN); the article's convergence order (2.69) refers to
the configuration blend (paper mode).

The table covers every result the article prints from a CableDyn calculation. Values derived
only from reference codes are not listed: the MoorDyn-F native-mesh difference, its refinement
and settlement study, and the 0.5 ms MoorDyn-F step.

## Known difference

**Cable motion envelope with the default force blend.** The article's envelope protocol
advances each 0.05 s interval with a single generalised-α step at a standalone tolerance of
`1e-3`, with no internal subdivision. In paper mode all 30 gated cases complete, as in the
article. With the default force blend, 2 of the 30 stop on a non-converged step: heave at
80 m (10 m, 14 s and 5 m, 7 s). The 15 m margin probes at 80 and 200 m also stop; in paper
mode only the 200 m probe does.

Root cause: the Hermite step tangent is inexact. It holds added mass over the step and omits
the wave-field gradient, so Newton reaches a residual plateau and stops. Under the force blend
this plateau can lie above the tolerance on steps the configuration blend completes. In the
80 m, 5 m, 7 s case, step 61 stagnates at a scaled residual of 1.23e-3, above the `1e-3`
tolerance; paper mode completes the case.

The release's production step (`CD_HermiteCable_Dyn_Step_Recovering`, used by the standalone
driver and the module for OpenFAST, maintained by NLR, the National Laboratory of the Rockies,
formerly NREL) subdivides such intervals. With it, all 30 gated cases and all
six margin probes complete in both modes. The defaults subdivide 6 intervals in 5 cases, and
paper mode 4 intervals in 4 cases. The solver is not broken, but under the article's
single-step protocol the default scheme has less convergence margin.

**Mooring motion envelope with the default force blend.** With the defaults, a different set of
mooring motions needs step subdivision at the article's 0.1 s envelope step, and the peaks of the
severe motions changed. Against converged 0.5 / 0.25 ms references (configuration blend = paper
mode, force blend = defaults, both at 0.1 s):

| Case | Reference | Configuration blend | Force blend |
| --- | --- | --- | --- |
| 200 m semitaut surge 10 m/14 s, anchor max | 2950–2975 kN | 8084 kN (+173 %) | 3584 kN (+21 %) |
| 200 m semitaut surge 5 m/7 s, anchor max | 4208–4277 kN | 9042 kN (+113 %) | 5799 kN (+36 %) |
| 80 m all-chain heave 5 m/7 s, fairlead max | 1724–1787 kN | 1723 kN (−2 %) | 1538 kN (−13 %) |
| 80 m all-chain heave 5 m/7 s, anchor max | 1494–1585 kN | 1468 kN (−4 %) | 1246 kN (−19 %) |

The snap is not resolved at 0.1 s, which the run notes. The force blend removes the spurious
semitaut spikes but underestimates the all-chain heave peaks at that step. Confirm peak tensions
with a smaller `dtM`.

**Hang-off curvature near an unresolved boundary layer.** This is not an article result. At
the 800 m hang-off node, where the article reports η_b = 1.63 and omits the bend moment, the
maximum dynamic curvature is 1.6e-3 /m with the defaults and 1.3e-4 /m in paper mode. The
sag-bend peak and the interior profile are unaffected. The curvature near a pinned hang-off is a
boundary-layer quantity and depends strongly on the time step. In a 3 m, 12 s heave it converges
only at Δt ≤ 0.025 s (800 m) and Δt ≤ 0.0125 s (200 m), with the mesh graded toward the end; at
the article's 0.05 s both blends overstate it, by 1.6–2.3 times at 1 m from the end and up to 37
times at the pinned node, whose exact curvature is zero. The sag-bend peak is converged at
0.05 s. Report end curvature 1–2 m from a pinned end after a time-step study, as described in
the [modelling guide](https://cabledyn.readthedocs.io/en/latest/modeling.html).

## How to reproduce

Build the release as described in the
[development guide](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/DEVELOPMENT.md):

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

**Test programs.** Run the test programs from `build` unless noted. Where the article used an
output file, pass its name as the first argument. The programs print every scored value. The
executables are in `build/` on Linux and macOS; Windows builds with the conda GNU toolchain
put them, with the runtime DLLs, in `build/bin/`. Set `BIN` to match:

```bash
BIN=.      # Linux and macOS; use BIN=bin for a Windows GNU build
cd build
$BIN/test_l3_lazywave_dynamic lazywave_solver_evidence.csv                     # paper mode
CD_L3_FORCE_BLEND=1 $BIN/test_l3_lazywave_dynamic lazywave_solver_evidence.csv # defaults
$BIN/test_l3_lazywave_irregular irregular_wave_cable_comparison.dat TABLE.dat  # see below
$BIN/test_l3_orcaflex_wave_dynamic regular_wave_chain_comparison.dat
$BIN/test_snap_load time_step_snap.dat
$BIN/test_viscoelastic polyester_working_ramp.dat
$BIN/test_syrope polyester_syrope_validation.dat
$BIN/test_l2_chain_parity; $BIN/test_l3_orcaflex_current_static; $BIN/test_l3_longduration_mooring
$BIN/test_l2_lozon80_mooring; $BIN/test_l2_lozon200_semitaut
$BIN/test_l3_lazywave_3d_dynamic; $BIN/test_l3_lazywave_touchdown_dynamic
$BIN/test_l4_lazywave_coupled
cd .. && build/$BIN/test_l2_2_dynamic_parity WD0050/A1  # also A2, WD0200/A1..A2, WD0600/A1..A2
```

The L1 programs (`test_l1_*`) give the elementary-mechanics results.

**Irregular-sea comparison.** The article drove both codes with OrcaFlex's own 78-component
JONSWAP realisation. OrcaFlex output is not redistributed, so OrcaFlex licence holders
regenerate that table with
`python validation/scripts/orcaflex_lazywave_irregular_reference.py --orcaflex-jonswap TABLE.dat`
and pass it as the second argument; the program checks the table and scores the article's
OrcaFlex values. Without the table it runs CableDyn's own seeded sea against its OrcaFlex
summary values.

**Paper mode in other test programs.** Apart from `test_l3_lazywave_dynamic`, the Hermite
dynamic test programs use the default force blend. For paper mode, add
`CALL CD_HermiteCable_Dyn_Set_ForceBlend(model, .FALSE., es, em)` after
`CD_HermiteCable_Dyn_Init`. This applies to `test_l3_lazywave_irregular`,
`test_l3_lazywave_3d_dynamic`, `test_l3_lazywave_touchdown_dynamic`,
`test_l4_lazywave_coupled`, `test_l1_hermite_beam_vibration` and
`test_l1_hermite_energy_stability`.

The tension-only (EI = 0) test programs use the default force blend as well. For paper mode, set
`force_blend = .FALSE.` in the `GenAlphaConfig` passed to the EI = 0 step (for example
`dcfg%force_blend = .FALSE.`, or `cfg%force_blend = .FALSE.`) before the march. This applies to
`test_snap_load`, `test_l3_orcaflex_wave_dynamic`, `test_l3_longduration_mooring`,
`test_l2_2_dynamic_parity`, `test_viscoelastic`, `test_syrope`, `test_l1_string` and
`test_l1_energy_stability`. Deck runs (`test_l2_lozon80_mooring`, `test_l2_lozon200_semitaut`
and the driver) take `False alpha_force_blend` from `OPTIONS`.

**Toolchain.** Built with gfortran, the development source gives the same paper-mode values as
v0.1.0 built with gfortran. One count depends on the toolchain: with gfortran the 800 m paper-mode
run subdivides 0 of 1200 intervals (v0.1.0 as well), where the table records 1 of 1200.

**Deck runs.** The static cable profiles use the example decks, which carry the article's
refined meshes (1024, 952 and 1024 elements):

```bash
mkdir -p out    # the driver does not create output folders
build/$BIN/cabledyn examples/lozon_gomex80_power_cable.dat out/cable_80
```

With the release executable, run `CableDyn_driver.exe` (`.\CableDyn_driver.exe` in PowerShell)
in place of `build/$BIN/cabledyn`.

For paper mode, add these rows to `OPTIONS`:

```text
sequenced cable_statics
False     alpha_force_blend
element   OutputRecovery
```

`alpha_force_blend` matters only for dynamic runs. The finite-EI node tension, curvature and
bend moment of the deck channels, `.static.out` and the range graphs are recovered from nodal
equilibrium by default; the article reported the element-mean axial force and the geometric
Hermite curvature, which `element OutputRecovery` restores. The test programs of this record
read the geometric curvature (`CD_HermiteCable_Dyn_Curvature_Exact`), so their numbers do not
depend on this option. For the quadrature and refinement study, use
the article's starting meshes:

| Cable | Segments per section | Multiples run |
| --- | --- | --- |
| 80 m | 28 / 20 / 16 | 1, 2, 4, 8, 16 |
| 200 m | 58 / 20 / 41 | 1, 2, 4, 8 |
| 800 m | 128 / 128 / 256 | 1, 2 |

Add these rows to `OPTIONS`:

```text
False tensile_safety
4     axial_quadrature_order
4     bending_quadrature_order
```

Read the continuous extrema from `<root>.elements.out`.

**Mooring end tensions.** For the moorings, set the line's `Outputs` field to `pt`. Segment 1
of `<root>.Line1.t.out` is the article's end-element tension; `FairTen` in `<root>.out` is the
end force.
