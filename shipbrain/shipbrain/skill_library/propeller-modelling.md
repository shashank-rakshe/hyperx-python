---
name: propeller-modelling
description: screw propeller model inputs: diameter, blades, pitch ratio, expanded area ratio, hub, sections
when: propeller (model|geometry|design inputs)|pitch ratio|expanded area ratio|\bEAR\b|blade (number|count) of (a|the) propeller
---
# Propeller modelling

A screw propeller is set by: diameter D, number of blades Z, pitch ratio P/D (pitch over diameter, usually radially varying), expanded area ratio EAR (blade area over disk area, 0.4 to 1.0; more area for a
cavitation-limited propeller), hub ratio (about 0.18 to 0.25), section shapes (thickness, camber, zero-lift angle), skew and rake. The ShipBrain tool `propeller_bem` takes the first four, the hub ratio and a section drag
coefficient, with constant pitch and an elliptical chord - good for what-if studies, not for design.
- Ask for D, rpm, ship speed (knots) and the shaft immersion; the wake fraction and thrust deduction are NOT in the open-water curve: the speed of advance Va = V (1 - w) is the user's input (say so).
- Open-water coefficients: J = Va / (n D), KT = T / (rho n^2 D^4), KQ = Q / (rho n^2 D^5), eta0 = J KT / (2 pi KQ).
- For a real design use Wageningen B-series or the yard's propeller program; for a CFD of the propeller use OpenFOAM with an MRF zone (a rotating region) or STAR-CCM+ with a rigid-body motion, a hexahedral mesh
  with boundary layers and the thrust / torque from the force of the blade patches - ShipBrain does not run that case (see the knowledge on propeller CFD set-ups in the private packs).
