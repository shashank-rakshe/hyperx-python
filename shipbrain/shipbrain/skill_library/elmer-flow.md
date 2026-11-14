---
name: elmer-flow
description: CFD and fluid-structure interaction (flow bending a flexible plate) with Elmer FEM, with pictures
when: \bcfd\b|\bfsi\b|fluid.structure|\belmer\b|flow (past|around|over) (a |the )?plate|pressure distribution on|drag on (a |the )?plate
---
# Flow and FSI with Elmer (elmer_flow)

Use `elmer_flow` for a plate standing in a channel with water / seawater / air / oil flowing past it, 2D, lengths in metres, velocity in m/s.
- plate = rigid: pressure on the front and back, drag, Cd. plate = elastic (+ material steel / aluminium / rubber / plastic, or E_pa): two-way FSI - tip deflection and von Mises stress too.
- turbulence = laminar (checked against the exact channel flow) or sst (SST k-omega with wall functions: indicative only, check the converged flag).
- The answer names the pictures (velocity, pressure, displacement, stress) and a .vtu for ParaView: show them with show_result / tell the user the file names.
Be plain about limits: it is a 2D plate in a channel, not the user's 3D part; 3D flow around an arbitrary STEP, free surface / waves, ship hulls and
seakeeping are NOT covered. A steady laminar solution exists only at low Reynolds number: when the tool says "did not converge" do not quote the numbers as results.
Needs Elmer installed (ElmerSolver): if the tool says it is missing, give the install step (https://www.elmerfem.org).
