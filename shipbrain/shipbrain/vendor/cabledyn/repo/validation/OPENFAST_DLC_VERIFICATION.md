<!-- SPDX-License-Identifier: Apache-2.0 -->

# Coupled OpenFAST design-load-case comparison

This record is for users who need evidence that CableDyn (`CompMooring = 5`) runs and agrees with
stock MoorDyn-F inside a full turbine model in OpenFAST, maintained by NLR (National Laboratory
of the Rockies, formerly NREL), under IEC 61400-1/-3 design load case (DLC)
environments. All cases use the IEA-15MW turbine on the UMaine VolturnUS-S platform.

Two questions are assessed for each case:

- **Completion:** the coupled run reaches `TMax` with no NaN and no fatal error.
- **Agreement:** platform motion and mooring loads are within tolerance of stock MoorDyn-F.

## Method

Each environment is run twice with the identical aero-servo-elastic-hydro model, changing only
the mooring module: `CompMooring = 3` (stock MoorDyn-F, the reference) and `CompMooring = 5`
(CableDyn). Both runs use the same TurbSim wind field, SeaState realisation and ROSCO controller.
[`dlc_ab_compare.py`](scripts/dlc_ab_compare.py) scores the pair over a window that excludes
the initial transient:

| Channels | Scored on | Tolerance |
| --- | --- | --- |
| Platform DOFs (surge, sway, heave, roll, pitch, yaw) | standard deviation and maximum | \|Δ\| ≤ 0.02 + 3 %·\|ref\| |
| Near-zero-mean platform DOFs (head-on roll, sway, yaw at ~0) | additionally, absolute mean difference | < 0.05 m or deg |
| Fairlead tensions `FairTen1..3` | mean | 2 % |
| Anchor tensions `AnchTen1..3` | mean | 3 % |

Both codes report `FairTen` and `AnchTen` as the force at the line end, including the end
node's share of the chain weight, so their mean tensions are compared directly. CableDyn starts
from a Newton static equilibrium and MoorDyn from dynamic relaxation; on this mooring the two
initial states give the same line loads, and the mean tensions agree to within 0.03 % in every
case below. The platform mean is reported for information only: it follows from the same line
loads, which are scored on the tensions, and a small mean gives a noisy percentage. The platform
DOFs are therefore scored on their dynamic response. The absolute
floor of 0.02 prevents a negligible amplitude difference on a near-motionless DOF (such as a
sub-0.1° parked yaw, where 3 % is ~0.001°) from failing, while a genuinely different oscillation
amplitude still fails. The tension result is consistent with the L4-1b DLC-1.1 case in
[`VALIDATION.md`](../VALIDATION.md).

## DLC matrix (moored-FOWT subset of IEC 61400-3-1)

| DLC | Turbine state | Wind | Waves | Type | Load of interest | Assessed here |
| --- | --- | --- | --- | --- | --- | --- |
| **1.1** | Power production | NTM, Vin<V<Vout | NSS | U | operational baseline | yes, 6 m/s and 18 m/s |
| **1.2** | Power production | NTM | NSS | F | long-run fatigue | no |
| **1.3** | Power production | ETM | NSS | U | extreme turbulence | no (see notes) |
| **1.4** | Power production | ECD (gust+dir) | NSS | U | transient snatch | no |
| **1.5** | Power production | EWS (shear) | NSS | U | asymmetric loading | no |
| **1.6** | Power production | NTM | **SSS** (Hs≈10) | U | severe waves on the cable | yes |
| **2.1** | Prod + ctrl fault | NTM | NSS | U | fault transient | no |
| **2.3** | Prod + grid loss | EOG | NSS | U | load-loss surge | no |
| **6.1** | Parked | **EWM 50-yr** turb | **ESS** (Hs≈11) | U | max mooring tension | yes, 60 s class case |
| **6.2** | Parked + grid loss | EWM 50-yr | ESS | U | drift + snap | no |
| **6.3** | Parked, 20° yaw | EWM 1-yr | SSS | U | asymmetric extreme | no (see notes) |
| **6.4** | Parked | NTM | NSS | F | idling fatigue | no |

IEC ultimate (U) cases call for 1 h simulations with 6 seeds, and fatigue (F) cases for 10 min
per seed. The results below are single 60 s realisations of each environment class; they
establish completion and agreement for that realisation, not a certification-length ensemble.

## Reproduce

Inputs:

- the full IEA-15MW UMaine VolturnUS-S OpenFAST model with wind, aerodynamics, ROSCO
  (`libdiscon.dll`) and waves, from the OpenFAST regression-test IEA-15-240-RWT models;
