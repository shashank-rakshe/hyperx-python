<!-- SPDX-License-Identifier: Apache-2.0 -->

# Developing CableDyn

This guide is for developers who build and test CableDyn from source. It lists the
commands for the environment, build, tests, Python package, documentation, and
integration with OpenFAST, maintained by NLR (National Laboratory of the Rockies,
formerly NREL). Contribution rules are in
[CONTRIBUTING.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/CONTRIBUTING.md);
the release procedure is in
[RELEASE.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/RELEASE.md).

## Environment

Requirements: conda (Miniconda, Miniforge, or Anaconda) on Linux, macOS, or
Windows, and git. `environment.yml` provides conda-forge gfortran, a C compiler,
CMake, Ninja, Make, OpenBLAS/LAPACK, Python, and the developer tools
(`pre-commit`, `fprettify`). Do not mix the conda gfortran with a system gfortran
or Intel IFX.

```powershell
conda env create -f environment.yml
conda activate cabledyn
pre-commit install
```

## Build and test

```powershell
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build -L fortran -LE slow --output-on-failure   # fast tier
ctest --test-dir build --output-on-failure                       # full suite
```

The standalone driver is `build/cabledyn` (`build\bin\cabledyn.exe` with the conda
toolchain on Windows, where CMake stages the runtime DLLs and every executable in
`build\bin`); a build with an MSVC-style linker (Intel IFX) and the static release
build name the same program `CableDyn_driver.exe`. On Windows, add
`-DCMAKE_C_COMPILER=gcc` if CMake would otherwise pick a Visual Studio C compiler, so the
C sources build with the conda MinGW `gcc` that matches `gfortran` (as CI does).
The Debug configuration (`-DCMAKE_BUILD_TYPE=Debug`) adds `-fcheck=all
-fbacktrace`. CMake finds LAPACK with `find_package(LAPACK)` and falls back to the
conda OpenBLAS through `CONDA_PREFIX`. `cmake --install build --prefix stage`
installs the driver, the shared library, and `CableDyn_CAPI.h`.

`-DCABLEDYN_TARGET_AVX2=ON` compiles the Fortran core for x86-64-v3 (AVX2, FMA,
BMI1/2: Intel Haswell and AMD Excavator or newer) with IFX (`/arch:CORE-AVX2`) or
gfortran 11+ (`-march=x86-64-v3`), with contraction into fused multiply-adds off
(`/Qfma-`, `-ffp-contract=off`) so a restored state still continues a run bit for
bit. The static Windows release always sets it: its IFX driver runs the benchmark
decks 13-33% faster, and the results change at round-off. Such a build checks the
processor when it starts
(`src/cabledyn_cpu_guard.c`, compiled for baseline x86-64) and stops with a
message naming the missing instructions instead of crashing on the first one;
the driver's `--version` output and the OpenFAST module's start-up lines report the
x86-64-v3 build. The default (`OFF`) runs on any x86-64 processor.

A Windows build with gfortran links every executable with a 64 MiB stack reserve
(the MinGW default is 2 MiB). With OpenMP enabled, gfortran keeps fixed-size local
arrays on the stack, and the stack depth of the OpenBLAS kernels differs between
CPUs, so a small reserve can pass on one machine and overflow on another. The
shared library cannot rely on this reserve: the host program (for example
`python.exe`, which reserves about 2 MB) sets the stack of the threads that call
it. The `-L stack` tests check the library on a thread with a 1 MiB stack and, in
a Windows gfortran build, the driver and the modal test relinked with a 1 MiB
reserve and the reserve written into each executable.

| Selection | Tests |
|---|---|
| `-L fortran` | All Fortran tests |
| `-L fortran -LE slow` | Fast tier |
| `-L slow` | Long validation cases |
| `-L l1` | The 10 analytical cases |
| `-L static`, `-L dynamic` | Static and dynamic solver tests |
| `-L integration` | End-to-end driver and aggregate tests |
| `-L openfast` | OpenFAST shell and aggregate tests |
| `-L external_ref` | IEA-15MW VolturnUS-S mooring comparisons |
| `-L cosserat` | Secondary Cosserat path |
| `-L python` | Python package, deck-style, and documentation checks |
| `-L stack` | Library, driver, and modal test on a 1 MiB stack |

