---
name: Bug report
about: Report incorrect results, a crash, or a rejected valid input
title: "Bug: <short description>"
labels: bug
---

<!-- SPDX-License-Identifier: Apache-2.0 -->

## What happened

<!-- The error message or the wrong result, and what you expected instead. -->

## How to reproduce

<!-- Attach the smallest input that shows the problem (.dat deck, OpenFAST .fst with its
     MooringFile, or Python snippet) and every file it references. -->

```text
CableDyn_driver.exe my_deck.dat my_run
```

## Environment

- CableDyn version (`CableDyn_driver.exe --version`, or the banner in the log):
- Program: `CableDyn_driver.exe`, `openfast.exe` with `CompMooring = 5`, Python package, or
  source build
- OS:
- Source builds only: compiler and BLAS/LAPACK
- Python only: Python version

## Checks

- [ ] The problem occurs with the latest release.
- [ ] If results disagree with another code, I have described both models and the quantity
      compared (see [VALIDATION.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/VALIDATION.md)).
