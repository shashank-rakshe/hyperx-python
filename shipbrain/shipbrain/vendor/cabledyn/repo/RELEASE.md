<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn release procedure

This procedure is for maintainers. It turns one reviewed commit into the native and
Python assets of a CableDyn release. Run it from a clean checkout of the release
commit. Tags have the form `vMAJOR.MINOR.PATCH`; CableDyn follows semantic
versioning and stays below `1.0.0` while its interfaces may change. Build and test
details are in [DEVELOPMENT.md](DEVELOPMENT.md).

Work for the next release collects on `dev`. To release, merge `dev` into `main` and run
this procedure on the resulting `main` commit.

## 1. Set and check the release metadata

Update the version and date in `CHANGELOG.md`, `CMakeLists.txt`, the Fortran banner
and OpenFAST module, the Python package, the C header, and `CITATION.cff`. Move
every release note from `[Unreleased]` to the new dated heading. Then run:

```powershell
python release/check_release_metadata.py
python release/audit_release_tree.py --tree .
pre-commit run --all-files
git diff --check
```

The audit rejects local-only directories, generated products, credentials, and
machine-specific paths in the tracked files. After creating the release commit,
audit the Git archive as well:

```powershell
python release/audit_release_tree.py --archive-ref HEAD
```

## 2. Test the source tree

Use fresh Release and Debug build directories:

```powershell
cmake -S . -B build-release -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-release --parallel
ctest --test-dir build-release --output-on-failure

cmake -S . -B build-debug -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build-debug --parallel
ctest --test-dir build-debug --output-on-failure
```

Both runs must pass every test, including the `slow` tier, with no compiler
warnings. Then check the install layout and the Python distributions:

```powershell
cmake --install build-release --prefix stage
python -m pip install -e ".\python[dev]"
python -m pytest python/tests -q
python -m build python --outdir dist-python
python -m twine check dist-python\*
```

Both distributions must contain the Apache-2.0 licence; the wheel must contain
only the `cabledyn` package and its metadata.

## 3. Test the OpenFAST integration