- the mooring pair `examples/openfast/MoorDyn_UMaine.dat` and
  `examples/openfast/CableDyn_UMaine.dat` (the CableDyn deck already outputs
  `FairTen1..3` and `AnchTen1..3`);
- for the parked case, an ElastoDyn file with 90° blade pitch, zero rotor speed and
  `GenDOF = False`, and a ServoDyn file with `PCMode = 0` and `VSContrl = 0`;
- TurbSim (OpenFAST build target `turbsim`) and an OpenFAST build with CableDyn
  ([`integration/openfast/`](../integration/openfast/README.md)).

```bash
# 0) put openfast.exe, turbsim.exe and their runtime DLLs on PATH
export PATH="<build>/glue-codes/openfast:<runtime-dlls>:$PATH"

# 1) stage the model; ../IEA-15-240-RWT holds the shared blade and tower files
#    <workdir>/IEA-15-240-RWT/  and  <workdir>/IEA-15-240-RWT-UMaineSemi/

# 2) generate the wind field (set URef, TI and IEC_WindType in NTM_*.in for the DLC)
turbsim.exe NTM_6_1.in                       # -> NTM_6_1.bts

# 3) set the sea state in *_SeaState.dat (WaveMod = 2, JONSWAP; WaveHs/WaveTp for NSS/SSS/ESS)

# 4) make the pair from a 60 s main input, changing ONLY CompMooring and MooringFile
#    (as in examples/openfast/):
#      Main_short_md3.fst : CompMooring = 3, "*_MoorDyn.dat"
#      Main_short_cd5.fst : CompMooring = 5, "CableDyn_UMaine.dat"
openfast.exe Main_short_md3.fst
openfast.exe Main_short_cd5.fst

# 5) score (third argument: start of the scored window, s)
python validation/scripts/dlc_ab_compare.py Main_short_md3.out Main_short_cd5.out 10
```

## Results

Every case below completed its 60 s run with `CompMooring = 5`, and every all-chain case passed
all tolerances. Values are CableDyn − MoorDyn-F as a percentage of the MoorDyn-F value. Each
run starts from the undisplaced platform, so the platform means include the initial drift and
are reported for information only.

### DLC-1.1 class, below rated: NTM 6 m/s + JONSWAP Hs=6/Tp=16, full aero + ROSCO

Scored `t ≥ 10 s`.

| Channel | CableDyn − MoorDyn | Scored on | Tolerance |
| --- | --- | --- | --- |
| FairTen1 / FairTen2 / FairTen3 | mean 0.000 % / 0.000 % / 0.002 % | mean | 2 % |
| AnchTen1 / AnchTen2 / AnchTen3 | mean 0.001 % / −0.001 % / 0.006 % | mean | 3 % |
| PtfmSurge / PtfmHeave / PtfmPitch | dyn std/max ≤ 0.07 / 0.02 / 0.13 % (means 0.03 / 0.02 / −0.03 %, info) | dyn (std + max) | 3 % |
| PtfmSway | abs mean delta 0.0002 m | abs | 0.05 m |

The fairlead tension standard deviations agree to within 0.34 %, and every scored channel to
within 0.81 % (the PtfmSway maximum).

### DLC-1.6 class, severe sea: NTM 6 m/s + JONSWAP **Hs=10**/Tp=16

Scored `t ≥ 10 s`.

| Channel | CableDyn − MoorDyn (mean) | Dyn (std / max) | Tolerance |
| --- | --- | --- | --- |
| FairTen1 / FairTen2 / FairTen3 | 0.004 % / 0.002 % / 0.003 % | ≤ 0.61 % / ≤ 0.12 % | 2 % |
| AnchTen1 / AnchTen2 / AnchTen3 | < 0.01 % | ≤ 0.51 % / ≤ 0.28 % | 3 % |
| PtfmHeave / PtfmPitch (dyn) | std/max ≤ 0.06 % | mean 0.02 / 0.02 % | 3 % |
| PtfmSurge (dyn) | std/max ≤ 0.03 % | mean 0.03 % (info) | 3 % |

The platform dynamic response agrees to within 0.3 % on every DOF and the mean tensions to
within 0.01 %.

### DLC-1.1 class, above rated: NTM **18 m/s** + JONSWAP Hs=6/Tp=16, ROSCO pitch control

Above rated, ROSCO pitches the blades, which gives a different aero-servo loading from the
below-rated case. The run starts at the rated rotor speed with 15° blade pitch. Scored
`t ≥ 15 s`.

