<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn v0.4.1 release record

This record lists what was built and tested for the v0.4.1 release: the source commit,
toolchains, dependency pins, test results and asset hashes. Case definitions and pass criteria
are in [`VALIDATION.md`](../VALIDATION.md). The OpenFAST and r-test pins and the reference
LAPACK are those of [v0.4.0](RELEASE_0_4_0.md); the OpenFAST patch set grows from 22 to 23.
The last section corrects one row of the v0.4.0 record.

## Source and pins

| Item | Value |
| --- | --- |
| CableDyn | `0.4.1` (2026-11-08), C ABI 1, minor extension 4 |
| Source | The release tree (`release/0.4.1` at `f8f1e1a`, tree `79d3309`): dev with #87 to #104, the version and the experiment records of the release. The assets, the local gates and the Windows gates were produced from this tree; this record is added afterwards |
| OpenFAST base | `2895884d2be01862173c88d70f86b358d2f1a50a`; the 23 patches of [`integration/openfast/patches`](../integration/openfast/patches) applied to a clean checkout by `prepare_openfast_source.ps1` |
| OpenFAST r-test | `dd5feaaaa500ba7283140107806300d551cff0a7` |
| Reference LAPACK/BLAS | 3.12.1, release-tag archive with SHA-256 `2ca6407a001a474d4d4d35f3a61550156050c48016d949f0da0529c0aa052422`, built with IFX for x86-64-v3 (`/fp:precise /arch:CORE-AVX2`) |

## Toolchains

| Item | Version |
| --- | --- |
| GNU Fortran (test builds) | conda-forge GCC 16.2.0, with OpenBLAS 0.3.34 and LAPACK from the conda environment |
| Intel Fortran (Windows release) | IFX 2025.3.2, `/fp:precise /arch:CORE-AVX2 /Qfma-` (value-safe floating point, x86-64-v3, no contraction into fused multiply-adds), `/Qauto` (thread-safe local storage) |
| Microsoft C/C++ | Visual Studio 2022 (release workflow) |
| Python wheels | scikit-build-core; cibuildwheel v4.3.3 (Linux `manylinux_2_28`, macOS arm64); IFX static build on Windows (`release/build_windows_wheel.ps1`) |
| Python and packaging | Python 3.13.17, build 1.6.1, Twine 7.0.0 (release workflow) |

## Test results