1. **Build check**: prepare the pinned OpenFAST source and run
   `integration/openfast/openfast_build_gate.ps1` (commands in
   [DEVELOPMENT.md](DEVELOPMENT.md#openfast-integration)). It builds
   `openfast.exe` with CableDyn, checks that a coupled run prints the CableDyn
   banner, and checks that the output is finite.
2. **Linearisation check**: with the built executable and again with the release workflow's
   `openfast.exe` (single precision, the Visual Studio `Release` configuration), run
   `python validation/scripts/openfast_lin_ab.py --exe <openfast.exe> --case-dir <case-dir>`,
   where `<case-dir>` holds the `examples/openfast` IEA-15 UMaine twin decks and
   the r-test `MD_Shared` turbine-1 ElastoDyn, HydroDyn, SeaState and HydroData
   inputs (listed in the script docstring). The CableDyn mooring block must be
   symmetric to ≤ 1e-3 with negative restoring diagonals and bounded sway
   coupling. Its per-fairlead blocks and platform 6×6 stiffness must match stock
   MoorDyn's quasi-static reduction to 0.5%. The script writes the `.lin` files
   at full precision.
3. Confirm that [VALIDATION.md](VALIDATION.md) matches the results at the release
   commit.

## 4. Build the Windows executables

Prerequisites: Windows x64, Visual Studio 2022 with the x64 C++ tools and the
Windows SDK 10.0.22621.0, and Intel oneAPI IFX 2025.3 or newer with MKL. Start from
clean, unpatched checkouts of the OpenFAST and r-test revisions pinned in the
release workflow; `release/build_static_windows.ps1` applies the patch series
itself:

```powershell
./release/build_static_windows.ps1 -OpenFASTRoot <openfast> -RTestRoot <r-test> -OutputDir <dist>
```

The build uses Intel IFX with interprocedural optimisation (`/Qipo`), the static
MSVC runtime, and the netlib reference LAPACK/BLAS 3.12.1, which the script
compiles with the same IFX. The script downloads the LAPACK source
from its release tag and checks its SHA-256; for an offline build pass the archive
with `-ReferenceLapackArchive <lapack-3.12.1.tar.gz>`. In `openfast.exe` the
reference libraries are linked ahead of the MKL of the OpenFAST Visual Studio
solution, which still supplies the single-precision routines they do not build.

The build fails if either executable imports a non-system DLL or lacks the UTF-8
active-code-page manifest (`release/check_static_windows_binary.ps1`), or if the
standalone and `CompMooring = 5` smoke cases fail with a system-only `PATH` or from
a folder named in mixed scripts. It also fails unless `openfast.exe -v` names the
executable `OpenFAST-v5.0.0-CableDyn-0.4.2`: the OpenFAST base and the CableDyn version,
never a `-dirty` describe of the patched tree.

The release workflow (`.github/workflows/release-windows-static.yml`) produces
exactly these assets:

- `CableDyn_driver.exe`
- `openfast.exe`
- `cabledyn-MAJOR.MINOR.PATCH-py3-none-any.whl`
- `cabledyn-MAJOR.MINOR.PATCH.tar.gz`
- `SHA256SUMS.txt`

A local run of the script writes a `SHA256SUMS.txt` for the two executables only;
the published five-asset manifest is the one the workflow builds. Run the workflow
manually (`workflow_dispatch`) as a preflight. Download its
`CableDyn-release-assets` artifact, verify every checksum (on a second machine
where practical), and keep the workflow URL with the release record.

The PyPI distribution (the sdist and the Linux, macOS and Windows wheels that carry
the library and the driver) comes from `.github/workflows/wheels.yml`. As its
preflight, run that workflow manually with **upload = testpypi**: it builds and
smoke-tests the four distributions and uploads them to TestPyPI (a version already
there is skipped). Then, in a clean environment on each platform you can reach:

```powershell
python -m pip install --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple/ "cabledyn==MAJOR.MINOR.PATCH"
python release/smoke_test_wheel.py examples/dynamic_chain_current.dat --expect-build x86-64-v3
```

(`--expect-build baseline` on macOS arm64.)

## 5. Tag and publish

Tag only the commit that passed every check:

```powershell
$ReleaseVersion = "MAJOR.MINOR.PATCH"
git tag -s "v$ReleaseVersion" -m "CableDyn v$ReleaseVersion"
git push origin "v$ReleaseVersion"
```

If no signing key is available, use an annotated tag and state this in the release
notes. Create a draft GitHub release from the tag, attach the five assets, and
compare their checksums with the preflight artifact. Publish after checking the
notes, licence, citation, documentation links, and executables on the draft page.

Publishing triggers a fresh build from the tag. If the release already has the five
preflight assets, the workflow verifies their inventory and SHA-256 manifest
without replacing them; if it has no assets, the workflow uploads the new build. A
partial release or invalid manifest fails without replacing any file. If assets do
not match, withdraw the release and investigate; never replace a file without a
documented correction.

Publishing also starts `.github/workflows/wheels.yml`, which rebuilds and smoke-tests
the PyPI distributions from the tag, checks that every file carries the tag's
version, and then waits for approval of the `pypi` environment. Approve it only
after the release assets above check out: a version uploaded to PyPI can be yanked
but never replaced.

## 6. Close the release

Confirm that the release page lists all five assets, <https://pypi.org/project/cabledyn/>
lists the sdist and the three wheels of the release, the documentation builds from
the tag, the GitHub source archives contain no credentials or run output, and a
fresh clone passes the fast test tier. Then add an empty `[Unreleased]` section to
the changelog.

## Publishing checklist for a new repository

Before the first release is published from a new GitHub repository:

- [ ] **About**: set the description and topics below, the website to
      <https://cabledyn.readthedocs.io>, and enable Releases.
- [ ] **Features**: enable Issues (the templates in `.github/ISSUE_TEMPLATE`
      disable blank issues); disable the Wiki and Projects unless they will be
      maintained.
- [ ] **Security**: enable private vulnerability reporting (used by
      [SECURITY.md](SECURITY.md)) and secret scanning.
- [ ] **Actions**: allow GitHub-hosted runners; the workflows need no secrets
      beyond the automatic `GITHUB_TOKEN`, and only the release job writes
      (`contents: write`).
- [ ] **PyPI**: on <https://pypi.org> and <https://test.pypi.org>, register a
      (pending) Trusted Publisher for the project `cabledyn`: this repository, the
      workflow `wheels.yml`, and the environments `pypi` and `testpypi`
      respectively. Create both environments in the repository settings and make
      a maintainer a required reviewer of `pypi`. The publish jobs then need no
      token (`id-token: write` only).
- [ ] **Branch protection** on `main` and `dev`: require pull requests, the `fortran` and
      `python` workflow checks, and linear history.
- [ ] **Read the Docs**: import the repository as project `cabledyn`, build
      `latest` and the release tag, and check the badge in the README.
- [ ] **Citation**: confirm that **Cite this repository** renders from
      `CITATION.cff`.

Suggested description:

> Finite-element solver for mooring lines and dynamic power cables of floating
> offshore wind: implicit statics and dynamics, cubic-Hermite bending cables,
> MoorDyn-format decks, OpenFAST coupling, a C API, and Python tools.

Suggested topics: `mooring`, `mooring-dynamics`, `cable-dynamics`,
`dynamic-power-cable`, `lazy-wave`, `floating-offshore-wind`, `offshore-wind`,
`offshore-engineering`, `marine-engineering`, `finite-element-method`,
`numerical-simulation`, `fortran`, `python`, `openfast`, `moordyn`.
