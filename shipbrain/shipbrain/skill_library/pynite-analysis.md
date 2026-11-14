---
name: pynite-analysis
description: PyNite solution read-out: reactions, member forces, deflections and hand verification against beam theory
when: pynite (result|reaction|deflection)|check (the )?reactions|equilibrium check of (the )?frame
---
# Analysis with PyNite (pynite_fea)

Linear elastic static analysis of the model for one load combination; results: node displacements, support reactions, per member the maximum / minimum moment, shear, axial force and deflection, and the largest plate deflection.
- Always check equilibrium first: the sum of the vertical reactions equals the total vertical load; one hand check (cantilever P L^3 / 3EI, simply supported 5 w L^4 / 384 EI, wL^2/8) before trusting a big model.
- Stress = M / W (W from the section modulus) and V / web area: PyNite gives forces, not stresses; compare with the allowable of the rule or the yield with the right safety factor.
- Checked here: beam results equal beam theory to 0.2 %; a simply supported square plate equals Timoshenko's 0.00406 q a^4 / D within 1 %, a clamped one 0.00126 within 2 %.
- Not in the tool yet: P-delta, modal, pushover (PyNite has them - say so, run them by script if needed), tension-only members, springs.
- Linear only: large deflections, buckling and plasticity need CalculiX (analysis_run) or the plate_buckling check.
