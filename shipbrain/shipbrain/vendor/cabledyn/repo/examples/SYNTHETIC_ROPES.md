<!-- SPDX-License-Identifier: Apache-2.0 -->

# Synthetic-rope examples

This page is a quick reference for users modelling polyester or nylon lines. It lists the four
axial models, the deck that demonstrates each one, and the input restrictions. The walkthrough
with results is [Tutorial 6 — Synthetic ropes](../doc/tutorial_ropes.rst); the equations are in
[doc/theory.rst](../doc/theory.rst).

## Model selection

The `EA` and `BA` fields of a `LINE TYPES` row select the model. No other option is involved.

| Model | `EA` field | `BA` field | Example deck |
| --- | --- | --- | --- |
| Linear | `EA` | `BA`, or `-zeta` for a damping ratio | `polyester_catenary_mooring.dat` |
| Viscoelastic, constant dynamic stiffness | `Es\|Ed` | `Bs\|Bd` | `ve_polyester_catenary_mooring.dat`, `ve_polyester_dynamic_waves.dat` |
| Viscoelastic, load-dependent dynamic stiffness | `Es\|alphaMBL\|vbeta` | `Bs\|Bd` | `ve_nylon_loaddependent_mooring.dat` |
| Syrope working curve | `SYROPE:<settings>\|alpha\|beta` | `BA_s\|BA_d` | `syrope_polyester_mooring.dat` |

Stiffnesses are axial stiffnesses in N, not moduli in Pa. Damping values are in N·s.

Example rows:

```text
TypeName  Diam    Mass   EA                                                    BA            EI   Cd_n Cd_t Ca_n Ca_t
poly      0.1438  22.42  1.42e8                                                -1.0          0.0  1.2  0.2  1.0  0.0
poly_ve   0.1438  22.42  1.424e8|2.50e8                                        4.0e9|1.1e7   0.0  1.2  0.2  1.0  0.0
nylon_ld  0.15    24.0   6.0e7|1.00e8|0.4                                      4.0e9|1.1e7   0.0  1.2  0.2  1.0  0.0
rope      0.1438  22.42  "SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"  5.0e10|1.0e5  0.0  1.0  0.0  1.0  0.0
```

## Input rules

- Viscoelastic: `Ed` must be finite and greater than `Es`; `Bs` and `Bd` must be finite and
  non-negative. The static solution uses `Es`.
- Syrope: `alpha` and `beta` must be positive; `BA_s` and `BA_d` must be non-negative with a
  positive sum. The settings file names the original working-curve table, relative to itself.
  The optional `SYROPE IC` section sets the prior load history (`Tmax0`, `Tmean0`). `Tmax0` is
  the running maximum: the static solve uses its working curve (the OWC beyond its top strain),
  and the line starts in that static equilibrium with no initial transient. With fixed line
  ends the geometry and `Tmax0` fix the mean tension, so `Tmean0` does not enter the state. A
  `Tmean0` more than 1 % from the static mean tension is reported on the console. A line whose
  initial strain is below the zero-tension strain of the `Tmax0` working curve is slack on that
  history and stops at initialisation. Without the section the rope starts as a virgin rope on
  the OWC.
- Syrope: the OWC table must cover every strain the line reaches. An initial strain outside the
  table, or a run that leaves it, stops with an error. Extend the table rather than rely on
  extrapolation.
- Syrope: the working curve must stay softer than the fast spring. Its slope must be below
  `alpha + beta*T` along the whole curve, and this limits the admissible running maximum
  `Tmax`. With the shipped constants (`EXP`, `k1 = 0.2`, `k2 = 1.5`, `alpha = 1.53e8`,
  `beta = 23.12`) `Tmax` must be at least about 7.46e5 N. A lower pretension or `Tmax0` stops at
  initialisation with the offending tension and the next admissible `Tmax`. `EXP` requires
  `k2 > 0`.
- Viscoelastic and Syrope line types require `EI = 0`; a finite-EI type is rejected.
- A Syrope line is a single section, taut at initialisation, or a composite line whose other
  sections are linear-elastic `EI = 0` sections (`composite_chain_syrope_chain.dat`), and the deck
  must set `dtM` and `TMax` (there is no static-only output). It takes the seabed, bathymetry,
  Morison loads, current, waves, host fluid fields and VIV of any `EI = 0` line.

## Run the Syrope example

`syrope_polyester_mooring.dat` reads `data/syrope/syrope_settings.dat`, which reads
`data/syrope/syrope_owc.dat`. Copy all three files together and keep their relative layout.

```powershell
New-Item -ItemType Directory -Force results | Out-Null
.\CableDyn_driver.exe .\examples\syrope_polyester_mooring.dat .\results\syrope
```

The driver does not create output folders, so the first line creates `results`.
