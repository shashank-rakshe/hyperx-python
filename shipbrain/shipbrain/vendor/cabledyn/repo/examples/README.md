<!-- SPDX-License-Identifier: Apache-2.0 -->

# Example input decks

This directory is for users who want a runnable starting point for their own CableDyn model.
Every deck runs as shipped. The annotated catalogue, with the solver route and run time of each
deck, is [doc/examples.rst](../doc/examples.rst); guided walkthroughs are in
[doc/tutorials.rst](../doc/tutorials.rst).

## Run a deck

From the repository root, with the Windows release executable:

```powershell
New-Item -ItemType Directory -Force results | Out-Null
.\CableDyn_driver.exe .\examples\spread_3line_chain.dat .\results\spread
```

The driver does not create output folders, so the first line creates `results`. A source build
produces `build/cabledyn` (`build\cabledyn.exe` on Windows, or `build\bin\cabledyn.exe` for a
MinGW build that stages its runtime DLLs), which takes the same arguments:

```sh
mkdir -p results
build/cabledyn examples/spread_3line_chain.dat results/spread
```

## Choose a starting deck

- `cabledyn_options_reference.dat` lists the common OPTIONS keywords, with defaults active and
  alternatives commented in place. The full keyword list, with meanings and units, is in
  [doc/options.rst](../doc/options.rst).
- The deck grammar is in [doc/driver_format.md](../doc/driver_format.md); output channels are in
  [doc/outputs.rst](../doc/outputs.rst).
- Synthetic-rope models (`ve_*`, `syrope_*`) are summarised in
  [SYNTHETIC_ROPES.md](SYNTHETIC_ROPES.md).

Copy a deck under a new name and keep every file it references at the same relative path.

## Directory layout

| Path | Contents |
| --- | --- |
| `*.dat` | Standalone decks. `iea15mw_umaine_openfast_cabledyn.dat` is an OpenFAST-only `MooringFile`; `iea15mw_umaine_mixed_cabledyn.dat` runs both standalone and coupled. |
| `openfast/` | IEA-15MW VolturnUS-S `.fst` pair (`CompMooring = 5` and `3`) with their mooring decks; see [openfast/README.md](openfast/README.md). |
| `data/syrope/` | Syrope settings and original working-curve table used by `syrope_polyester_mooring.dat` and `composite_chain_syrope_chain.dat`. |
| `data/lozon/` | Prescribed hang-off heave history for `lozon_gomex80_power_cable_motion.dat` and `torsion_free_end_armoured_cable.dat`, and the script that generates it. |
| `data/vessel/` | 6-DOF vessel-motion record for `lazy_wave_vessel_motion.dat`, `composite_chain_syrope_chain.dat` and `lazy_wave_modules_stiffener.dat`, the script that generates it, and the illustrative RAO table for `lazy_wave_vessel_rao.dat`, `lazy_wave_bend_stiffener.dat` and `composite_ve_syrope_jonswap.dat`. |
| `data/torsion/` | Hang-off roll history (motionFile roll column) for `torsion_lazy_wave_hangoff_twist.dat` and the script that generates it. |
| `data/range_tdp/` | Fairlead surge history for `chain_range_tdp.dat` and `chain_sloped_bathymetry_friction.dat`, and the script that generates it. |
| `data/shared/` | Hang-off motions of both ends of `shared_cable_two_floaters.dat` and the script that generates them. |
| `data/bathymetry/` | The `x y depth` seabed grid of `chain_sloped_bathymetry_friction.dat`. |
| `moordynC_wavekin/` | A deck with the MoorDyn-C `wave_frequencies.txt` and `current_profile.txt` files it reads from its own folder. |
| `moordynC_currents/` | Two decks with the MoorDyn-C `wave_elevation.txt`, `current_profile_dynamic.txt` and `current_profile_4d.txt` files they read from their own folder (`WaveKin 3`, `Currents 2` and `5`), and the script that generates the files. |
| `plot_range_envelope.py` | Plots the tension envelope of a range-graph file (`python plot_range_envelope.py <out_root>`). |

Files under `data/` are inputs referenced by decks; do not pass them to an executable.

## Accidental limit state: a broken mooring line

`als_volturnus_line_break_time.dat` and `als_volturnus_line_break_tension.dat` model the
IEA-15MW VolturnUS-S as one free `Rigid6` body on its three 850 m chains. Mass, centre of
gravity, inertias, displacement and waterplane stiffness come from the OpenFAST model; the drag
area and the linear damping that stands in for radiation damping are assumptions, and the body
has no wave drift force. Use the decks to screen a line failure, and the coupled OpenFAST route
([openfast/README.md](openfast/README.md)) for design.

A constant 2 MN force toward azimuth 60° stands in for the mean rotor thrust, and a JONSWAP sea
(Hs 6 m, Tp 11 s) travels the same way, so line 3 is the windward line. A `FAILURE` row detaches
line 1 from its fairlead, at t = 300 s in the first deck and when its fairlead tension first
reaches 3.0 MN (t = 240.7 s) in the second. The detached end falls freely, and the platform moves
to a new equilibrium on lines 2 and 3. Each deck simulates 1800 s in about 50 s.

| Result (time-triggered deck) | Intact, 100–300 s | After the break |
| --- | --- | --- |
| Line 3 (windward) fairlead tension, mean / peak | 4.34 / 12.53 MN | 3.57 / 12.73 MN |
| Line 2 fairlead tension, mean / peak | 1.98 / 3.51 MN | 1.27 / 2.67 MN |
| Platform horizontal offset, mean / peak | 23.4 / 37.0 m | 62.2 / 70.6 m |

After the break the platform settles 62 m from its origin, toward azimuth 137°, and turns 3.4° in
yaw; the means after the break are over 1200–1800 s. The peak on line 2 is the transient 17 s
after the break. In the tension-triggered deck the line breaks in the wave group that loads it,
so line 2 peaks higher, at 3.35 MN 11 s after the break; the line 3 peak, the peak offset and the
new mean offset are the same as above to the digits shown.

The peak tension on the intact lines is converged in `dtM`: 12.762, 12.727, 12.718 and 12.716 MN
at `dtM` = 0.1, 0.05, 0.025 and 0.0125 s, with the same 70.6 m peak offset. When the thrust
and the waves act toward −X instead, line 1 is the only windward line: after it breaks, the two
remaining anchors lie behind the platform, which drifts about 810 m before lines 2 and 3 hold it.
A three-line mooring has no redundancy against the loss of its windward line.

## Lozon reference decks

The seven `lozon_*` decks take their dimensions and static properties from Lozon et al. (2025),
*Ocean Engineering* 322:120473. The paper gives only the static `EA` of the polyester sections.
The dynamic stiffness and dashpots in the 200 m and 800 m mooring decks are taken from
CableDyn's MoorDyn viscoelastic validation case and are labelled as such in each deck; do not
cite them as values from the paper.

## Torsion

`torsion_lazy_wave_hangoff_twist.dat` is the Gulf of Mexico 80 m lazy-wave cable with an
illustrative torsional stiffness `GJ` of 50 kN·m², clamped and restrained in torsion at both
ends through the `END CONNECTIONS` torsion columns. The `motionFile` roll column twists the
hang-off by two turns over 60 s; the run then holds the twist for 30 s. The torque settles at
3.54 kN·m: the cable writhes 3.3 m out of its plane and takes up 30° of the 720° itself. The
deck grammar is in [doc/driver_format.md](../doc/driver_format.md) and the model in the
torsion section of [doc/theory.rst](../doc/theory.rst).
