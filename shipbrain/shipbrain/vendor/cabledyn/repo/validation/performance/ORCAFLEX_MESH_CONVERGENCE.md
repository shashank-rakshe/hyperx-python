<!-- SPDX-License-Identifier: Apache-2.0 -->

# OrcaFlex mesh convergence for the 800 m suspended span

This page documents how the OrcaFlex segment length for the 800 m cross-code and performance
comparisons was chosen.

The matched pinned-TDP 800 m model was run with target segment lengths of 3.0, 1.5, 0.75 and
0.375 m. The 0.05 s implicit step, prescribed motion, hydrodynamic coefficients and 24–60 s
assessment interval were the same in every run.

The dynamic peak curvature increased from 0.03797 to 0.03861, 0.03881 and 0.03886 m⁻¹. The
final halving changed the peak by 0.13%. HOP-tension mean, minimum and maximum were already
stable to the reported precision. The 0.75 m mesh is used for the comparisons; the 0.375 m mesh
doubles the segment count for a 0.13% change in peak curvature.

To reproduce, run from the repository root in an environment with the licensed OrcFxAPI 11.6d
interface:

```text
python validation/scripts/orcaflex_lazywave_dynamic_reference.py 800m --segment-lengths 3 1.5 0.75 0.375
```

The results are in `orcaflex_mesh_convergence.csv`.
