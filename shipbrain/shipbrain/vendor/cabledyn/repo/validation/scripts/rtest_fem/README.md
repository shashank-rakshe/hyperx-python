<!-- SPDX-License-Identifier: Apache-2.0 -->

# FEM-observable comparison manifests

This directory is for developers who compare CableDyn results with another solver's output
(MoorDyn, OrcaFlex, OpenFAST or other). The comparator,
[`fem_observable_compare.py`](../fem_observable_compare.py), scores solver-neutral physical
observables, so the other solver's discretisation never becomes part of CableDyn's model.

```text
python validation/scripts/fem_observable_compare.py manifest.json \
  --reference-root external/r-test/modules/moordyn \
  --candidate-root build/rtest-cabledyn
```

`--case <name>` runs one manifest case; `--json` prints machine-readable results. The OpenFAST
`r-test` checkout is not needed by CI.

## Manifest rules

- **Names.** Each observable name starts with `line`, `cable`, `connector`, `body`, `vessel` or
  `environment`. Channel names may use MoorDyn or CableDyn spelling; solver-internal objects,
  such as a MoorDyn rod node, are rejected. Suitable quantities are endpoint loads,
  fairlead/anchor tension, platform response, touchdown location, and positions or curvature at
  normalised arc-length stations.
- **Limits.** Each observable must declare a non-empty `limits` object with one or more of
  `nrmse`, `bias`, `std_relative` and `peak_relative`. A missing or empty object is an error.
- **Normalisation.** Use range normalisation for dynamic signals and magnitude normalisation for
  static or nearly static loads.
- **Time.** Candidate values are interpolated onto the reference timestamps. MoorDyn/OpenFAST
  `Time` and CableDyn `Time(s)` headers, including bracketed and case variants, map to the same
  column. Header and unit rows may wrap, but every numeric row must contain exactly one finite
  value per channel; malformed rows are rejected, never re-chunked.
- **Profiles.** For an along-line profile, set `reference_axis` and `candidate_axis` to
  `ArcLength`, select the line with `reference_filter` / `candidate_filter` (for example
  `{"LineID": 1}`), and set `normalize_axis` to `true`. Each solver's arc coordinate is mapped to
  0–1 before interpolation, so different meshes and slightly different deformed lengths are
  compared at the same material fraction. A normalised profile uses the whole selected line;
  combining `normalize_axis` with an axis or time window is rejected.
- **Units.** `reference_scale` and `candidate_scale` multiply a channel before scoring (default
  1), for example `"reference_scale": 1000.0` for a reference in kN against a candidate in N.
  The MoorDyn r-test histories already report `FAIRTEN`/`ANCHTEN` in N and need no scaling.

## Template

`moordyn_line_cases.template.json` covers the OC4Semi endpoint tensions, the near-vertical
touchdown case and the viscoelastic line. Its limits are starting values, not validation
results; a case counts as validation only when its CableDyn deck, protocol, reference version
and measured result are recorded in [`VALIDATION.md`](../../../VALIDATION.md).
