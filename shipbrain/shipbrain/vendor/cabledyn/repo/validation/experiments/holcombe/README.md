<!-- SPDX-License-Identifier: Apache-2.0 -->

# Holcombe static lazy-wave experiment

This directory reproduces CableDyn's comparison with the 1:70 static lazy-wave cable experiment
of Holcombe et al. (2025), <https://doi.org/10.1016/j.oceaneng.2025.120384>. No model parameter
is fitted to the measurements.

## Model and data

- The model uses the 3.67 m hang-off-to-tether length, the attachment stations as revised in
  Holcombe's 2026 thesis (which resolves inconsistent stations in the journal tables), and the
  measured attachment properties from the journal article (`--module-properties article2025`).
- `experimental_markers.csv` holds the seven marker centres digitised from Fig. 7 of the
  open-access article, each with a two-pixel interval in both coordinates. The figure itself is
  not copied. `digitise_holcombe_fig7.py` reproduces the calibration from an image extracted from
  the source PDF.
- The rotational stiffness of the platform fixing was not measured, so results bracket it with
  a free-rotation limit and an ideal vertical clamp.
- Marker 7 defines the tether endpoint and is excluded from the position-error statistics.
- Marker-scale curvature is the inverse circumradius of each set of three adjacent markers,
  computed identically for measured and calculated centres.

## Reproduce

From the repository root, with `path/to/cabledyn.exe` replaced by the release executable or a
local build, run the 10 mm primary mesh:

```powershell
python validation/experiments/holcombe/prepare_holcombe_cases.py `
  validation/experiments/holcombe/experimental_markers.csv `
  validation/experiments/holcombe/work/h0p010 --element-length 0.01 `
  --module-properties article2025

python validation/experiments/holcombe/run_holcombe_cases.py `
  path/to/cabledyn.exe validation/experiments/holcombe/work/h0p010

python validation/experiments/holcombe/reduce_holcombe_cases.py `
  validation/experiments/holcombe/work/h0p010 `
  validation/experiments/holcombe/experimental_markers.csv
```

Repeat the three commands with element lengths 0.020 m and 0.005 m, writing to `work/h0p020`
and `work/h0p005`. Then write the mesh and marker-curvature summaries:

```powershell
python validation/experiments/holcombe/summarise_mesh_refinement.py
python validation/experiments/holcombe/reconstruct_marker_curvature.py `
  validation/experiments/holcombe/experimental_markers.csv `
  validation/experiments/holcombe/work/h0p010/holcombe_L3p67_discrete_pinned_h0p010.marker_comparison.csv `
  validation/experiments/holcombe/work/h0p010/holcombe_L3p67_discrete_rigid_h0p010.marker_comparison.csv `
  validation/experiments/holcombe/marker_curvature_comparison.csv `
  validation/experiments/holcombe/marker_curvature_plot.dat `
  validation/experiments/holcombe/marker_curvature_summary.json
```

## Results

The committed summaries and `provenance.json` record:

| Quantity | Free rotation | Ideal clamp |
| --- | ---: | ---: |
| Marker position RMSE | 39.4 mm | 69.4 mm |
| Peak marker-scale curvature error | 0.34% | 5.54% |

With the discrete buoyancy modules, refining from 212 to 771 elements changes a predicted marker
position by at most 0.007 mm for free rotation and 0.12 mm for the ideal clamp
(`mesh_refinement_summary.csv`).
