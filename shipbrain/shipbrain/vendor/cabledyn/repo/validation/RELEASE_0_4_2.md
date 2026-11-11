<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn v0.4.2 release record

This record lists what was built and tested for the v0.4.2 release: the source commit,
toolchains, dependency pins, test results and asset hashes. Case definitions and pass criteria
are in [`VALIDATION.md`](../VALIDATION.md). The OpenFAST and r-test pins, the 23 OpenFAST
patches and the reference LAPACK are those of [v0.4.1](RELEASE_0_4_1.md).

## Source and pins

| Item | Value |
| --- | --- |
| CableDyn | `0.4.2` (2026-11-09), C ABI 1, minor extension 4 |
| Source | The release tree (`release/0.4.2` at `98db4a5`, tree `3ff9cce`): dev with #107 to #142, the version and the experiment and L5 records of the release. The assets and the gates below were produced from this tree, or from the version commit `25bdfc1` before it, which has the same sources (the two later commits change only records and documentation); this record is added afterwards |
| OpenFAST base | `2895884d2be01862173c88d70f86b358d2f1a50a`; the 23 patches of [`integration/openfast/patches`](../integration/openfast/patches) applied to a clean checkout by `prepare_openfast_source.ps1` |
| OpenFAST r-test | `dd5feaaaa500ba7283140107806300d551cff0a7` |
| Reference LAPACK/BLAS | 3.12.1, release-tag archive with SHA-256 `2ca6407a001a474d4d4d35f3a61550156050c48016d949f0da0529c0aa052422`, built with IFX for x86-64-v3 (`/fp:precise /arch:CORE-AVX2`) |

## Toolchains

| Item | Version |
| --- | --- |
| GNU Fortran (test builds) | conda-forge GCC 16.2.0, with OpenBLAS 0.3.33 and LAPACK from the conda environment |
| Intel Fortran (Windows release) | IFX 2025.3.2, `/fp:precise /arch:CORE-AVX2 /Qfma-` (value-safe floating point, x86-64-v3, no contraction into fused multiply-adds), `/Qauto` (thread-safe local storage) |
| Microsoft C/C++ | Visual Studio 2022 (release workflow) |
| Python wheels | scikit-build-core; cibuildwheel v4.3.3 (Linux `manylinux_2_28`, macOS arm64); IFX static build on Windows (`release/build_windows_wheel.ps1`) |
| Python and packaging | Python 3.13, build 1.6.1, Twine 7.0.0 (release workflow) |

## Test results

