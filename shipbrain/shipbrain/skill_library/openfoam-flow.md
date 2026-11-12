---
name: openfoam-flow
description: 3D CFD past a plate or a STEP part with OpenFOAM, and the flow-to-stress chain on the part's shell model
when: openfoam|simplefoam|flow (load|force)s? on (the |my |a )?(part|plate|structure)|water at [0-9.]+ ?m/s|wind load on|current load on|flow.*(then|and).*stress
---
# OpenFOAM flow (openfoam_flow, flow_load_stress)

- `openfoam_flow`: steady incompressible flow (simpleFoam), laminar or SST k-omega, past a plate (plate_t, plate_h, plate_w) or a part from a STEP / STL file; 2D (no width) or 3D.
  Returns drag, vertical force, Cd, pressure and velocity ranges and pictures (velocity, pressure slices). SI units; STEP files are read in mm.
- `flow_load_stress`: for "apply the flow load and show the stress" on a STEP part: OpenFOAM flow -> the face forces become nodal forces on the part's shell mesh
  (their sum equals the flow force) -> CalculiX displacement and von Mises -> pictures. Needs fix = the supports in the part's mm, e.g. [{"x": -500, "dof": "123456"}], and the
  plate thickness (thickness_mm). The part stands on the channel floor, flow along +x: say so, and ask which way the user wants it turned if that matters.
- Laminar steady only works at low Reynolds number (the tool says when it diverged): use sst for water / air at m/s speeds.
- Be plain: the part wall is stair-stepped on the grid (rough for curved parts), results are checked only for plates against Elmer and the exact channel flow, the structure
  is one-way coupled. Free surface, waves and ship hulls with seakeeping are not covered. For a flexible plate with strong coupling use elmer_flow (two-way FSI).
- Needs OpenFOAM installed (simpleFoam on the PATH; Ubuntu: apt install openfoam).
