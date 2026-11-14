<!-- SPDX-License-Identifier: Apache-2.0 -->

# Validation data

This directory is for reviewers and users who want to check or reproduce the published
CableDyn assessments. It holds the compact inputs, reduction scripts and numerical
results; the case definitions and pass criteria are in [`VALIDATION.md`](../VALIDATION.md).
Source publications, third-party models for OrcaFlex (Orcina) and OrcaFlex output files are not
redistributed.

| Path | Contents |
| --- | --- |
| [`RELEASE_0_4_0.md`](RELEASE_0_4_0.md) | Toolchains, test results, dependency revisions and asset hashes for v0.4.0 |
| [`RELEASE_0_3_0.md`](RELEASE_0_3_0.md) | The same for v0.3.0 |
| [`RELEASE_0_2_0.md`](RELEASE_0_2_0.md) | The same for v0.2.0 |
| [`RELEASE_0_1_1.md`](RELEASE_0_1_1.md) | The same for v0.1.1 |
| [`RELEASE_0_1_0.md`](RELEASE_0_1_0.md) | The same for v0.1.0 |
| [`bodies/`](bodies/README.md) | Rigid-body, rod and shared-anchor cases with MoorDyn-C twins, stored references and pass limits |
| [`experiments/`](experiments/README.md) | Holcombe et al. (2025) static lazy-wave and Bergdahl et al. (2016) dynamic-chain comparisons |
| [`PERFORMANCE_0_1_0.md`](PERFORMANCE_0_1_0.md) | Wall time of CableDyn 0.1.0, MoorDyn-C and MoorDyn-F at equal accuracy on five mooring, cable, buoy and coupled cases |
| [`performance/`](performance/README.md) | Same-host wall-clock records of the L5 cases: the resolved lazy-wave spans, the one-hour VolturnUS-S mooring and the tension-only chain |
| [`PAPER_REPRODUCTION.md`](PAPER_REPRODUCTION.md) | Every CableDyn result in the journal article, re-run with the release defaults and in paper mode |
| [`OPENFAST_DLC_VERIFICATION.md`](OPENFAST_DLC_VERIFICATION.md) | Design-load-case comparison against stock MoorDyn-F in OpenFAST, maintained by NLR (National Laboratory of the Rockies, formerly NREL) |
| `scripts/` | Cross-code comparison and reference-generation scripts cited in `VALIDATION.md` |

The experiment run scripts take the CableDyn executable path as an argument, so either the
release executable or a local build can be checked.

## OrcaFlex references

OrcaFlex comparisons are committed as the summary values the tests and records check:
statistics, peaks, harmonics and scalar results, with the OrcaFlex version, settings and
generating script recorded next to them. The `scripts/orcaflex_*.py` scripts rebuild each
OrcaFlex model through OrcFxAPI (OrcaFlex 11.6d) and regenerate the full output for OrcaFlex
licence holders.

| Comparison | Script | Committed summary | Full output |
| --- | --- | --- | --- |
| V-D1b buoy release (bodies suite) | `orcaflex_vd1b_reference.py ref --nseg 320 --dt 0.00025 --out DIR` | `bodies/references/V-D1b/orcaflex.json` (`summary`: statistics, dominant tension harmonic, snap maxima over t = 0.5-120 s), scored by `bodies_score.py` | time series in `DIR/*.npz` |
| L3-6c irregular sea | `orcaflex_lazywave_irregular_reference.py` | `REF_*` values in `tests/test_l3_lazywave_irregular.f90` | printed; the sea is CableDyn's seeded synthesis, so no wave table is needed |
| L3-6c, the article's sea | `orcaflex_lazywave_irregular_reference.py --orcaflex-jonswap TABLE.dat` | `ART_*` values in the same test | OrcaFlex's 78-component table in `TABLE.dat`; run `test_l3_lazywave_irregular OUT TABLE.dat` |
| T-2, T-5, T-6 torsion | `orcaflex_torsion_reference.py --refs tests/data/torsion_orcaflex_refs.txt` | `tests/data/torsion_orcaflex_refs.txt` (torques, buckling onsets, twist, peak curvature, offset, tension), checked by `test_torsion_orcaflex` | `build/validation/orcaflex_torsion_summary.json`: summary values and every setting with OrcaFlex's read-back |
| L-fig 800 m curvature overlay | `curvature_profile_overlay.py` | `tests/data/lfig_800m_curvature_summary.csv` | `build/validation/lfig_800m_curvature_profiles.csv` |
| L2-2 dynamic chain | `l2_2_orcaflex_summary.py <MoorDyn>/tests/Mooring/QuasiStatic` | `tests/data/l2_2_dynamic_refs/orcaflex_summary.txt` | the OrcaFlex series distributed with MoorDyn-C (BSD-3-Clause) |
| 800 m segment-length study | see `performance/ORCAFLEX_MESH_CONVERGENCE.md` | `performance/orcaflex_mesh_convergence.csv` | rerun of the listed meshes |

The remaining `orcaflex_*.py` scripts print the scalar references that the corresponding
tests hold as constants.