| Channel | CableDyn − MoorDyn | Scored on | Tolerance |
| --- | --- | --- | --- |
| FairTen1 / FairTen2 / FairTen3 | mean 0.007 % / 0.001 % / 0.002 % | mean | 2 % |
| AnchTen1 / AnchTen2 / AnchTen3 | mean < 0.01 % | mean | 3 % |
| PtfmSurge / PtfmHeave / PtfmPitch | dyn std/max ≤ 0.05 / 0.02 / 0.02 % (means 0.035 / 0.015 / −0.002 %, info) | dyn (std + max) | 3 % |
| PtfmSway | abs mean delta 0.0003 m | abs | 0.05 m |

Platform dynamics agree to within 0.1 % on every DOF and the mean tensions to within 0.01 %.
The tension standard deviations agree to within 0.82 % at the fairleads and 1.86 % at the
anchors, where they are reported but not scored.

### DLC-6.1 class, 50-year extreme: EWM 50-yr wind ~50 m/s + ESS **Hs=11**/Tp=16, parked

The rotor is parked: the blades are feathered at 90°, the generator degree of freedom is off
and pitch control is disabled. This is the maximum-mooring-tension case. The run completed with
all outputs finite. Scored `t ≥ 15 s`.

| Channel | CableDyn − MoorDyn (mean) | Dyn (std / max) | Tolerance |
| --- | --- | --- | --- |
| FairTen1 / FairTen2 / FairTen3 | 0.024 % / 0.010 % / 0.010 % | ≤ 0.57 % / ≤ 0.04 % | 2 % |
| AnchTen1 / AnchTen2 / AnchTen3 | < 0.03 % | ≤ 0.60 % / ≤ 0.33 % | 3 % |
| PtfmHeave / PtfmPitch (dyn) | std/max ≤ 0.02 % | mean −0.02 / −0.01 % | 3 % |
| PtfmSurge (dyn) | std/max ≤ 0.01 % | mean 0.04 % (info) | 3 % |

Tensions and platform dynamic response agree to within 0.6 %, apart from the PtfmYaw maximum
(1.70 %). Across the four environments, CableDyn and MoorDyn-F agree to within
0.03 % in mean fairlead and anchor tension.

### Finite-EI power cable, severe sea (Hs=11)

The cases above use the all-chain mooring. This case uses the mixed deck
`examples/iea15mw_umaine_mixed_cabledyn.dat`: three chains plus a finite-EI cubic-Hermite
lazy-wave cable that runs from the platform (point 7, `Coupled`) to a touchdown on the 200 m
seabed and ends at an anchor (point 8, `Fixed`), in the full turbine under Hs=11 waves. The run
used the deck's earlier 87-element (20 + 25 + 42) mesh of the cable; the example now meshes it
with 248 elements to resolve its bending length, and the one-hour full-turbine run of the
coupled finite-EI touchdown row in [`VALIDATION.md`](../VALIDATION.md) uses that mesh. The run
completed (exit 0, all 2400 steps, 0 NaN/Inf), and its output contains the finite-EI curvature
and bending-moment channels of the sag bend, which confirms that the cable ran on the finite-EI
element. With the geometric curvature of the centreline, which these channels reported when the
case was run and which `OutputRecovery element` reproduces, the standalone driver gives at the
static initial state 0.0915 1/m and 1821 N·m on that mesh (`Curv4N20`, `BendMom4N20`) and
0.0906 1/m and 1803 N·m on the current one (`Curv4N38`, `BendMom4N38`). The curvature and bend moment
recovered from nodal equilibrium, the channels' definition now, are 0.0838 1/m and 1667 N·m at
node 20 of the former mesh (0.0914 1/m at node 19, the recovered peak) and 0.0902 1/m and
1795 N·m at node 38 of the current one. This case has no MoorDyn-F twin and establishes completion only; cable accuracy is established against OrcaFlex in cases L3-4, L3-5, L3-6 and
L4-1c of [`VALIDATION.md`](../VALIDATION.md).

### Coupled rod between two fairleads, still water

This case checks a platform-borne rod, which MoorDyn-F supports. Lines 1 and 2 of the all-chain
mooring hang from the two ends of a `Coupled` pontoon rod (100 m long, 1 m diameter,
400 kg/m, `Cd 0.8`, `Ca 1.0`, 10 segments) that runs between fairleads 1 and 2 at z = -14 m.
Line 3 stays on a `Coupled` point. The model runs 300 s in still water with no wind, starting
from the undisplaced platform, so the response is the free decay of the static offset. The
released MoorDyn-F build and CableDyn give different responses on this case. The difference
traces to the orientation convention of the coupled-rod mesh node, so the comparison reference
is MoorDyn-F with that convention adjusted, as described below:

