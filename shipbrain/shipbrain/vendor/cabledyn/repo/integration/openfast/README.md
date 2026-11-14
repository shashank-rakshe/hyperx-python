<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn integration for OpenFAST v5

This directory is for developers who build OpenFAST, maintained by NLR (National Laboratory of
the Rockies, formerly NREL), with CableDyn as `CompMooring = 5`. Users
who only run coupled cases should use the released `openfast.exe` and the
[OpenFAST guide](../../doc/openfast.rst).

The patches in [`patches/`](patches/) apply to the public OpenFAST upstream commit
`2895884d2be01862173c88d70f86b358d2f1a50a` (the OpenFAST v5.0.0 release, used by
CableDyn v0.4.2). They add only the OpenFAST host integration; the CableDyn sources come from
this repository.

| File | Purpose |
| --- | --- |
| `patches/*.patch` | Patch series, one file per patch; `0006` and `0016`–`0020` add new CableDyn-owned files, the others modify upstream files |
| `prepare_openfast_source.ps1` | Checks the upstream revision and a clean worktree, then applies the series |
| `integrate_openfast_vs_solution.ps1` | Adds CableDyn to the Intel Fortran Visual Studio solution of the Windows release and sets its version string |
| `vs-build/CableDyn.vfproj.in` | Visual Studio project template used by that script |
| `openfast_build_gate.ps1` | Builds a configured OpenFAST tree and runs a coupled `CompMooring = 5` smoke case |

## Prepare a source tree

```powershell
git clone https://github.com/OpenFAST/openfast.git openfast-cabledyn
git -C openfast-cabledyn checkout 2895884d2be01862173c88d70f86b358d2f1a50a
./integration/openfast/prepare_openfast_source.ps1 -OpenFASTRoot ./openfast-cabledyn
```

The script stops if the revision differs, the worktree carries other changes, or a patch does
not apply. On a checkout where the whole series is already applied it reports that and changes
nothing, so it can be rerun. Configure the patched tree with CMake and pass `-DCABLEDYN_ROOT=<CableDyn
checkout>` (optionally `-DCABLEDYN_BUILD_DIR=<CableDyn build>` to link a prebuilt core). Then
check the build:

```powershell
./integration/openfast/openfast_build_gate.ps1 -BuildDir <openfast-build> -CaseFst <case.fst>
```

The script fails unless `openfast.exe` builds, the smoke case initialises the CableDyn module, and
the output is finite to the last row. Configure with `-DBUILD_FASTFARM=ON` to build `FAST.Farm`
as well (target `FAST.Farm`); the release does not ship it, so FAST.Farm users take this route.
On Windows with the GNU compilers, patch `0022` links `openfast.exe` and `FAST.Farm.exe` with a
256 MiB stack reserve (`-Wl,--stack,268435456`, as the CableDyn driver): with the MinGW default
of 2 MiB, `FAST.Farm.exe` stops with `0xC00000FD` (stack overflow) while it initialises the
turbines of a farm, before any output. The reserve is address space, not committed memory; the
Visual Studio projects of the release set their own. An `openfast.exe` built through CMake does not embed the
UTF-8 active-code-page manifest, so on Windows it may not open input files in folders whose names
the system code page cannot spell; the static release build embeds it.

For the static Windows release, pass a clean, unpatched checkout to
`release/build_static_windows.ps1`; it applies the series itself (see
[Installation](../../doc/installation.rst)). Its Visual Studio project compiles the CableDyn
adapter with `/heap-arrays:1024`, as the static CMake build compiles the CableDyn core, so arrays
whose size is known only at run time are placed on the heap rather than on the `openfast.exe` stack.
Every configuration also makes local variables automatic (`/Qauto`, as the CMake build of the
core does with every compiler): without OpenMP, ifx keeps fixed-size local arrays and `CHARACTER`
locals in static storage, which every thread shares, and the turbines of a FAST.Farm run, like
separate C API handles, may step on several threads at once. Every configuration, and the
adapter target of the CMake route, compiles with the value-safe floating-point model
(`/fp:precise`, `-fp-model precise` off Windows), as every Intel build of the core does: the
ifx default, `/fp:fast`, may reassociate sums and flush subnormals to zero.

## Version string

OpenFAST names its version with `git describe --dirty`, which would read `v5.0.0-dirty` on
the patched tree. A CableDyn-enabled executable names itself
`OpenFAST-<OpenFAST base>-CableDyn-<CableDyn version>` instead, here
`OpenFAST-v5.0.0-CableDyn-0.4.2` (printed by `openfast.exe -v` and at the start of every run).
The OpenFAST part is `git describe --tags --abbrev=8` of the checked-out commit, the
unpatched base; the CableDyn part is the project version in the CableDyn `CMakeLists.txt`.
Patch `0021` sets it in the CMake build, and `integrate_openfast_vs_solution.ps1` in the
Visual Studio solution, whose `vs-build/CreateGitVersion.bat` it replaces. Both stop unless
the base is described by a release tag (`vX.Y.Z` or `vX.Y.Z-N-g<hash>`), so the checkout
needs its tags: a `git clone` has them, a single-commit shallow fetch does not.

## License of modified files

The patches modify OpenFAST source files licensed under the Apache License, Version 2.0. The
changed files are modified files in the sense of Section 4(b) of that license: upstream copyright
and license notices are retained, and the changed files and the nature of the changes are
identified here and in the top-level [`NOTICE`](../../NOTICE).
