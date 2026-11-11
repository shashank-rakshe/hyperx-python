<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn v0.3.0 release record

This record lists what was built and tested for the v0.3.0 release: the source commit,
toolchains, dependency pins, test results and asset hashes. Case definitions and pass criteria
are in [`VALIDATION.md`](../VALIDATION.md). The OpenFAST and r-test pins and the reference
LAPACK are those of [v0.2.0](RELEASE_0_2_0.md).

## Source and pins

| Item | Value |
| --- | --- |
| CableDyn | `0.3.0` (2026-10-23), C ABI 1, minor extension 2 |
| Source | The release-preparation tree (`release/0.3.0` at `b9c01eb`): dev with #43 to #47 and the version and documentation changes of the release. The assets and the Windows gates were produced from this tree; afterwards only this record and the two experimental `provenance.json` files changed, which no build reads |
| OpenFAST base | `2895884d2be01862173c88d70f86b358d2f1a50a`; the 20 patches of [`integration/openfast/patches`](../integration/openfast/patches) applied to a clean checkout by `prepare_openfast_source.ps1` |
| OpenFAST r-test | `dd5feaaaa500ba7283140107806300d551cff0a7` |
| Reference LAPACK/BLAS | 3.12.1, release-tag archive with SHA-256 `2ca6407a001a474d4d4d35f3a61550156050c48016d949f0da0529c0aa052422`, now built for x86-64-v3 (`/arch:CORE-AVX2`) like the CableDyn core |

## Toolchains

| Item | Version |
| --- | --- |
| GNU Fortran (test builds) | conda-forge GCC 16.2.0, with OpenBLAS and LAPACK from the conda environment |
| Intel Fortran (Windows release) | IFX 2025.3.2, `/arch:CORE-AVX2 /Qfma-` (x86-64-v3, no contraction into fused multiply-adds) |
| Microsoft C/C++ | Visual Studio 2022, Windows SDK 10.0.22621.0 (release workflow) |
| Python wheels | scikit-build-core; cibuildwheel v4.3.3 (Linux `manylinux_2_28`, macOS arm64); IFX static build on Windows (`release/build_windows_wheel.ps1`) |
| Python and packaging | Python 3.13.16, build 1.6.1, Twine 7.0.0 (release workflow) |

## Test results

