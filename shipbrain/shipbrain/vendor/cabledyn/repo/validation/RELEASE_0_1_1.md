<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn v0.1.1 release record

This record lists what was built and tested for the v0.1.1 release: the source commit,
toolchains, dependency pins, test results and asset hashes. Case definitions and pass criteria
are in [`VALIDATION.md`](../VALIDATION.md). The toolchains and pins are those of
[v0.1.0](RELEASE_0_1_0.md).

## Source and pins

| Item | Value |
| --- | --- |
| CableDyn | `0.1.1` (2026-10-09), C ABI 1, minor extension 1 |
| Source | The `v0.1.1` tag. The assets and the gates below were produced from this tree before this record was completed; every other file is identical |
| OpenFAST base | `2895884d2be01862173c88d70f86b358d2f1a50a`; the 20 patches of [`integration/openfast/patches`](../integration/openfast/patches) applied to a clean checkout by `prepare_openfast_source.ps1` |
| OpenFAST r-test | `dd5feaaaa500ba7283140107806300d551cff0a7` |
| Reference LAPACK/BLAS | 3.12.1, release-tag archive with SHA-256 `2ca6407a001a474d4d4d35f3a61550156050c48016d949f0da0529c0aa052422` |

## Toolchains

| Item | Version |
| --- | --- |
| GNU Fortran (test builds) | conda-forge GCC 15.2.0, with OpenBLAS and LAPACK from the conda environment |
| Intel Fortran (Windows release) | IFX 2025.3.2 |
| Microsoft C/C++ | MSVC 14.44.35207 (`cl` 19.44.35215), Visual Studio 2022, Windows SDK 10.0.22621.0 |
| CMake and Ninja | 3.29.2 and 1.12.0 |
| Python and packaging | Python 3.11.15, build 1.5.0, setuptools 82.0.1, Twine 6.2.0 |

## Test results

| Gate | Result |
| --- | --- |
| GNU Release build | 0 compiler warnings |
| GNU Release CTest, including the slow tier | 243 of 243 passed |
| GNU Debug build (`-fcheck=all`) | 0 compiler warnings |
| GNU Debug CTest | 243 of 243 passed |
| GNU Debug CTest with `-finit-real=snan -finit-integer=-2147483647 -fcheck=all` | 243 of 243 passed, 0 compiler warnings |
| Python package tests, native library and driver included | 1993 passed; 99.44% branch coverage (minimum 95%) |
| Ruff, Ruff format and mypy (strict) | passed |
| Sphinx documentation, HTML and EPUB (`-W -n`) | built with no warnings |
| pre-commit, all files | passed |
| Release metadata and release-tree audits | `check_release_metadata.py` passed, with no other CableDyn version outside the records of past releases; `audit_release_tree.py` passed on the working tree and on `--archive-ref HEAD` |
| OpenFAST-tree build gate (`integration/openfast/openfast_build_gate.ps1 -Clean`, GNU CMake build of the patched OpenFAST base) | the CableDyn module compiled from a clean tree, identified itself and ran a 30 s `CompMooring = 5` smoke with finite output |
| Experimental comparisons ([`experiments`](experiments/README.md)) | Holcombe (12 cases) and Bergdahl (30 primary and 8 refinement cases) re-run with a GNU Release build of 0.1.1; every committed result file is reproduced byte for byte |

## Windows executable gates

Every gate of `build_static_windows.ps1` passed. The smoke runs used a system-only `PATH`.

| Gate | Result |
| --- | --- |
| Compiler | IFX 2025.3.2 (minimum 2025.3) |
| OpenFAST solution build | 0 errors in all 34 projects |
| `CableDyn_driver.exe` imports | `KERNEL32.dll`, `SHELL32.dll` and `imagehlp.dll` only; stack reserve 268,435,456 bytes |
| `openfast.exe` imports | `KERNEL32.dll` and `imagehlp.dll` only; stack reserve 9,999,999 bytes |
| Standalone smoke | `--version`, the shallow-chain static deck from a mixed-script folder, and one dynamic step of the 952-element Gulf of Maine cable |
| Memory growth over a 10× longer run | 4.7 → 4.7 MiB (`dynamic_chain_current.dat`), 31.0 → 20.5 MiB (`lozon_gomex80_power_cable.dat`; the 100 ms sampling caught a larger transient in the short run); limit +16 MiB |
| Exit contract | a run states the exit contract after the banner; a refused input exits with 1 and ends stderr with `CableDyn_driver: ended with exit code 1` |
| `CompMooring = 5` smoke | CableDyn banner, 41 committed rows at `dtM` 0.025 s, t = 0 fairlead tensions inside the 2.28–2.52 MN band, printed equilibrium tensions equal to the static profile |
| `CompMooring = 3` smoke | stock MoorDyn initialises and the run ends normally |

## Clean-machine test

A self-contained kit ran the release assets from a folder whose path holds spaces, an accented
letter and Hangul, with a system-only `PATH`. It checks the checksums, the start of both
executables, 13 standalone decks (the torsion example included), three `CompMooring = 5` runs (a
70 s JONSWAP sea, a 400 s line failure, and a checkpoint at 30 s with a restart that must be
bit-identical), and the Python wheel in a new virtual environment. All 20 checks passed. Every
key result of the decks that also ran for v0.1.0 agrees with the v0.1.0 executables within the
kit tolerance (relative 1e-4; most are identical).

The end-of-run reports of the release `CableDyn_driver.exe` were checked separately: a
completed run exits with 0 and states the exit contract; a refused input exits with 1 and
ends stderr with the closing line; a run ended from outside by its process id leaves no
closing line; and Ctrl+Break gives `CableDyn_driver: stopped by Ctrl+Break after the step at
simulated time t = ... s`, followed by the Intel Fortran runtime's `forrtl: error (200)` and
traceback (exit code 152 in these runs, after `forrtl: severe (152)`).

## Assets

| File | SHA-256 |
| --- | --- |
| `CableDyn_driver.exe` | `f9102899dc2742ee699a4f30d9863ccd064437a1c22de994e3c3bc518131d0e4` |
| `openfast.exe` | `e969a70b50f90bd422d85b1ad37ebef7085eebde1cbb61255099fc9c43819e13` |
| `cabledyn-0.1.1-py3-none-any.whl` | `05c0ad8c283af82ecf237493df4229fcd5db93cbdf75e67f9e2f7422b0455c4f` |
| `cabledyn-0.1.1.tar.gz` | `264c892d5b618588f1d81b712dbacc7f7401ed021c07a9a4a39a5aaf059e0f6b` |
