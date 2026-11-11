<!-- SPDX-License-Identifier: Apache-2.0 -->

# Contributing to CableDyn

Contributions are welcome: bug reports, documentation fixes, validation cases, and
code. This guide sets out how to contribute and the standards a change must meet.
Build, test, and tooling commands are in
[DEVELOPMENT.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/DEVELOPMENT.md);
the solver design is in
[ARCHITECTURE.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/ARCHITECTURE.md).
Everyone taking part follows the
[Code of Conduct](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/CODE_OF_CONDUCT.md).

## Contributing upstream

If you have extended or corrected CableDyn in your own copy, please consider
offering the change here. A change merged upstream is tested on every platform in
CI, carried into the validation record, and maintained with the rest of the code,
and every user benefits from it. Open an issue first for a larger change so that
the design can be agreed before you invest in it.

## Issues

- **Bugs**: use the bug-report template. Include the CableDyn version, platform,
  a minimal deck or script that reproduces the problem, and the full error output.
- **Enhancements**: use the feature-request template and describe the physical
  problem the feature solves.
- **Questions**: use the question template; see
  [SUPPORT.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/SUPPORT.md).
- **Security issues**: follow
  [SECURITY.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/SECURITY.md);
  do not open a public issue.

## Development setup

```powershell
git clone https://github.com/SMI-Lab-Inha/CableDyn.git
cd CableDyn
conda env create -f environment.yml
conda activate cabledyn
pre-commit install
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build -L fortran -LE slow --output-on-failure
```

The conda environment provides gfortran, CMake, LAPACK, Python, and the
formatting tools on Linux, macOS, and Windows. The full suite, the Python package,
and the OpenFAST build are described in
[DEVELOPMENT.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/DEVELOPMENT.md).

## Pull requests

`main` holds the released code; new work collects on `dev` until the next release.

1. Fork the repository and branch from `dev` with a descriptive name
   (`fix/<topic>`, `feat/<topic>`, `docs/<topic>`, `test/<topic>`, `perf/<topic>`,
   `ci/<topic>`).
2. Keep each pull request to one change. Add or update tests for it.
3. Run `pre-commit run --all-files` and the test suite (see
   [DEVELOPMENT.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/DEVELOPMENT.md)).
4. Open the pull request against `dev` with a
   [Conventional Commits](https://www.conventionalcommits.org) title and complete
   the template.
5. CI must pass and a maintainer must approve before merge. Pull requests are
   squash-merged.

Commit messages follow Conventional Commits: a subject of at most 72 characters,
and a body that explains why the change is needed.

```text
feat: add Hermite cable drag element
fix: correct tangential drag sign on the Hermite path
test: add convergence-order case for the bending patch
```

Do not bypass hooks with `--no-verify`. Commits must be attributed to the people
who wrote them.

## Standards

- **Tests**: every behaviour change carries a CTest or pytest case. Numerical
  changes compare against a closed form, an independent reference, or a
  conserved quantity.
- **Validation**: if a change alters a validation result, tolerance, or reference,
  update
  [VALIDATION.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/VALIDATION.md)
  in the same pull request.
- **Documentation**: document only implemented and tested behaviour. Update the
  manual in `doc/` and add a
  [CHANGELOG.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/CHANGELOG.md)
  entry under `[Unreleased]` for user-visible changes (add that heading above the
  latest release if it is not there yet).
- **Errors**: unsupported inputs stop with a specific error message; never return
  an approximate result silently.
- **Fortran**: see the coding standards in
  [DEVELOPMENT.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/DEVELOPMENT.md#coding-standards).
- **Python**: `ruff` for linting and formatting, `mypy --strict` for types,
  `pytest` for tests; line and branch coverage of the package stays at or above
  95%.
- **Other codes**: describe differences from MoorDyn, OpenFAST, OrcaFlex, or any
  other code neutrally and with the evidence, and cite them as listed in the
  manual's references.

## Repository contents

- Manual pages and interface specifications go in `doc/`.
- `examples/*.dat` files are runnable decks; auxiliary tables go in
  `examples/data/`.
- Reference data and reproduction scripts go in `validation/`; release checks in
  `release/`; OpenFAST integration scripts and patches in `integration/openfast/`.
- Do not commit build trees, solver output, editor settings, third-party source
  trees, copyrighted papers, or manuscript sources.

## Licence and sign-off

CableDyn does not use a contributor licence agreement. As Section 5 of the
[Apache License 2.0](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/LICENSE)
provides, a contribution you submit is licensed under the same licence. Sign off
each commit (`git commit -s`) to certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/): that you
wrote the change or otherwise have the right to submit it under this licence. New
source files carry the SPDX header given in
[DEVELOPMENT.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/DEVELOPMENT.md#spdx-headers).