| Gate | Result |
| --- | --- |
| GNU Release CTest, including the slow tier (Windows, local, fresh build directory) | 365 of 365 passed; 0 compiler warnings |
| GNU Debug CTest (`-fcheck=all`), including the slow tier (Windows, local, fresh build directory) | 365 of 365 passed; 0 compiler warnings |
| Round-off fragility, Windows (GNU Release build of the release tree; OpenBLAS kernels Prescott, Nehalem, Sandybridge, Haswell and Zen through `OPENBLAS_CORETYPE`, each confirmed by name with `tests/check_example_fallbacks.py --coretype`) | on each kernel the full CTest passes 365 of 365 and all 54 example decks run with no fallback note (`check_example_fallbacks.py`, which matches the notes the solver prints) |
| Round-off fragility, SkylakeX (the CI round-off job with `OPENBLAS_CORETYPE=SkylakeX` on the release tree, #105; a Linux runner with AVX-512, AMD EPYC 9V74, required by the job) | the full CTest passes 358 of 358 (the Linux set) and all 54 example decks run with no fallback note. A first run landed on a runner without AVX-512 and stopped on illegal instructions; OpenBLAS names the forced kernel whether or not the processor can run it |
| Python package tests (local, native library and driver of the release tree) | 2872 passed, 47 skipped (platform- and tool-dependent cases) |
| Python distributions (`python -m build python`, `twine check`) | both pass; each carries the Apache-2.0 licence; the wheel holds only `cabledyn` and its metadata |
| CI matrix of #104 (the last change before the release tree) | Linux and Windows, Release and Debug; the Prescott round-off job; Python on three platforms with coverage and strict type checks; Sphinx; all passed |
| Sphinx documentation (`-W -n`) | built with no warnings |
| pre-commit, all files | passed |
| Release metadata | `check_release_metadata.py` passed (CableDyn v0.4.1, 2026-11-08) |
| Release-tree audit | worktree of the release tree: 944 files, SHA-256 `ae227dd5d017d0f01ed80080d4e39c955ed0601dbf9235edaf320448479c890a` |
| MoorDyn-C water kinematics (`wavekin_modes`) | MoorDyn-C v2.7.2, built for the check, reproduces the stored v2.7.1 references to 1e-16. With a 0.8 m mean level under six `WaveKin 7` components in six directions, CableDyn matches it to 1e-8 of its scale; the `WaveKin 3` record raised by 0.8 m matches to the grid tolerances (3e-7 m, 1e-4) |
| Experimental comparisons ([`experiments`](experiments/README.md)) | Holcombe (12 cases) and Bergdahl (30 primary and 8 refinement cases) re-run with a GNU Release build of the release tree (`cabledyn.exe` SHA-256 `9b86cbd5abc47d73d535f49dd5952f7805646b190a3744380d0b43849019e10f`). Both reproduce their summaries, metrics and refinement figures byte for byte. Of the hashed profiles only Holcombe's two static profiles change, in their curvature and bend-moment columns by at most 1.1e-4 relative (the geometric curvature of a stretched line). The Bergdahl waveform comparison was not re-run (its measured series was not available); its files and metrics are those of v0.3.0, as `provenance.json` states |
| Bodies suite (102 metrics) | 102 of 102 pass with a GNU Release build of the release tree |
| OpenFAST linearisation (`validation/scripts/openfast_lin_ab.py`, IEA-15 MW UMaine twin decks and a mixed cable deck) | passed with the release `openfast.exe` (single precision), its log identical to v0.4.0's: CableDyn mooring block symmetric to 7.2e-6; surge stiffness 7.721e4 N/m against MoorDyn-F's 7.716e4 N/m; dominant fairlead-block entries to 1.1e-3 and every entry above 1 % of its block to 2.9e-3; the platform 6×6 stiffness to 1.0e-3 of MoorDyn-F's quasi-static reduction; the lowest nine line-mode frequencies to 0.3 %; the mixed cable deck's point stiffness to its static solves to 1.1e-4 |
| Wall time of the shipped examples, v0.4.0 vs the release tree (GNU Release builds, same host, one thread, OpenBLAS Haswell kernel, best of two runs in alternating order) | over the 53 decks, the geometric-mean ratio is 0.967 and the total falls from 155.8 to 123.1 s; the six decks in irregular seas take 15 to 51 % less and no deck is slower |

## Windows executable gates

Every gate of `build_static_windows.ps1` passed in the release workflow (`release-windows-static.yml`,
run 42438065613). The smoke runs used a system-only `PATH`.

| Gate | Result |
| --- | --- |
| Compiler | IFX 2025.3.2 (minimum 2025.3) |
| OpenFAST solution build | one pass: 34 projects succeeded, 0 failed |
| `CableDyn_driver.exe` imports | `KERNEL32.dll`, `SHELL32.dll` and `imagehlp.dll` only; stack reserve 268,435,456 bytes; `--version` reports `Build x86-64-v3 (AVX2)` |
| `openfast.exe` imports | `KERNEL32.dll` and `imagehlp.dll` only; `-v` reports `OpenFAST-v5.0.0-CableDyn-0.4.1` |
| Processor check | both executables stop at start with exit 3 and the message on a simulated missing x86-64-v3 feature, in the workflow and again on the downloaded assets |
| Standalone smoke | the shallow-chain static deck (`chain_catenary_shallow_30m.dat`) converges |
| Memory growth over a 10x longer run | 2.6 -> 2.6 MiB (`dynamic_chain_current.dat`), 20.7 -> 20.7 MiB (`lozon_gomex80_power_cable.dat`); limit +16 MiB |
| Exit contract | a run states the exit contract after the banner; a refused input ends stderr with the closing line |
| `CompMooring = 5` smoke | CableDyn banner, `dtM` 0.025 s (one glue step), equilibrium fairlead tensions 2.437 MN, the same as v0.4.0 to every printed digit, normal termination |

## Clean-machine test

A self-contained check ran the release assets from a folder whose path holds spaces, an accented
letter and Hangul, with a system-only `PATH`. It checks the checksums of the four files and the
manifest, the start of both executables (both name 0.4.1), every shipped example deck (53) with
the release `CableDyn_driver.exe`, four `CompMooring = 5` runs, and the Python wheel in a new
virtual environment, where it imports as 0.4.1 and runs the release driver. The four runs are a
70 s JONSWAP sea with mixed chains and a cable, a 400 s line failure, a checkpoint at 30 s with a
restart whose last 10 s of output (400 rows) must be bit-identical, and, new in 0.4.1, a
checkpoint between two mooring steps (`dtM` = 2 `DT`, at 30.025 s) whose restart must match the
rest of the run (200 rows) bit for bit. All 13 checks passed.

## Python distribution

The PyPI distribution is built by `.github/workflows/wheels.yml`; each wheel is installed into a
clean environment and smoke-tested on its own platform (the library and the driver it carries
load and run a deck, and the driver reports the expected build). The preflight run (42438067968)
built the files below and uploaded them to TestPyPI; the release run rebuilds them from the tag
before the upload. The Windows wheel installed from TestPyPI into a new environment has the
preflight checksum and passed `release/smoke_test_wheel.py` (library, driver, build x86-64-v3).

| File | SHA-256 (preflight) |
| --- | --- |
| `cabledyn-0.4.1.tar.gz` | `a442878a37649e317e7765d94513a8f0fcadba581bd9baba154d224759d0ca52` |
| `cabledyn-0.4.1-py3-none-win_amd64.whl` | `a9edeaabb979bb41b64e2655482f46b45464644b19821068ac3d2f732af354a2` |
| `cabledyn-0.4.1-py3-none-macosx_15_0_arm64.whl` | `a6972b6fb1035e4221a02c0a9fc32e3db2f14a16d5bc9b17c9debd33e1649e87` |
| `cabledyn-0.4.1-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl` | `19420f17d4cfc3af07b48a6d675ab119ec9b581a9e1b67d79f7695ec86add063` |

## Assets

| File | SHA-256 |
| --- | --- |
| `CableDyn_driver.exe` | `30020098b7b2df3664955a0e5288b89f397a5ffae0bf93bf994a935b583010f8` |
| `openfast.exe` | `e92f7311483771295165acc909e30fcee6d0bd69436cfaebf174511bc0a795e6` |
| `cabledyn-0.4.1-py3-none-any.whl` | `6d92659c7fb7b4dd0a6abf230aaca2d940c189387880a86e93f7b12ab131d22b` |
| `cabledyn-0.4.1.tar.gz` | `2a5e963d512774d493fb27370ef7806cc47660a2298217764a2f781fe3bb79d4` |

## Correction to the v0.4.0 record

The round-off fragility row of [the v0.4.0 record](RELEASE_0_4_0.md) states that the full CTest
passed on six OpenBLAS kernels and that all 53 examples ran "with no fallback, stall or
relaxed-tolerance note" on each. Two parts of that were not shown by the checks run for it:

- **SkylakeX was not run.** The Windows conda-forge OpenBLAS accepts
  `OPENBLAS_CORETYPE=SkylakeX` and silently runs its Haswell kernel, on a processor with AVX-512
  too, so the SkylakeX row repeated Haswell. `tests/check_example_fallbacks.py --coretype` now
  asks OpenBLAS to name the kernel it loaded and fails on a mismatch. SkylakeX was first run for
  real on a Linux runner on 2026-11-08 (#103, dev at `cf5d48a`): CTest 358 of 358 and 54
  example decks with no fallback note. The v0.4.0 evidence is therefore five kernels.
- **The scan could not see the relaxed-tolerance note.** It searched the console for "looser
  tolerance", which the solver does not print; the note reads "residual floor above". The
  corrected scan (`check_example_fallbacks.py`, also run by the CI round-off job) found every
  example clean on all five Windows kernels and on SkylakeX at `cf5d48a`, and does so for the
  release tree above.

No result of v0.4.0 changes: the corrected checks pass on the same examples. The same record
also gives the `CompMooring = 5` smoke tensions as 2.436 MN; its workflow printed 2.43712E+06 N,
which is 2.437 MN.
