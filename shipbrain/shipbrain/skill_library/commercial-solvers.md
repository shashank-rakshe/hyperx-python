---
name: commercial-solvers
description: ANSYS (Mechanical, Fluent), Abaqus, STAR-CCM+ - what ShipBrain can do with them and what it cannot
when: fluent|star-?ccm|simcenter|\bansys\b|abaqus|\bmapdl\b|\bodb\b
---
# ANSYS, Abaqus, Fluent, STAR-CCM+ (commercial: the user's own licence)

ShipBrain cannot run these here and cannot test them without a licence - say so, then do what is possible:
- Structure, Abaqus or ANSYS: ShipBrain's mesh and loads are written as an Abaqus `.inp` / ANSYS `.mac` / Nastran `.bdf` (fe_convert), and with `solve` they run in the user's installed solver
  (find_solvers lists what is installed; the Abaqus and ANSYS adapters follow the documented batch commands and are not tested). The flow-to-stress model (flow_load_stress) is an `.inp` with *CLOAD
  forces: it opens in Abaqus as it is. Their result files (.odb, .rst) are closed formats: ask for an export (CSV, .vtu, or the mesh as .inp / .bdf).
- CFD, Fluent or STAR-CCM+: `cfd_export` writes the mesh in Fluent .msh format (checked with OpenFOAM's importer), a setup sheet and a PyFluent script or a STAR-CCM+ macro (written from the
  documented APIs, never run). The same case runs here in OpenFOAM (openfoam_flow) - suggest running both to cross-check the drag.
- Results come back as exported CSV (Fluent: File > Export > Solution Data, ASCII; STAR-CCM+: exported table): uploaded, they are read by probe_result (value at any place) and drawn by show_result.
Never claim a commercial solver was run, or a script was tested, when it was not.
