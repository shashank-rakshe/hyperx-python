<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn v0.1.0 release record

This record is for users and reviewers who need to know exactly what was built and tested
for the v0.1.0 release. It lists the source commit, toolchains, dependency pins, test results
and asset hashes. Case definitions and pass criteria are in
[`VALIDATION.md`](../VALIDATION.md); the wall-time comparison with MoorDyn is in
[`PERFORMANCE_0_1_0.md`](PERFORMANCE_0_1_0.md). OpenFAST is developed by NLR (National Laboratory
of the Rockies, formerly NREL) and MoorDyn by Hall et al.; the coupled build and the
comparisons build directly on their open-source work.

## Source and pins

| Item | Value |
| --- | --- |
| CableDyn | `0.1.0` (2026-10-01), C ABI 1 |
| Source | The `v0.1.0` tag. The assets, the source-tree gates and the coupled end-to-end checks below were produced from this tree before this record was completed; every other file is identical |
| OpenFAST base | `2895884d2be01862173c88d70f86b358d2f1a50a`; the 20 patches of [`integration/openfast/patches`](../integration/openfast/patches) applied to a clean worktree by `prepare_openfast_source.ps1` |
| OpenFAST r-test | `dd5feaaaa500ba7283140107806300d551cff0a7` |
| Reference LAPACK/BLAS | 3.12.1, release-tag archive with SHA-256 `2ca6407a001a474d4d4d35f3a61550156050c48016d949f0da0529c0aa052422` |
| MoorDyn in `openfast.exe` | MoorDyn-F v2.3.8, as in the OpenFAST base |

## Toolchains

| Item | Version |
| --- | --- |
| GNU Fortran (test builds) | conda-forge GCC 15.2.0, with OpenBLAS and LAPACK from the conda environment |
| Intel Fortran (Windows release) | IFX 2025.3.2 (build 20260112) |
| Microsoft C/C++ | MSVC 14.44.35207 (`cl` 19.44.35215), Visual Studio 2022 17.14.13, Windows SDK 10.0.22621.0 |
| CMake and Ninja | 3.29.2 and 1.12.0 |
| Python and packaging | Python 3.11.15, build 1.5.0, setuptools 82.0.1, Twine 6.2.0 |

