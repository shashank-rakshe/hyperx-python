<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn

[![Release](https://img.shields.io/github/v/release/SMI-Lab-Inha/CableDyn?sort=semver)](https://github.com/SMI-Lab-Inha/CableDyn/releases/latest)
[![Fortran CI](https://github.com/SMI-Lab-Inha/CableDyn/actions/workflows/fortran.yml/badge.svg)](https://github.com/SMI-Lab-Inha/CableDyn/actions/workflows/fortran.yml)
[![Python CI](https://github.com/SMI-Lab-Inha/CableDyn/actions/workflows/python.yml/badge.svg)](https://github.com/SMI-Lab-Inha/CableDyn/actions/workflows/python.yml)
[![Documentation](https://img.shields.io/readthedocs/cabledyn/latest?label=docs)](https://cabledyn.readthedocs.io/en/latest/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![DOI](https://img.shields.io/badge/DOI-10.1016%2Fj.oceaneng.2026.128332-blue.svg)](https://doi.org/10.1016/j.oceaneng.2026.128332)

CableDyn is an open-source, geometrically exact finite-element solver for the static and
dynamic analysis of mooring lines and dynamic power cables. It resolves what a power cable is
designed against: the curvature along the line, under a bend stiffener, through a lazy wave and
across a moving touchdown, together with tension, torque and twist. Strain and curvature are the
exact large-deformation measures, never linearised, so slack and snap, large rotations and a line
lifting off the seabed lie inside the formulation.

It runs as a standalone program, as a mooring module of OpenFAST and FAST.Farm
(`CompMooring = 5`), through a C interface, or from Python.
The current stable release is `v0.4.2`; interfaces are versioned and may change before `1.0.0`.

## What CableDyn does

- **Finite-element cables with real bending stiffness.** Cubic-Hermite elements carry position
  and tangent at every node, so the slope is continuous along the line, and the deflection of a
  beam under its weight converges at fourth order with the mesh (measured slope 3.99).
  Tension-only `EI = 0` elements serve chains, wire and fibre ropes in the same model.
- **An implicit solver.** Generalised-alpha integration with consistent mass and automatic step
  subdivision: a snap load stays within 1.5 % of a 0.5 ms reference at a 20 ms step, where an
  explicit lumped-mass step must stay near 1 ms.
- **Bend stiffeners and section curvature.** Tapered stiffener sleeves with their own mass,
  buoyancy and drag; the curvature of the section, its two components on the section's own axes
  (`CurvX`, `CurvY`) and the moments of the cable and of the sleeve, for fatigue.
- **Torsion.** A twist angle and polar inertia at every node, torque–tension coupling for
  armoured cables, the buckling onset of a twisted line, and end restraints that are rigid,
  elastic or free in twist.
- **Statics that start from the geometry alone.** No seed files: a catenary start, continuation in
  bending stiffness and buoyancy, mesh sequencing and refinement to the bending length solve hard
  lazy waves, long grounded runs, bathymetry and friction held as laid; a deck that has no
  equilibrium stops with a named reason.
- **Coupled analysis.** OpenFAST and FAST.Farm coupling with checkpoint restart at any step, the
  host's waves and current at every node, active line control, line failure, and linearisation
  that carries the line dynamics as states.
- **More analyses.** Natural modes and shapes, cross-flow vortex-induced vibration of chains and
  cables, viscoelastic and Syrope fibre ropes, buoyancy modules, clumps, rigid bodies and rods,
  range graphs and seabed contact channels.
- **In-process hosts.** The C API and Python step a deck from a CFD code or a script, with the
  host's fluid field at every node, saved and restored states and whole-line reads in one call.

## Evidence

Every capability above is tested, and the comparisons are published with their data and scripts
in the [validation record](https://cabledyn.readthedocs.io/en/latest/validation.html). A
selection:

| Case | Reference | Result |
|---|---|---|
| Large-deflection elastica | Bisshopp–Drucker closed form | error 1.9e-6 |
| Lazy-wave cables at 80, 200 and 800 m, static | OrcaFlex 11.6d | peak curvature within 0.08, 0.26 and 4.8 % |
| Installed 800 m lazy-wave cable | OrcaFlex 11.6d | peak curvature 0.06 %, hang-off tension 0.15 % |
| Lazy wave in an irregular sea | OrcaFlex 11.6d, same 80-component sea | curvature 0.21 %, tension 0.20 % |
| Moving touchdown under heave | OrcaFlex 11.6d | curvature within 0.6 %, touchdown point within 0.08 m |
| Tapered bend stiffener at a clamped hang-off | OrcaFlex 11.6d | curvature 0.45 % of its root value, moments 0.01 % |
| Lazy-wave cable twisted five turns | OrcaFlex 11.6d | torque 0.019 %, peak curvature 0.049 % |
| One-hour VolturnUS-S chain mooring | OrcaFlex 11.6d | fairlead tension mean 0.27 %, standard deviation 0.26 % |
| Holcombe lazy-wave model test | measured geometry | position error 1.1–1.9 % of the suspended length |
| Bergdahl dynamic chain test, 30 conditions | measured end force | correlation 0.993 |
| IEA 15 MW VolturnUS-S in OpenFAST with a power cable | OpenFAST with MoorDyn | platform motions within 0.6 % |

Run times on one processor thread, same host and protocol, with the timing scripts in
[`validation/performance`](https://cabledyn.readthedocs.io/en/latest/validation.html):

| Case | CableDyn 0.4.2 | OrcaFlex 11.6d |
|---|---|---|
| 80 / 200 / 800 m lazy-wave spans, 60 s of heave | 1.3 / 2.4 / 5.0 s | 2.7 / 5.3 / 27.8 s |
| One-hour VolturnUS-S chain mooring | 4.3 s | 19.7 s |

The method and the lazy-wave comparisons are peer-reviewed
([Ocean Engineering 368, 128332, 2026](https://doi.org/10.1016/j.oceaneng.2026.128332)).
Unsupported combinations stop with a named error rather than running approximately.

## Quick start

1. Download from the
   [latest release](https://github.com/SMI-Lab-Inha/CableDyn/releases/latest):

   | Asset | Contents |
   |---|---|
   | `CableDyn_driver.exe` | Standalone solver for Windows x64 (AVX2 processor) |
   | `openfast.exe` | OpenFAST with CableDyn available as `CompMooring = 5` |
   | `cabledyn-0.4.2-py3-none-any.whl` | Python package (pre- and post-processing, batch runs) |
   | `cabledyn-0.4.2.tar.gz` | Python source distribution |
   | `SHA256SUMS.txt` | Checksums for the assets above |

   Both executables are statically linked, need no installer, compiler, or runtime
   DLLs, and run on Windows 10 (version 1903 or later) and Windows 11, from folders
   named in any script. A turbine controller used by an OpenFAST model still needs
   its own `DISCON.dll`. The example decks are in the `examples` folder of the
   release's **Source code (zip)** archive: unzip it and copy `examples` next to the
   executables.

2. Verify the download (compare with `SHA256SUMS.txt`):

   ```powershell
   Get-FileHash CableDyn_driver.exe -Algorithm SHA256
   ```

3. Solve an example deck. The driver finds the static equilibrium, then runs the
   dynamics when the deck sets `dtM` and `TMax`:

   ```powershell
   .\CableDyn_driver.exe examples\wd0050_chain.dat wd0050
   ```

   Results are written to `wd0050.out` and related tables in the current folder.
   The driver does not create folders: an output root such as `results\wd0050`
   needs `New-Item -ItemType Directory -Force results | Out-Null` first.

4. Optionally, script runs from Python. The package on PyPI carries the solver
   library and the driver (wheels for Windows x64 and Linux x86-64 with an AVX2
   processor, and macOS 15 or newer on Apple silicon), so nothing else is needed. A relative
   output root is resolved against the deck's folder, so this run writes
   `examples\wd0050.out`:

   ```powershell
   python -m pip install "cabledyn[post]"
   cabledyn-run examples\wd0050_chain.dat wd0050
   ```

   The pure Python wheel on the release page (`cabledyn-0.4.2-py3-none-any.whl`)
   carries no driver: `cabledyn-run` then needs `--executable .\CableDyn_driver.exe`,
   the `CABLEDYN_DRIVER` environment variable, or the driver on `PATH`. A source
   build names the driver `cabledyn` (see [Build from source](#build-from-source));
   the release executable is `CableDyn_driver.exe`.

For OpenFAST, set `CompMooring = 5` in the `.fst` file and point `MooringFile` at
a CableDyn deck; ready-to-run cases are in
[`examples/openfast`](https://cabledyn.readthedocs.io/en/latest/tutorial_openfast.html). Every shipped deck is listed
in [`examples/`](https://cabledyn.readthedocs.io/en/latest/examples.html).

Coming from MoorDyn: CableDyn reads decks written in the MoorDyn v2 format (its section and
keyword names), so an existing mooring model runs as it is and can then take finite-EI sections,
stiffeners and the other features above; the
[migration guide](https://cabledyn.readthedocs.io/en/latest/migrating.html) lists the differences.

## Documentation

The manual at <https://cabledyn.readthedocs.io> covers installation, tutorials,
the deck format, options, outputs, theory, OpenFAST coupling, the C API, Python,
validation, and troubleshooting.

## Build from source

```powershell
conda env create -f environment.yml
conda activate cabledyn
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build -L fortran -LE slow --output-on-failure
```

The driver is `build/cabledyn` (`build\bin\cabledyn.exe` with the conda toolchain
on Windows); the release
ships the same program as `CableDyn_driver.exe`.

See the [development guide](https://cabledyn.readthedocs.io/en/latest/development.html)
for the full test suite, the Python package, and the OpenFAST build; the source
layout is described in the architecture notes in the repository.

## Validation

CableDyn is verified against analytical solutions and compared with MoorDyn,
OrcaFlex, two physical experiments (Holcombe lazy-wave, Bergdahl dynamic chain),
the IEA 15 MW VolturnUS-S reference systems, and coupled OpenFAST runs. Results,
acceptance criteria, and reproduction commands are in
the [validation record](https://cabledyn.readthedocs.io/en/latest/validation.html); data and scripts are in
[`validation/`](https://cabledyn.readthedocs.io/en/latest/validation.html).

## Repository layout

| Directory | Contents |
|---|---|
| `app/` | Standalone driver (`CableDyn_driver.exe`) |
| `src/` | Solver core, C interface, OpenFAST module |
| `python/` | Python package |
| `tests/` | CTest unit, integration, and validation tests |
| `doc/` | Sphinx manual |
| `examples/` | Standalone and OpenFAST input decks |
| `integration/openfast/` | OpenFAST patch series and build scripts |
| `release/` | Release checks and the static Windows build |
| `validation/` | Validation records, reference data, and scripts |

## Citation

If you use CableDyn in academic work, please cite:

> J. H. Seo, J. Lim, K. Shim, J. Song. CableDyn: Curvature-resolving implicit
> finite-element analysis of mooring lines and dynamic power cables for floating
> offshore wind. *Ocean Engineering* 368 (Part 2), 128332, 2026.
> <https://doi.org/10.1016/j.oceaneng.2026.128332>

To identify the software version, also cite the release (CableDyn 0.4.2).
The [citation file](https://cabledyn.readthedocs.io/en/latest/citing.html) contains both entries (GitHub **Cite this
repository**); BibTeX is on the manual's
[How to cite](https://cabledyn.readthedocs.io/en/latest/citing.html) page.

## Contributing and support

Questions, bug reports, and feature requests are welcome in
[GitHub Issues](https://github.com/SMI-Lab-Inha/CableDyn/issues); the
support notes in the repository say where each belongs. Read the
[contributing guide](https://cabledyn.readthedocs.io/en/latest/contributing.html)
before opening a pull request. Everyone taking part is expected to follow the
[Code of Conduct](https://github.com/SMI-Lab-Inha/CableDyn?tab=coc-ov-file). Report
security issues privately as described in the
[security policy](https://github.com/SMI-Lab-Inha/CableDyn/security/policy).

If you extend or fix CableDyn in your own copy, please consider contributing the
change here, so that every user benefits and the validation record stays in one
place.

CableDyn is research software. Users are responsible for model selection,
convergence checks, and compliance with the design codes that govern their work.

Maintainer: Prof. Jae Hoon Seo, Department of Naval Architecture and Ocean
Engineering, Inha University, Republic of Korea, <jaehoon.seo@inha.ac.kr>

## Acknowledgements

CableDyn builds on the work of others, and we are grateful to the developers and
maintainers of MoorDyn (Hall et al.), whose open input format CableDyn reads and
which serves as a comparison reference; of OpenFAST (NLR), which hosts CableDyn as
a mooring module; and of OrcaFlex, the industry reference used for many of the comparisons
in the [validation record](https://cabledyn.readthedocs.io/en/latest/validation.html). OrcaFlex is a product of Orcina Ltd.

## License and name

CableDyn is distributed under the Apache License 2.0. See [LICENSE](LICENSE) and
[NOTICE](NOTICE).

"CableDyn" identifies the official project in this repository. Modified versions
are welcome under the licence, but, as Section 6 of the Apache License 2.0
provides, they may not use the name in a way that implies they are the official
CableDyn or endorsed by its maintainers; describing a work as "based on CableDyn"
is fine.

This software is developed independently at the Department of Naval Architecture
and Ocean Engineering, Inha University. It is not affiliated with, derived from,
or endorsed by the EPSRC-funded research project (2022–2025) of the same name
led by the University of Edinburgh, "CableDyn: Subsea Power Cable Dynamics Under
Complex Ocean Environment" ([cabledyn.eng.ed.ac.uk](https://cabledyn.eng.ed.ac.uk)).
