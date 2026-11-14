<!-- SPDX-License-Identifier: Apache-2.0 -->

# MoorDyn-F reference runs for the Lozon et al. (2025) cases

This directory documents the **MoorDyn-F** column of the Lozon et al. (2025) multi-depth tables
in [VALIDATION.md](../../../VALIDATION.md) and holds the decks needed to reproduce it.

| File | Contents |
| --- | --- |
| `mooring_80m.dat`, `mooring_200m.dat`, `mooring_800m.dat` | Single-line static-pretension decks |
| `cable_200m.dat` | 200 m lazy-wave cable, hang-off and anchor fixed, connector rods at the section junctions (rod positions from the CableDyn suspended-span seed) |

## Run

Use the OpenFAST v5.0.0 MoorDyn driver (MoorDyn v2) with a static initial-condition solve:

```text
moordyn_driver <driver.inp>    # driver.inp sets WtrDpth, names the .dat deck, and sets TMax = 0
```

The driver writes `<root>.MD.out` (fairlead and anchor tensions) and `<root>.MD.Line<n>.out`
(per-node position `p`, curvature `K` and tension `t`). MoorDyn computes node curvature as in
Hall, Sirnivas & Yu (2020), *Implementation and Verification of Cable Bending Stiffness in
MoorDyn* (NREL): the reciprocal bend radius from the tangent difference of adjacent segments.
A cable end attached to a rod (their Eq. 10) is a fixed connection whose curvature depends on
the angle between the cable and the rod axis.

## Moorings: static pretension (kN)

Single line; fairlead fixed at radius 58 m and depth 14 m; anchor fixed on the seabed at the
design anchor radius. The fairlead tension at the neutral platform position is the pretension.

| Deck | Site | MoorDyn-F | Paper | OrcaFlex | CableDyn `FairTen` |
| --- | --- | ---: | ---: | ---: | ---: |
| `mooring_80m.dat` | Gulf of Mexico 80 m (catenary chain) | **750.5** | 748 | 747.4 | 749.6 |
| `mooring_200m.dat` | Gulf of Maine 200 m (semitaut poly+chain) | **1212.0** | 1205 | 1199.2 | 1205.4 |
| `mooring_800m.dat` | Humboldt 800 m (taut chain-poly-chain) | **1864.5** | 1704 | 1881.5 | 1881.5 |

- The CableDyn column is the `FairTen` line-end force of the release example decks
  `examples/lozon_gomex80_mooring.dat`, `lozon_gomaine200_mooring.dat` and
  `lozon_humboldt800_mooring.dat`, run with the release defaults.
- At 80 and 200 m all values are within ~1 % of the paper.
- At 800 m the three solvers agree within 1 % (MoorDyn-F 1864.5, CableDyn 1881.5, OrcaFlex
  1881.5). The paper's 1704 kN is a MoorPy quasi-static value that reads ~10 % lower on the stiff
  taut fibre line.
- The authors' three-line coupled MoorDyn reference decks (not redistributed) give fairlead
  tensions of 756.3 kN (80 m) and 1875.9 kN (800 m); the single-line decks here reproduce them
  to ~1 %.

## Lazy-wave cables: static peak curvature (m⁻¹)

Bare, buoyant and bare sections are joined by zero-length connector rods, which MoorDyn requires
at a property transition (Hall et al. 2020, §2.2). Hang-off and anchor are fixed. The 80 m and
800 m values come from the authors' coupled reference decks; the 200 m value is reproduced by
`cable_200m.dat`.

| Site | MoorDyn-F | OrcaFlex | CableDyn |
| --- | ---: | ---: | ---: |
| Gulf of Mexico 80 m | **0.0966** | 0.0968 | 0.09688 |
| Gulf of Maine 200 m | **0.0809** | 0.0831 | 0.08331 |
| Humboldt 800 m | **0.0318** | 0.0280 | 0.02666 |

At 80 m and 200 m the three solvers agree to <0.3 % and <3 %; MoorDyn's elements are 2.6 m and
5.7 m long there. At **800 m** the values span ~0.027–0.032. MoorDyn-F's peak (0.0318) is at the
**hang-off connector rod** (Hall et al. 2020, Eq. 10) on its native 18.6 m mesh (buoy arch
0.0177, bare bottom 0.0208). OrcaFlex and CableDyn peak at the **mid-span sag bend**, which that
mesh samples coarsely. Refining the MoorDyn-F mesh twofold and fourfold moves its sag-bend
peak toward the OrcaFlex and CableDyn values; the refinement study is in the L3-6b entry of
[VALIDATION.md](../../../VALIDATION.md). The CableDyn value is the CTest case
`l3_lazywave_curvature`.
