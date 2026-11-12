---
name: global-hull-fea-tool-knowledge
description: which ShipBrain tools do the global hull FE steps and what the example repository contains
when: global (hull|ship) (tool|workflow)|which tool.*(hull girder|global)
---
# Global hull girder FE - tool knowledge

ShipBrain route: STEP of the hull or the structure model (structure_to_mesh, cad_mesh) -> mesh_check / fe_quality -> loads and supports (cad_mesh fix / loads, or edit the .inp) -> analysis_run (CalculiX, static) ->
show_result (stress picture) and probe_result (value at a place) -> hull-girder hand checks with section_props. For another solver, fe_convert writes Abaqus / ANSYS / Nastran decks.
The repository "Global Ship Hull Structural Analysis Based on the Finite Element Method" (D. Melozzi) holds ANSYS command files for a tanker (vertical, horizontal, shear and torsion cases), a spreadsheet and a report.
It has no licence: only a private knowledge pack (for your own computer) exists; ShipBrain does not copy or train on it - the skills here are written from general naval architecture knowledge.