| Run (t ≥ 100 s) | Surge mean/std (m) | Sway mean/std (m) | Roll mean/std (deg) | max \|sway\| (m) | `FairTen1..3` mean vs orientation-adjusted MoorDyn-F |
| --- | --- | --- | --- | --- | --- |
| MoorDyn-F v2.3.8 (release build) | 1.605 / 0.850 | 3.714 / 1.778 | 0.048 / 2.760 | 7.07 | +4.09 %, +8.38 %, +4.63 % |
| MoorDyn-F, upstream `dev` 0b1979810 | 1.606 / 0.851 | 3.715 / 1.779 | 0.048 / 2.760 | 7.07 | +4.09 %, +8.39 %, +4.63 % |
| MoorDyn-F, `dev` with the orientation adjusted | -0.350 / 0.329 | 0.039 / 0.041 | 0.193 / 0.113 | 0.13 | reference |
| CableDyn | -0.350 / 0.330 | 0.040 / 0.042 | 0.193 / 0.108 | 0.13 | +0.001 %, 0.000 %, 0.000 % |

**Observed difference.** MoorDyn-F registers the coupling-mesh node of a coupled rod with the
rod's rotation matrix `R_rod` (rod frame to global) as its reference orientation, while OpenFAST
mesh orientations are direction-cosine matrices (global to local), and takes the rod axis as
`Orientation * [0, 0, 1]`. With these conventions the rod axis is `R_rod Rp^T e_z` (`Rp` the
platform rotation), whereas the rigid-body transform of the platform gives `Rp R_rod e_z`. The
two coincide while the platform does not rotate; once it rolls, pitches or yaws, End B of the
rod departs from the rigid-body position while the node velocities follow the platform. The rod
node positions written by MoorDyn-F (`Rod1N0P*`, `Rod1N10P*`) show this directly. Against the
rigid-body transform of the ElastoDyn platform motion, End A stays within 1 mm in every run.
End B is up to 27.3 m from it in `dev`, and it matches `R_rod Rp^T e_z` to 1 mm. With the
orientation adjusted, End B is within 1 mm. For the comparison reference, a local build of
upstream `dev` 0b1979810 registers and updates the coupled-rod mesh node so that the rod axis is
`Rp R_rod e_z`; nothing else in MoorDyn-F is changed.

The orientation-adjusted MoorDyn-F and CableDyn then agree to 0.001 % in mean fairlead tension,
within 2 mm and 0.002° in the platform means, and within 5 % in the platform standard deviations.
MoorDyn-F runs at `dtM` 0.2 ms with 50 lumped-mass segments per line; CableDyn runs at `dtM`
0.025 s with the implicit march. The unmodified upstream `dev` reproduces the v2.3.8 release
to 0.01 %. The observation applies to `Coupled`/`Vessel` rods once the platform rotates;
pinned rods integrate their own orientation and are not affected. The difference may reflect an
interface convention other than the one assumed here. The decks are
[`examples/openfast/CableDyn_UMaine_rod.dat`](../examples/openfast/CableDyn_UMaine_rod.dat) and
its MoorDyn twin
[`examples/openfast/MoorDyn_UMaine_rod.dat`](../examples/openfast/MoorDyn_UMaine_rod.dat), which
writes the rod node positions `Rod1N0P*` and `Rod1N10P*`.

## Notes

- **DLC 6.3 (parked, 20° yaw).** Run with an EWM field and `PropagationDir = 20°`, it
  reproduces DLC 6.1 almost exactly: a parked, feathered rotor carries little aerodynamic load,
  so the wind-direction offset barely changes the wave-dominated response. It is not counted as
  a separate case.
- **DLC 1.3 (ETM at 6 m/s).** Below rated the response is wave-dominated, so ETM instead of NTM
  changes only the minor wind-driven component. It is not counted as a separate case; a
  discriminating ETM case needs above-rated wind.
- **Not assessed:** the 1 h, 6-seed ensembles required for IEC ultimate cases, DLC 1.2, 1.4, 1.5,
  2.1, 2.3, 6.2, 6.4, and DLC 6.3 with 1-yr EWM. Each can be run with the steps above (TurbSim
  `IEC_WindType`, e.g. `"1EWM50"` or `"1ETM"`, plus the matching sea state) and scored with the
  same `dlc_ab_compare.py`.
