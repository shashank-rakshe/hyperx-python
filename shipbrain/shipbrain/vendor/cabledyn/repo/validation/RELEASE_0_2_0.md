<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn v0.2.0 release record

This record lists what was built and tested for the v0.2.0 release: the source commit,
toolchains, dependency pins, test results and asset hashes. Case definitions and pass criteria
are in [`VALIDATION.md`](../VALIDATION.md). The OpenFAST and r-test pins and the reference
LAPACK are those of [v0.1.1](RELEASE_0_1_1.md).

## Source and pins

| Item | Value |
| --- | --- |
| CableDyn | `0.2.0` (2026-10-20), C ABI 1, minor extension 2 |
| Source | The `v0.2.0` tag. The assets and the Windows gates were produced from this tree before this record was completed; every other file is identical. The GNU gates below ran on the release-preparation tree (#30). The later changes (#31, the seabed recompute check; and, on the release branch, the crease bound of `CD_Bathymetry_Max_Floor`, the per-line friction options of the Python `DeckModel`, and the monotone touchdown parabola) passed the CI matrix (Linux and Windows, Release and Debug; Python on three platforms with coverage and strict type checks) and the GNU Release and Python suites |
| OpenFAST base | `2895884d2be01862173c88d70f86b358d2f1a50a`; the 20 patches of [`integration/openfast/patches`](../integration/openfast/patches) applied to a clean checkout by `prepare_openfast_source.ps1` |
| OpenFAST r-test | `dd5feaaaa500ba7283140107806300d551cff0a7` |
| Reference LAPACK/BLAS | 3.12.1, release-tag archive with SHA-256 `2ca6407a001a474d4d4d35f3a61550156050c48016d949f0da0529c0aa052422` |

## Toolchains

| Item | Version |
| --- | --- |
| GNU Fortran (test builds) | conda-forge GCC 16.2.0, with OpenBLAS and LAPACK from the conda environment |
| Intel Fortran (Windows release) | IFX 2025.3.2 |
| Microsoft C/C++ | MSVC 14.44.35207 (`cl` 19.44.35229), Visual Studio 2022, Windows SDK 10.0.22621.0 |
| CMake and Ninja | 4.4.4 and 1.13.2 (local test builds) |
| Python and packaging | Python 3.13.16, build 1.6.1, setuptools 84.2.0, Twine 7.0.0 (release workflow) |

## Test results

| Gate | Result |
| --- | --- |
| GNU Release build | 0 compiler warnings in the library, the standalone driver and the OpenFAST module; 169 in the test programs, all reviewed (see below) |
| GNU Release CTest, including the slow tier | 293 of 293 passed |
| GNU Debug build (`-fcheck=all`) | 0 compiler warnings in the library, driver and module |
| GNU Debug CTest | 293 of 293 passed |
| GNU Debug CTest with `-finit-real=snan -finit-integer=-2147483647 -fcheck=all` | 293 of 293 passed |
| Python package tests, native library and driver included | 2105 passed; 99.01% branch coverage (minimum 95%), on the release head |
| Ruff, Ruff format and mypy (strict) | passed |
| Sphinx documentation, HTML and EPUB (`-W -n`) | built with no warnings |
| pre-commit, all files | passed |
| Release metadata and release-tree audits | `check_release_metadata.py` passed; `audit_release_tree.py` passed on the working tree and on `--archive-ref HEAD` |
| OpenFAST-tree build gate (`integration/openfast/openfast_build_gate.ps1 -Clean`, GNU CMake build of the patched OpenFAST base) | the CableDyn module compiled from a clean tree, identified itself and ran a 60 s `CompMooring = 5` smoke of the mixed IEA-15 deck (three chain lines and a 248-element finite-EI power cable) with finite output |
| OpenFAST linearisation (`validation/scripts/openfast_lin_ab.py`) | passed: per-fairlead stiffness within 0.07-0.11% of stock MoorDyn (0.29% for the transverse term), platform 6x6 diagonals within 0.11%, gate 0.5% |
| Experimental comparisons ([`experiments`](experiments/README.md)) | Holcombe (12 cases) and Bergdahl (30 primary and 8 refinement cases) re-run with a GNU Release build of 0.2.0: the Holcombe results and the Bergdahl force matrix and refinement are reproduced byte for byte; the Bergdahl waveform RMSEs, now computed from the article supplement, are 5.93% and 2.56% (5.95% and 2.54% before), against a limit of 6.5% |

The warnings of the test programs are gfortran false positives and deliberate comparisons:
"used uninitialized" reports on the default initialisation of local derived-type variables with
allocatable components, subscripts of loops whose out-of-range iterations a guard skips, and
exact real comparisons in bit-identity assertions.

## Windows executable gates

Every gate of `build_static_windows.ps1` passed in the release workflow (`release-windows-static.yml`,
run 39484701335). The smoke runs used a system-only `PATH`.

| Gate | Result |
| --- | --- |
| Compiler | IFX 2025.3.2 (minimum 2025.3) |
| OpenFAST solution build | 0 errors in all 34 projects; the CableDyn project with 0 warnings |
| `CableDyn_driver.exe` imports | `KERNEL32.dll`, `SHELL32.dll` and `imagehlp.dll` only; stack reserve 268,435,456 bytes |
| `openfast.exe` imports | `KERNEL32.dll` and `imagehlp.dll` only |
| Standalone smoke | the shallow-chain static deck (`chain_catenary_shallow_30m.dat`) converges |
| Memory growth over a 10x longer run | 5.0 -> 5.0 MiB (`dynamic_chain_current.dat`), 21.2 -> 21.2 MiB (`lozon_gomex80_power_cable.dat`); limit +16 MiB |
| Exit contract | a run states the exit contract after the banner; a refused input ends stderr with the closing line |
| `CompMooring = 5` smoke | CableDyn banner, `dtM` 0.025 s (one glue step), equilibrium fairlead tensions 2.437 MN, normal termination |

## Clean-machine test

A self-contained check ran the release assets from a folder whose path holds spaces, an accented
letter and Hangul, with a system-only `PATH`. It checks the checksums of the four files and the
manifest, the start of both executables, 13 standalone decks (the torsion example included),
three `CompMooring = 5` runs (a 70 s JONSWAP sea, a 400 s line failure, and a checkpoint at 30 s
with a restart whose last 10 s of output must be bit-identical), and the Python wheel in a new
virtual environment, where it imports as 0.2.0 and runs the release driver. All 26 checks
passed. Every shipped example deck (51) also runs to completion with the release
`CableDyn_driver.exe`.

The first build of the assets stopped `examples/buoy_clamped_cable.dat` in this check: the
setup check of the seabed recompute inputs compared two products that the optimised Intel
build rounds differently. The fix (#31) accepts agreement within 8 units in the last place. The
review of the release found three more defects, fixed on the release branch: the seabed bound
of the explicit object sub-step estimate left out the crease rounding of neighbouring cells, the
Python `DeckModel` did not rename or remove the per-line friction options with their line, and the
touchdown point could jump by almost an element as a node grounded on a steep stencil (its
parabola is now limited to rise monotonically over the element). The assets above were built from
the final tree.

## Assets

| File | SHA-256 |
| --- | --- |
| `CableDyn_driver.exe` | `3eb0727e9a329f155de8aad2dd68ba280985b35a2c9482236930ee007ddbcc89` |
| `openfast.exe` | `1ba18e46d4b00e7c5340534add6d6c179b8e3e2dd9645b553fcc9035dece77f9` |
| `cabledyn-0.2.0-py3-none-any.whl` | `8bc843121685e6a9e0af877765f6d1d0a9e7de47c6ab0c5361a2f644eeb0ac73` |
| `cabledyn-0.2.0.tar.gz` | `b1034bcd4fff0e690f9635121807f0f41693c16be0de1caf9af4426af127dc7b` |