The Windows executables were built with
[`release/build_static_windows.ps1`](../release/build_static_windows.ps1): IFX with
interprocedural optimisation (`/Qipo /O2`), the static Microsoft runtime, and the reference
LAPACK/BLAS compiled by the same IFX with `/fp:precise`. `openfast.exe` is the `Release|x64`
target of the OpenFAST Visual Studio solution with CableDyn added; the reference libraries are
linked ahead of the solution's MKL, which supplies only the single-precision routines. The
release workflow installs Intel Fortran Essentials 2025.3.1, not the 2025.3.2 used for the
recorded assets, so the executables it publishes are not expected to be bit-identical to the
files listed under [Assets](#assets).

## Test results

| Gate | Result |
| --- | --- |
| GNU Release build | 0 compiler warnings |
| GNU Release CTest, including the slow tier (`-j 8`) | 221 of 221 passed |
| GNU Debug build | 0 compiler warnings |
| GNU Debug CTest (`-j 8`) | 221 of 221 passed |
| Python package tests | 1877 passed; 99.44% branch coverage (minimum 95%) |
| Ruff, Ruff format and mypy (strict) | passed |
| Sphinx documentation (`-W -n`) | built with no warnings |
| Example decks (`examples/*.dat`, GNU Release driver) | 51 of 51 exit with code 0 |
| pre-commit, all files | passed |
| Release metadata and release-tree audits | `check_release_metadata.py` passed; `audit_release_tree.py` passed on the working tree and on `--archive-ref HEAD` |
| Static-solution campaign, 2078 decks | 1872 pass; 206 stop with the intended named error (95 geometries with no admissible equilibrium, 111 tensile-audit rejections); 0 fail, 0 silently wrong, 0 timeouts |
| Rigid bodies, rods and shared anchors ([`bodies`](bodies/README.md)) | 102 of 102 gates passed |
| Dynamic cable cases | 76 of 76 passed |
| Input fuzzing | campaign A 4000 of 4000, B 2500 of 2500, C 4000 of 4000 |

The static, bodies, dynamic-cable and fuzz campaigns ran on GNU Release builds of earlier release
candidates and were not repeated on the release tree. Every
static and fuzz case had the same outcome on each candidate it ran on. The bodies suite has 102 gates, including the 14 OrcaFlex summary
gates of V-D1b.

## Windows executable gates

Every gate of `build_static_windows.ps1` passed. The smoke runs used a system-only `PATH`.

| Gate | Result |
| --- | --- |
| Compiler | IFX 2025.3.2 (minimum 2025.3) |
| OpenFAST patch series | 20 patches applied to a clean worktree |
| Reference LAPACK | archive SHA-256 verified; `liblapack.lib` and `libblas.lib` built with IFX |
| OpenFAST solution build | 0 errors in all 34 projects |
| `CableDyn_driver.exe` imports | `KERNEL32.dll`, `SHELL32.dll` and `imagehlp.dll` only; stack reserve 268,435,456 bytes |
| `openfast.exe` imports | `KERNEL32.dll` and `imagehlp.dll` only |
| Standalone smoke | `--version`, the shallow-chain static deck, and one dynamic step of the 952-element Gulf of Maine cable |
| Memory growth over a 10× longer run | 4.6 → 4.6 MiB (`dynamic_chain_current.dat`, 1000 s → 10000 s), 19.9 → 19.9 MiB (`lozon_gomex80_power_cable.dat`, 3 s → 30 s); limit +16 MiB ² |
| `CompMooring = 5` smoke | CableDyn banner; 41 committed rows at `dtM` 0.025 s; t = 0 fairlead tensions 2.436, 2.436 and 2.436 MN, inside the 2.28–2.52 MN band; each line's printed equilibrium tension equals its End A tension in `.CD.static.out` |
| `CompMooring = 3` smoke | stock MoorDyn initialises and the run ends normally |

² The gate samples the peak private memory every 100 ms. A 100 s chain run can end within one
sample, before its buffers are allocated, and then reads 2.2 MiB. The peak is about 4.7 MiB
at 1000, 3000 and 10000 s, so the footprint is a one-time allocation that does not grow with
the number of steps.

## Coupled end-to-end checks

These checks ran the release `openfast.exe` on the IEA-15MW VolturnUS-S model: r-test
`MD_Shared` turbine 1 with the pose reset of
[`examples/openfast/README.md`](../examples/openfast/README.md), a JONSWAP sea with Hs 6 m and
Tp 12 s, and no wind. The wall times are single runs on an otherwise idle Intel Core i9-13900K,
with the process on its performance cores.
Repeating each run reproduced its output rows exactly.

| Run | Result | Wall time |
| --- | --- | ---: |
| CableDyn (`CompMooring = 5`), 70 s | FairTen1 2.114–2.878 MN; PtfmSurge −1.80 to 3.60 m | 4.8 s |
| MoorDyn twin (`CompMooring = 3`), 70 s | FairTen1 2.115–2.881 MN; PtfmSurge −1.80 to 3.60 m; mean fairlead and anchor tensions within 0.01% of CableDyn's over 10–70 s | 142.9 s |
| Coupled platform rod (`CableDyn_UMaine_rod.dat`), 70 s | FairTen1 2.115–2.902 MN | 4.8 s |
| Line failure (`IEA-15-UMaine_CompMooring5_CableDyn_LineFailure.fst`), 400 s | line 1 detaches at t = 100.0 s; PtfmSurge reaches 146.8 m | 26.5 s |
| Checkpoint at 30 s, then `-restart` | all 1,600 rows after 30 s of `.out` and `.CD.out` identical to the uninterrupted run | 5.0 s, then 2.8 s |

The MoorDyn version of the platform-rod model (`MoorDyn_UMaine_rod.dat`) also runs to the end.
Its platform response differs from CableDyn's because the two codes orient a coupled rod
differently; [`OPENFAST_DLC_VERIFICATION.md`](OPENFAST_DLC_VERIFICATION.md) compares them.

## Physical validation

Both comparisons ran with a GNU Release build of `cabledyn.exe`, whose SHA-256 is recorded in
each `provenance.json`. Both builds are from earlier release candidates, and the comparisons were not repeated on the release tree.

The Holcombe static lazy-wave comparison completed all 12 mesh and end-condition cases without
a nonlinear miss. The profile root-mean-square errors were 39.4 mm for free end rotation and
69.4 mm for the ideal vertical clamp. The marker peak-curvature errors were 0.34% and 5.54%,
respectively. Refining from 212 to 771 elements changed a reported marker position by at most
0.007 mm for free rotation and 0.12 mm for the ideal clamp.

The Bergdahl dynamic-chain comparison completed all 30 experimental conditions and all 8
refinement runs without a nonlinear miss, at a 0.3125 ms step that resolves the segment axial
modes the snap loads excite. Across the 30 upper-end force maxima, CableDyn gave an RMSE of
1.58 N, a MAPE of 3.11%, a Pearson correlation of 0.993 and a Lin concordance correlation of
0.989. The maximum primary spatial and temporal refinement differences were 0.49% and 0.28%.
The two waveform comparisons gave RMSEs of 5.95% and 2.54% of the measured force range, against
the measured phase averages of the article supplement.

The CSV and JSON results, their SHA-256 digests, source-data licences and reproduction
commands are in [`experiments`](experiments/README.md).

## Assets

| File | Size, bytes | SHA-256 |
| --- | ---: | --- |
| `CableDyn_driver.exe` | 7,744,000 | `dbd28ea10eed8d1d9fee20d35b276eb5f2a76ebdf18c42e2b4c254d19b655997` |
| `openfast.exe` | 40,523,776 | `83394752c79e0143b0a30de1f1266076185ae9ad64cfbf17b73d54eca402178c` |
| `cabledyn-0.1.0-py3-none-any.whl` | 255,133 | `88177438bccde2b13e43288cb53a3307c8d8d1c7aff570366584fdddaafb755d` |
| `cabledyn-0.1.0.tar.gz` | 377,640 | `6f234f2fbd338798d26c70eed1eb34a93b50c300325c1977a7b38c41729d1482` |

All four assets are built from a fresh clone of the release tree. `SHA256SUMS.txt` lists these four
files. The Python distributions were built with `SOURCE_DATE_EPOCH` set to a fixed time and
pass `twine check`. The wheel holds only the
`cabledyn` package and its metadata, and both distributions include the Apache-2.0 licence. A
rebuild reproduces the wheel byte for byte. The source distribution's contents are also
reproduced, but its generated metadata files carry build timestamps, so its hash differs
between builds. The release workflow rebuilds every asset from the tag and publishes its own
`SHA256SUMS.txt`. The hashes above identify the locally built files.