| Gate | Result |
| --- | --- |
| GNU Release CTest, including the slow tier (Windows, local) | 298 of 298 passed on the release tree |
| Python package and repository tests (local, native library and driver included) | 2052 passed, 114 skipped (platform- and tool-dependent cases) |
| CI matrix of #47 (the last change before the release tree) | Linux and Windows, Release and Debug; Python on three platforms with coverage and strict type checks |
| Sphinx documentation (`-W -n`) | built with no warnings |
| pre-commit, all files | passed |
| Release metadata | `check_release_metadata.py` passed (CableDyn v0.3.0, 2026-10-23) |
| Robustness campaigns (2026-10-15 decks, re-run on dev with #46) | 356 static cases, the 384-case rough-seabed sweep and 776 dynamic runs completed; no pass became a failure. Statics failures 47 -> 41, the rough sweep converges 192/192 for finite-EI lines (153 before), dynamic failures and time-outs 77 -> 43 |
| Experimental comparisons ([`experiments`](experiments/README.md)) | Holcombe (12 cases) and Bergdahl (30 primary and 8 refinement cases) re-run with a GNU Release build of the release tree (`cabledyn.exe` SHA-256 `5f1d3b15b414ce7b7eb884db76e50901da6a0094c5548489f58cbfed7ac0546a`): every summary, metric and refinement result is reproduced byte for byte |
| Bodies suite (102 metrics) | 102 of 102 pass with a GNU Release build of dev with #46 |
| All shipped examples, dev vs the release tree (GNU) | all 51 run; 85 of 99 output files bit-identical; the others differ in touchdown node values of static profiles and range graphs (#47, at most 1.8 % of a channel's range); no time series changes |

## Windows executable gates

Every gate of `build_static_windows.ps1` passed in the release workflow (`release-windows-static.yml`,
run 39898803772). The smoke runs used a system-only `PATH`.

| Gate | Result |
| --- | --- |
| Compiler | IFX 2025.3.2 (minimum 2025.3) |
| OpenFAST solution build | the first pass stopped in the NWTC library with the intermittent IFX parallel-compilation failure the script resumes after (`build_static_windows.ps1`); the resumed build compiled the 31 remaining projects with 0 errors |
| `CableDyn_driver.exe` imports | `KERNEL32.dll`, `SHELL32.dll` and `imagehlp.dll` only; stack reserve 268,435,456 bytes; `--version` reports `Build x86-64-v3 (AVX2)` |
| `openfast.exe` imports | `KERNEL32.dll` and `imagehlp.dll` only; reports `CableDyn build: x86-64-v3 (AVX2).` |
| Processor check | both executables stop at start with exit 3 and the message on a simulated missing x86-64-v3 feature |
| Standalone smoke | the shallow-chain static deck (`chain_catenary_shallow_30m.dat`) converges |
| Memory growth over a 10x longer run | 5.0 -> 5.0 MiB (`dynamic_chain_current.dat`), 21.2 -> 21.3 MiB (`lozon_gomex80_power_cable.dat`); limit +16 MiB |
| Exit contract | a run states the exit contract after the banner; a refused input ends stderr with the closing line |
| `CompMooring = 5` smoke | CableDyn banner, `dtM` 0.025 s (one glue step), equilibrium fairlead tensions 2.437 MN, normal termination |

## Clean-machine test

A self-contained check ran the release assets from a folder whose path holds spaces, an accented
letter and Hangul, with a system-only `PATH`. It checks the checksums of the four files and the
manifest, the start of both executables, 13 standalone decks (the torsion example included),
three `CompMooring = 5` runs (a 70 s JONSWAP sea, a 400 s line failure, and a checkpoint at 30 s
with a restart whose last 10 s of output must be bit-identical), and the Python wheel in a new
virtual environment, where it imports as 0.3.0 and runs the release driver. All 26 checks
passed. Every shipped example deck (51) also runs to completion with the release
`CableDyn_driver.exe`.

## Python distribution

The PyPI distribution is built by `.github/workflows/wheels.yml`; each wheel is installed into a
clean environment and smoke-tested on its own platform (the library and the driver it carries
load and run a deck, and the driver reports the expected build). The preflight run (39898806566)
built the files below; the release run rebuilds them from the tag before the upload. The 0.2.0
dry run through TestPyPI installed the Windows wheel into a new environment and passed the same
smoke test.

| File | SHA-256 (preflight) |
| --- | --- |
| `cabledyn-0.3.0.tar.gz` | `2978cd01f1f981ff4ddf133f3e8aa742002bcae74f85e4645d1b081eed6ff510` |
| `cabledyn-0.3.0-py3-none-win_amd64.whl` | `9aaee5e0e07fd2f2d6e462dea61c88d13bf7a1e8f7c2a1b2cc66041cb0800c04` |
| `cabledyn-0.3.0-py3-none-macosx_14_0_arm64.whl` | `ceb4acedae58df952b7fffa4aafe03f7cdfbcfc95253dcaa57fb398add920c0e` |
| `cabledyn-0.3.0-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl` | `5cc58414a685cbfc7b19d25a422e61a671053dfcaf8a559e3e24e15a1be46cc6` |

## Assets

| File | SHA-256 |
| --- | --- |
| `CableDyn_driver.exe` | `f3878776d862a758a5a6bcb7d18f5c01ae394e480951d45c61b6719e9a6484ff` |
| `openfast.exe` | `16cd67bf349aec4a6170edf881f234aa2749b1bb7efee85bd5c9d4f3a76e1643` |
| `cabledyn-0.3.0-py3-none-any.whl` | `867a8d4b2a99ca9bcd8cc5cc64f0c46b626f74710cb9155e3b51abd86462fe16` |
| `cabledyn-0.3.0.tar.gz` | `106245fe7b6aa1a0205295cdc9c04c5ea874369bac73546e5a0d80c09de30160` |