A test program can also be run directly from the build tree (`build/`, or
`build\bin\` with the conda toolchain on Windows); it prints `PASS:` or
stops at the first mismatch. The Fortran CI workflow builds Release and Debug on
Ubuntu and Windows and runs the full suite on every pull request and push to
`main`.

The `roundoff` job of the same workflow repeats the Linux Release build and the full
CTest on the SSE3 OpenBLAS kernel (`OPENBLAS_CORETYPE=Prescott`), then runs every shipped
example deck through `tests/check_example_fallbacks.py`, which fails on a non-zero exit and on a
fallback note where a deck should converge cleanly, and lists the offending decks. The job stops
first if OpenBLAS does not report that kernel. It is advisory, not a required check. To repeat it
locally, on Linux or Windows:

```bash
OPENBLAS_CORETYPE=Prescott ctest --test-dir build --output-on-failure
python tests/check_example_fallbacks.py --driver build/cabledyn --examples examples \
    --out build/example_scan --coretype Prescott
```

## Python package

The `cabledyn` package (`python/`) loads the C-ABI shared library built by
`cmake --build build --target cabledyn_shared`. The `python_package` CTest runs its
tests when the configured Python has `numpy` and `pytest`. To work on the package
directly:

```powershell
python -m pip install -e ".\python[dev]"
$env:CABLEDYN_LIBRARY = "<path to the built libcabledyn shared library>"
python -m pytest python/tests -q
cd python; python -m ruff check cabledyn tests; python -m ruff format --check cabledyn tests; python -m mypy; cd ..
```

The fatigue (`test_fatigue.py`) and spectral (`test_spectra.py`) tests do not load
the shared library. They compare against independent references (the ASTM E1049
cycle table and analytical sinusoids); do not replace these with snapshots of
CableDyn output.

### Distribution: sdist and platform wheels

The root `pyproject.toml` builds the published distribution with scikit-build-core: an
sdist of the sources and a platform wheel that carries the compiled library beside the
package modules and the standalone driver in `cabledyn/bin`. Only the `cabledyn_shared`
and `cabledyn` targets are built and installed (CMake install component `python`, active
under scikit-build only), serially (`CABLEDYN_ENABLE_OPENMP` off). The wheel is tagged
`py3-none-<platform>`: the package reaches the library through `ctypes`, so one wheel
serves every supported Python version. `python/pyproject.toml` stays the pure package for
development against a build tree; `tests/test_packaging_metadata.py` keeps the two
`[project]` tables identical except for the readme, licence files and platform
classifiers.

To build both locally from the activated `cabledyn` environment (Ninja, the conda GNU
toolchain, and forward slashes in the archiver paths):

```powershell
python -m pip install "scikit-build-core>=0.10" build
python -m build --sdist --no-isolation --outdir dist .
$ar = "$env:CONDA_PREFIX/Library/bin/x86_64-w64-mingw32-ar.exe" -replace '\\','/'
$rl = "$env:CONDA_PREFIX/Library/bin/x86_64-w64-mingw32-ranlib.exe" -replace '\\','/'
python -m pip wheel . --no-deps --no-build-isolation -w dist `
  "--config-settings=cmake.args=-GNinja" `
  --config-settings=cmake.define.CMAKE_C_COMPILER=gcc `
  --config-settings=cmake.define.CMAKE_Fortran_COMPILER=gfortran `
  --config-settings=cmake.define.CMAKE_AR=$ar --config-settings=cmake.define.CMAKE_RANLIB=$rl
```

A wheel built this way still needs the toolchain's runtime and LAPACK libraries on the
search path; the release wheels bundle them (or link them statically on Windows).

The release wheels come from `.github/workflows/wheels.yml` (manual runs, published
releases, and pull requests that touch the packaging), as workflow artifacts, which only
its publish jobs upload (TestPyPI from a manual run with **upload = testpypi**, PyPI from a
published release; see
[RELEASE.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/RELEASE.md)). It builds
the sdist (checked with `twine`) and three wheels:

| Wheel | Toolchain | Runtime and LAPACK | Build |
|---|---|---|---|
| Linux x86-64 (`manylinux_2_28`) | cibuildwheel, image GCC toolset | OpenBLAS and the Fortran runtime bundled by auditwheel | x86-64-v3 |
| macOS arm64 (14.0+) | cibuildwheel, Homebrew gfortran | OpenBLAS and the Fortran runtime bundled by delocate | baseline |
| Windows x86-64 | `release/build_windows_wheel.ps1`: IFX and MSVC, static runtime | the release's reference LAPACK, linked statically | x86-64-v3 |

The Windows wheel uses the static release configuration and the same pinned reference
LAPACK as `release/build_static_windows.ps1` (`tests/test_packaging_metadata.py` keeps
the version, checksum and flags equal), and the script checks with `dumpbin` that the
library and the driver import only Windows system DLLs. Each wheel is installed into a
clean environment and checked by `release/smoke_test_wheel.py`: the package loads the
library it carries, selects the driver it carries, the driver reports the expected build
(`--expect-build`), and a standalone deck runs. On a processor without AVX2 the x86-64
wheels' driver stops with the start-up message, and so does a Python process when it
loads the library.

On Windows, run Python from the activated `cabledyn` environment and point
`CABLEDYN_LIBRARY` at the DLL. Do not prepend compiler or OpenBLAS runtime
directories to `PATH` before importing NumPy: mixed runtime DLLs can terminate
Python during NumPy initialisation.

## Documentation

```powershell
python -m pip install -r doc/requirements.txt
python -m sphinx -W --keep-going -n -b html doc doc/_build/html
python tests/test_documentation.py
```

Markdown files outside `doc/` that the manual includes (`CHANGELOG.md`,
`CONTRIBUTING.md`, `DEVELOPMENT.md`, `VALIDATION.md`) must link to repository
files with absolute `https://github.com/SMI-Lab-Inha/CableDyn/blob/main/...`
URLs.

## Formatting and checks

```powershell
pre-commit run --all-files
fprettify --indent 2 --line-length 120 src/<file>.f90
```

The hooks check whitespace, end-of-file, merge markers, YAML, large files, Fortran
formatting (`fprettify`; `src/openfast/` is excluded), Python lint and formatting (`ruff`),
and release metadata.
Fortran lines longer than 120 columns must be split with `&` before formatting.

## Coding standards

### Fortran

- Fortran 2018, free form, `IMPLICIT NONE` in every program unit.
- Real kind `wp` from `CableDyn_Precision`; never `REAL*8` or `DOUBLE PRECISION`.
- Modules are named `CableDyn_<Function>`; subroutines `CD_<Action>_<Object>`
  (for example `CD_Assemble_Cable_Mass`).
- Public subroutines take `ErrStat (INTEGER, INTENT(OUT))` and
  `ErrMsg (CHARACTER(*), INTENT(OUT))`.
- LAPACK: banded solvers (`DGBSV`, and `DPBTRF`/`DPBTRS` for symmetric positive
  definite bands); a dense assembly is packed into band storage before the solve.
- Warning-clean under `-std=f2018 -Wall -Wextra -fimplicit-none` with gfortran 15
  and 16. gfortran 16 can report `-Wuninitialized` for a default-initialised local
  derived-type variable with allocatable components: the optimiser copies the
  unset bounds of its unallocated arrays, which the program never reads. Such a
  local is `ALLOCATABLE` where this occurs.
- Keep large data off the stack: a local array or derived-type variable that can
  exceed about 64 KB is `ALLOCATABLE`, except on the per-step path, which uses the
  preallocated workspaces and does not allocate.

### SPDX headers

Every source file starts with:

```text
! File: <path>
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
```

Use the comment syntax of the language (`#` for Python, PowerShell, and YAML).

## OpenFAST integration

The OpenFAST host module in `src/openfast/` compiles only inside an OpenFAST
source tree. To build and check it locally:

```powershell
git clone https://github.com/OpenFAST/openfast.git <openfast>
git -C <openfast> checkout 2895884d2be01862173c88d70f86b358d2f1a50a
./integration/openfast/prepare_openfast_source.ps1 -OpenFASTRoot <openfast>
cmake -S <openfast> -B <openfast-build-dir> -DCABLEDYN_ROOT=<CableDyn checkout>
powershell -File integration/openfast/openfast_build_gate.ps1 -BuildDir <openfast-build-dir> -CaseFst <case.fst>
```

With the MinGW gfortran of the conda environment, add
`-DCMAKE_EXE_LINKER_FLAGS="-Wl,--stack,16777216"` to the configure line. OpenFAST's
CMake raises the 2 MB default stack to 16 MB only for Cygwin and Visual Studio builds,
and a MinGW `FAST.Farm.exe` (`-DBUILD_FASTFARM=ON`) with the default stack stops with a
stack overflow while ElastoDyn initialises.

`openfast_build_gate.ps1` builds `openfast.exe`, runs a `CompMooring = 5` case,
checks that the CableDyn banner appears in the log, that the executable names itself
`OpenFAST-<OpenFAST base>-CableDyn-<CableDyn version>`, and that the output is finite.

An `openfast.exe` built this way through CMake does not embed the UTF-8
active-code-page manifest (`app/utf8_code_page.manifest`), so on Windows it may not
open input files in folders whose names the system code page cannot spell. The
static release build (`release/build_static_windows.ps1`, which uses the OpenFAST
Visual Studio solution) embeds the manifest. See
[integration/openfast/README.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/integration/openfast/README.md)
for details.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `gfortran` not found | environment not activated | `conda activate cabledyn` |
| `find_package(LAPACK)` fails | no system LAPACK | install `liblapack-dev`, or build inside the conda environment |
| Python exits while importing NumPy on Windows | runtime DLL directories on `PATH` | remove them from `PATH`; set `CABLEDYN_LIBRARY` instead |
| Windows checkout differs from CI | CRLF line endings | `.gitattributes` enforces LF; run `git add --renormalize .` |
| `modal` test stops with an access violation in `openblas.dll` (AMD Zen 4/5) | OpenBLAS 0.3.34 DGEMM stack overrun (OpenMathLib/OpenBLAS#6013) | `conda env update -f environment.yml`, which excludes 0.3.34, then configure a fresh build directory: the build keeps a staged `openblas.dll` that is newer than the package's |
