<!-- SPDX-License-Identifier: Apache-2.0 -->

# OpenFAST examples: IEA-15MW on the UMaine VolturnUS-S

Mooring decks and `.fst` templates for running the IEA-15MW turbine on the UMaine VolturnUS-S
semi-submersible in OpenFAST, maintained by NLR (National Laboratory of the Rockies, formerly
NREL), with CableDyn (`CompMooring = 5`), plus a stock MoorDyn twin
(`CompMooring = 3`) for a like-for-like comparison. The step-by-step procedure is the
[OpenFAST tutorial](../../doc/tutorial_openfast.rst).

## Files

| File | Role |
| --- | --- |
| `CableDyn_UMaine.dat` | CableDyn deck: three-line all-chain catenary |
| `MoorDyn_UMaine.dat` | MoorDyn deck for the same mooring, with SeaState line kinematics (`SeaState WaterKin`) |
| `IEA-15-UMaine_CompMooring5_CableDyn.fst` | `.fst` template using CableDyn |
| `IEA-15-UMaine_CompMooring3_MoorDyn.fst` | `.fst` template using MoorDyn |
| `CableDyn_UMaine_rod.dat`, `MoorDyn_UMaine_rod.dat` | Lines 1 and 2 hung from the ends of a `Coupled` 100 m pontoon rod between their fairleads (the coupled-rod comparison in `validation/OPENFAST_DLC_VERIFICATION.md`) |
| `IEA-15-UMaine_CompMooring5_CableDyn_LineFailure.fst`, `CableDyn_UMaine_line_failure.dat` | The `CompMooring = 5` model with a `FAILURE` row: line 1 breaks at its fairlead at t = 100 s of a 400 s run (see [Line failure](#line-failure-accidental-limit-state)) |
| `../iea15mw_umaine_mixed_cabledyn.dat` | CableDyn deck: the three chains plus a finite-EI lazy-wave power cable |

Both mooring decks describe three 120°-spaced R4 studless chains (850 m, 685 kg/m,
EA 3.27×10⁹ N, volume-equivalent diameter 0.333 m) from fairleads at radius 58 m and 14 m draft
to anchors at radius 837.6 m on a 200 m seabed. The two templates differ only in `CompMooring`
and `MooringFile`.

## Turbine model

The ElastoDyn, HydroDyn, SeaState, and WAMIT files are not included. Copy them from OpenFAST's
r-test (`glue-codes/fast-farm/MD_Shared/`, revision `dd5feaaaa500ba7283140107806300d551cff0a7`)
into the directory holding a template; the templates use its turbine-1 file names.

`MD_Shared` places turbine 1 at its farm pose (20.3 m surge, 180° yaw, `PtfmRefY = 180`).
Reset the pose, or the offset platform overstretches line 1 and both codes report a meaningless
~321 MN fairlead tension:

```powershell
$ed = 'IEA-15-240-RWT-UMaineSemi_ElastoDynT1.dat'
(Get-Content $ed) -replace '^\s*\S+(\s+Ptfm(Surge|Sway|Heave|Roll|Pitch|Yaw)\s)', '          0$1' |
    Set-Content $ed -Encoding ascii
$hd = 'IEA-15-240-RWT-UMaineSemi_HydroDynT1.dat'
(Get-Content $hd) -replace '^\s*\S+(\s+PtfmRefY\s)', '             0$1' |
    Set-Content $hd -Encoding ascii
```

The initial CableDyn fairlead tensions are then the ~2.4 MN chain pretension.

The `MD_Shared` `SeaState.dat` computes the wave kinematics on a grid that covers only the
platform (`X_HalfWidth = Y_HalfWidth = 100 m`, `Z_Depth = 40 m`), while the anchors lie 838 m
away on the 200 m seabed. SeaState gives every line node outside the grid the kinematics of the
grid boundary, and CableDyn warns about it. Enlarge the grid:

```powershell
$ss = 'SeaState.dat'
(Get-Content $ss) -replace '^\s*\S+(\s+[XY]_HalfWidth\s)', '           900$1' `
                  -replace '^\s*\S+(\s+Z_Depth\s)', '     "default"$1' `
                  -replace '^\s*\S+(\s+NX\s)', '            37$1' `
                  -replace '^\s*\S+(\s+NZ\s)', '            11$1' |
    Set-Content $ss -Encoding ascii
```

SeaState then needs about 4.6 GB of memory. The values in this file are for the enlarged grid.
Grid sizing is described in the manual's OpenFAST page (SeaState grid).

## Run

```powershell
.\openfast.exe IEA-15-UMaine_CompMooring5_CableDyn.fst   # CableDyn
.\openfast.exe IEA-15-UMaine_CompMooring3_MoorDyn.fst    # MoorDyn
```

The CableDyn run log identifies the module with `Running CableDyn (v0.4.2, 2026-11-09)` and
prints the converged fairlead state of each line, as the standalone driver does:

```text
   Line 1 fairlead effective tension: 2.43712E+06 N
      force [Fx, Fy, Fz]: [-1.35070E+06, 0, -2.02858E+06] N, inclination=56.343 deg
      line tangent: inclination=55.685 deg, declination=145.68 deg, azimuth=180 deg
```

The force is the one the line exerts on the fairlead, including the end node's share of the
chain weight, so it is slightly steeper than the line tangent. These are the static-equilibrium
values, also written to `<root>.CD.static.out`. The requested `OUTPUTS` printed below them are
the t = 0 values, which add the load of the SeaState wave kinematics at t = 0 on the end node:
`FairTen1` reads 2.43752E+06 N. In still water the two agree.

For the power-cable case, copy `../iea15mw_umaine_mixed_cabledyn.dat` beside the template and
point `MooringFile` at it.

## Coupled platform rod

`CableDyn_UMaine_rod.dat` replaces the fairlead points of lines 1 and 2 by the two ends of a
`Coupled` pontoon rod, 100 m long and 1 m in diameter, that runs between them. The rod follows the
platform and returns the force and moment of its lines, weight, buoyancy, Morison loads and
inertia to OpenFAST; line 3 stays on a `Coupled` point. To run it, set `MooringFile` in
`IEA-15-UMaine_CompMooring5_CableDyn.fst` to `"CableDyn_UMaine_rod.dat"`. `MoorDyn_UMaine_rod.dat`
is the same mooring for stock MoorDyn (`CompMooring = 3`), with `SeaState WaterKin` as in
`MoorDyn_UMaine.dat`; it also writes the rod end positions (`Rod1N0P*`, `Rod1N10P*`).

## Line failure (accidental limit state)

`IEA-15-UMaine_CompMooring5_CableDyn_LineFailure.fst` runs 400 s with
`CableDyn_UMaine_line_failure.dat`, whose `FAILURE` section breaks line 1 at its fairlead:

```text
--------------------------- FAILURE -------------------------------------------
FailID  Point  Line(s)  FailTime  FailTen
(-)     (-)    (-)      (s)       (N)
1       P1     1        100.0     0
```

At the break the log prints `CableDyn: FAILURE 1 triggered at t = 100.0000 s, detaching line
end(s) onto reserve point 7`; the detached end then moves freely and OpenFAST carries on with the
platform on lines 2 and 3. Set `FailTime` to `0` and `FailTen` to a tension in N to break the line
the first time its fairlead tension reaches that value instead. `FAILURE` runs on pure `EI = 0`
decks without Rigid6 bodies, seabed friction or FAST.Farm turbines.

The channels to read for an ALS check:

- `<root>.CD.out`: `FairTen<L>` and `AnchTen<L>` of the intact lines give the tension transient
  and peak; the broken line's `FairTen1` falls to zero at the break and `AnchTen1` decays as the
  line settles on the seabed.
- `<root>.out`: the ElastoDyn `PtfmSurge`, `PtfmSway` and `PtfmYaw` channels give the platform
  drift and its new mean position.
- The static equilibrium of every line is in `<root>.CD.static.out`.

In the `MD_Shared` JONSWAP sea (Hs 6 m, Tp 12 s, travelling along +X) line 1 is the only line on
the up-wave side. Before the break the line-1 fairlead tension averages 2.44 MN and `PtfmSurge`
stays within −2.5 to 3.6 m. After it the platform drifts down-wave: `PtfmSurge` reaches 147 m by
t = 400 s and is still growing, because the two remaining anchors lie down-wave of the platform.
The intact lines slacken as it approaches them (`FairTen2` mean 1.29 MN over 300–400 s, no peak
above the 2.51 MN at the break). Run longer (`TMax`) to reach the new equilibrium. The 400 s run
takes about 60 s.

## Notes

- **Sea state.** The templates run without wind or controller. The `MD_Shared` `SeaState.dat`
  is an irregular JONSWAP sea (Hs 6 m, Tp 12 s, heading 0°); set `WaveMod = 0` for still water.
- **Channels.** CableDyn channels are selected under the deck's `OUTPUTS` section, not in the
  `.fst` `OutList`. The deck requests `FairTen`, `AnchTen`, `FairIncl`, and `AnchIncl` for each
  line; their t = 0 values are printed after the static solve.
- **Time step.** Without a deck `dtM`, CableDyn steps at 0.1 s and holds its loads between
  steps. `<root>.CD.out` has one row per CableDyn step and `<root>.CD.static.out` the static
  equilibrium. For linearisation use `dtM = DT` and linearise at t = 0 from the still-water
  equilibrium.
- **MoorDyn.** MoorDyn builds its initial state by dynamic relaxation, so its deck uses a small
  `dtM` on this stiff chain. CableDyn solves the static state directly.
- **Like-for-like waves.** CableDyn samples the SeaState wave and current field at its line
  nodes by default. The MoorDyn deck's `SeaState WaterKin` option does the same for MoorDyn;
  without it MoorDyn's lines see still water and the tension statistics are not comparable. The
  option increases the MoorDyn run time.
- **Deck `dtM`.** A CableDyn `dtM` that is not a whole multiple of the glue `DT` is reduced to the
  largest multiple that does not exceed it, with a warning stating both values.

References: [deck format](../../doc/driver_format.md), [options](../../doc/options.rst),
[coupling contract](../../doc/coupling_boundary.md).
