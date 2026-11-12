---
name: fvm-1d
description: 1D finite volume method teaching scripts (diffusion, convection, fin, SIMPLE) - which ones are verified and which are not
when: \b(finite[- ]volume|fvm)\b|\b1d (cfd|diffusion|convection)\b|\bupwind scheme\b|\btdma\b|\bsimple algorithm\b
---
The knowledge pack `Finite-Volume-Method-for-1D-CFD-Simulations` (MIT, MATLAB scripts) was run in Octave and checked against exact solutions.
There is NO ShipBrain tool that runs a 1D CFD case yet: say so, explain the method from the scripts, and run them with the code tools / Octave only when asked.

Verified:
- oned_diffusion.m: plain conduction, exact (linear profile).
- oned_diffusion_with_heat_generation.m: error is exactly q dx^2 / (8 k), second order (4, 1, 0.25, 0.0625 C for 5, 10, 20, 40 nodes).
- oned_diffusion_convection_CDS.m: central scheme against the exact exponential profile, second order (0.0074, 0.0019, 0.0005, 0.0001).
- oned_SIMPLE_Algorithm.m: constant-area duct, velocity 10 m/s everywhere, mass flow conserved.
Defects of the original scripts (do not use their results as they are):
- oned_fin.m: the east coefficient of node 1 (ae(1)) is never set, so the base node is not coupled to node 2 and the temperatures are wrong
  (63 C instead of 82 C at the first node, error grows with the grid). One line `ae(1) = 1/dx;` fixes it (error then falls 4.3, 1.7, 0.52, 0.14 C).
- oned_diffusion_convection_UpwindScheme.m: unfinished - the tridiagonal arrays a, b, c, d are never created or filled; it stops with "c undefined".
These are teaching scripts: fixed small grids, MATLAB, no mesh or property input.
