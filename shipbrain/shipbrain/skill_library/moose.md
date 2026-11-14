---
name: moose
description: MOOSE multiphysics (INL) - shell plates under pressure, solid mechanics, contact, heat transfer, fracture (XFEM), Navier-Stokes, porous flow; input files (.i)
when: \b(moose|moose-opt|\.i file|multiphysics|xfem|thermo-?mechanical|coupled (heat|thermal))\b
---
1. A plate field under lateral pressure: moose_plate(a = span, b = stiffener spacing, t, q, clamped). Answer the deflection
   and its difference to the Navier series (simply supported) - a check of the model, not of the design.
2. Anything else in MOOSE: write the input file from MOOSE's own examples (knowledge_search "moose <topic>" - the
   pack holds its docs and test inputs), then moose_run(input). Never invent object names or parameters: use only
   those in the docs / test inputs found.
3. MOOSE missing: give the install card (Docker image idaholab/moose is the easiest). Meshes come from ShipBrain's own
   mesher (.msh written by ShipBrain, or Abaqus .inp) - never generate meshes with Gmsh.