| Gate | Result |
| --- | --- |
| GNU Release CTest, including the slow tier, on five OpenBLAS kernels (Prescott, Nehalem, Sandybridge, Haswell and Zen through `OPENBLAS_CORETYPE`; Windows, local, fresh build directory) | 405 of 406 on each kernel before the experiment rerun, the one failure being `validation_records`, which requires provenance records that name the release; it passes on the release tree. 0 compiler warnings |
| GNU Debug CTest (`-fcheck=all`), including the slow tier, with the tests' own timeouts (Windows, local, fresh build directory) | 405 of 406, the same `validation_records` row; 0 compiler warnings |
| Example fallback scan (`tests/check_example_fallbacks.py --coretype`, each kernel confirmed by name) | all 65 shipped decks, those of the `moordynC_*` folders included, run on each of the five kernels with no fallback note |
| Python package tests (local, native library and driver of the release tree) | 3016 passed, 47 skipped (platform- and tool-dependent cases) |
| Python distributions (`python -m build python`, `twine check`, release workflow) | both pass; each carries the Apache-2.0 licence; the wheel holds only `cabledyn` and its metadata |
| CI matrix of the release tree (#143 at `98db4a5`) | Linux and Windows, Release and Debug; the Prescott round-off job with the example fallback scan; Python 3.10 and 3.13 on three platforms with coverage and strict type checks; the wheel builds; Sphinx and Read the Docs; all passed. Codex review of the release tree: no findings |
| Sphinx documentation (`-W -n`) | built with no warnings |
| pre-commit, all files | passed |
| Release metadata | `check_release_metadata.py` passed (CableDyn v0.4.2, 2026-11-09) |
| Release-tree audit | Git archive of `98db4a5`: 988 files, SHA-256 `24e465c110f9ac5d7bbd5d1026b92cb9ba0eb277cec0f9eb36fdd1e91e1991d9` |
| Experimental comparisons ([`experiments`](experiments/README.md)) | Holcombe (12 cases) and Bergdahl (30 primary and 8 refinement cases) re-run with a GNU Release build of the release sources (`cabledyn.exe` SHA-256 `0ab8649f0d5532450ff5f99e8277e498ff8f8f24556ef98f46bf2d52fb5417e0`). Both reproduce their summaries, metrics and refinement figures byte for byte. Of the hashed profiles only Holcombe's two static profiles change, in their `Declination` and `Inclination` columns alone: the finite-EI node angles now come from the line's Hermite tangent (#114), which moves them by at most 3.47 deg at the ideal clamp and 0.32 deg at a discrete buoyancy module. The Bergdahl waveform comparison was not re-run (its measured series was not available); its files and metrics are those of v0.3.0, as `provenance.json` states |
| Bodies suite (102 metrics) | 102 of 102 pass with the same GNU Release build |
| OpenFAST build gate (`integration/openfast/openfast_build_gate.ps1`, a GNU double-precision OpenFAST of the release sources; the IEA-15 MW mixed `CompMooring = 5` case in still air, as no turbulent wind file is on the host) | passed: the module compiles, names itself `OpenFAST-v5.0.0-CableDyn-0.4.2` and runs 60 s with finite output |
| OpenFAST linearisation (`validation/scripts/openfast_lin_ab.py`, IEA-15 MW UMaine twin decks and a mixed cable deck) | passed with the release `openfast.exe` (single precision), its log identical to v0.4.1's: CableDyn mooring block symmetric to 7.2e-6; surge stiffness 7.721e4 N/m against MoorDyn-F's 7.716e4 N/m; dominant fairlead-block entries to 1.1e-3 and every entry above 1 % of its block to 2.9e-3; the platform 6×6 stiffness to 1.0e-3 of MoorDyn-F's quasi-static reduction; the lowest nine line-mode frequencies to 0.3 %; the mixed cable deck's point stiffness to its static solves to 1.1e-4. It also passed with the double-precision build (symmetry 7.2e-6, 6×6 to 1.0e-3, cable deck to 1.0e-4) |
| L5 wall-clock records ([`performance`](performance/README.md), `performance_records.py`, one thread, median of three runs after a warm-up) | the release driver takes 1.34 / 2.37 / 4.98 s on the 80 / 200 / 800 m lazy-wave spans (v0.4.1: 1.44 / 2.56 / 5.29 s), 4.30 s on the one-hour VolturnUS-S chain (4.44 s) and 0.197 s on the WD0050 chain (0.200 s), each with its reference response reproduced and with the solver counts of v0.4.1 |
| Wall time of the shipped examples, v0.4.1 vs the release sources (GNU Release builds, same host, one thread, OpenBLAS Haswell kernel, best of two runs in alternating order) | over the 63 decks that both run (two new decks use options v0.4.1 refuses), the geometric-mean ratio is 0.959 and the total falls from 133.2 to 121.4 s; `lazy_wave_modes.dat` takes 0.66 s instead of 4.12 s, six other finite-EI decks 7 to 22 % less, and no deck is slower by more than 5 % |

The coupled IEA-15 MW throughput figures of `VALIDATION.md` (September 2026, another host) were
not re-measured: the turbulent wind file of those runs is not on the release host. They say so
in place.

## Windows executable gates

Every gate of `build_static_windows.ps1` passed in the release workflow (`release-windows-static.yml`,
run 42620906823, on `98db4a5`; the preflight run 42611164798 on `25bdfc1` passed the same gates). The
smoke runs used a system-only `PATH`.

| Gate | Result |
| --- | --- |
| Compiler | IFX 2025.3.2 (minimum 2025.3) |
| OpenFAST solution build | one pass: 34 projects succeeded, 0 failed |
| `CableDyn_driver.exe` imports | `KERNEL32.dll`, `SHELL32.dll` and `imagehlp.dll` only; stack reserve 268,435,456 bytes; `--version` reports `Build x86-64-v3 (AVX2)` |
| `openfast.exe` imports | `KERNEL32.dll` and `imagehlp.dll` only; `-v` reports `OpenFAST-v5.0.0-CableDyn-0.4.2` |
| Processor check | both executables stop at start with exit 3 and the message on a simulated missing x86-64-v3 feature, in the workflow and again on the downloaded assets |
| Standalone smoke | the shallow-chain static deck (`chain_catenary_shallow_30m.dat`) converges |
| Memory growth over a 10x longer run | 2.6 -> 2.6 MiB (`dynamic_chain_current.dat`), 21.5 -> 21.5 MiB (`lozon_gomex80_power_cable.dat`); limit +16 MiB |
| Exit contract | a run states the exit contract after the banner; a refused input ends stderr with the closing line |
| `CompMooring = 5` smoke | CableDyn banner, `dtM` 0.025 s (one glue step), equilibrium fairlead tensions 2.437 MN, the same as v0.4.1 to every printed digit, normal termination |

## Clean-machine test

A self-contained check ran the release assets from a folder whose path holds spaces, an accented
letter and Hangul, with a system-only `PATH`. It checks the checksums of the four files and the
manifest, the start of both executables (both name 0.4.2), every shipped example deck (65, now
including the `moordynC_*` folders, each run from its own folder) with the release
`CableDyn_driver.exe`, four `CompMooring = 5` runs, and the Python wheel in a new virtual
environment, where it imports as 0.4.2 and runs the release driver. The four runs are a 70 s
JONSWAP sea with mixed chains and a cable, a 400 s line failure, a checkpoint at 30 s with a
restart whose last 10 s of output (400 rows) must be bit-identical, and a checkpoint between two
mooring steps (`dtM` = 2 `DT`, at 30.025 s) whose restart must match the rest of the run (200
rows) bit for bit. All 13 checks passed on the preflight assets and on the final assets.

## Python distribution

The PyPI distribution is built by `.github/workflows/wheels.yml`; each wheel is installed into a
clean environment and smoke-tested on its own platform (the library and the driver it carries
load and run a deck, and the driver reports the expected build). The preflight run (42620911318, on `98db4a5`)
built the files below and uploaded them to TestPyPI; the release run rebuilds them from the tag
before the upload. The Windows wheel installed from TestPyPI into a new environment has the preflight checksum and passed `release/smoke_test_wheel.py` (library, driver, build x86-64-v3).

| File | SHA-256 (preflight) |
| --- | --- |
| `cabledyn-0.4.2.tar.gz` | `046838d064ac730f2f26a969b28a3862a6dce3182ac033df5325f292aed294b5` |
| `cabledyn-0.4.2-py3-none-win_amd64.whl` | `4405bc41fc7f93ae2eaa2762ca7b4b6b8e36a8274315c9c3239b14b67ce6510a` |
| `cabledyn-0.4.2-py3-none-macosx_15_0_arm64.whl` | `8dd32c22831badb4fd536884f077b7149f10c91ff6bdc3fb9ce46114617ad39b` |
| `cabledyn-0.4.2-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl` | `e79267e0f80a091bd5aa6908a13981bdacd52221ae006e0babf44d069933cedc` |

## Assets

| File | SHA-256 |
| --- | --- |
| `CableDyn_driver.exe` | `c1a8ca25390bec4dc029aee9dd72c92d216c0f4cb26eb4c974aaf87aee734832` |
| `openfast.exe` | `53a0bb6be8311f6afc69e8ac26b529166a068cdf57cecefb90316d15d2a33f35` |
| `cabledyn-0.4.2-py3-none-any.whl` | `296126705668a120def9b5dfde3f825a6eab0ede19a35987f4b0ff84d9d39410` |
| `cabledyn-0.4.2.tar.gz` | `e1cc496568f4a4aec784250a859e3c48fe64bd64af5e3ec66a2befd412623d0d` |
