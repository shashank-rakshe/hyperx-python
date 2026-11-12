---
name: pynite-modelling
description: PyNite modelling: nodes, members, section data, supports, load cases and combinations
when: pynite|space frame|portal frame|truss (model|analysis)|continuous beam|plate bending model
---
# Modelling with PyNite (pynite_fea)

Build the model as data, in ONE consistent unit set (N, mm, MPa is the shipbuilding habit; kN, m, kPa also fine) - the answer comes back in those units.
- Nodes: name -> [x, y, z]. Put a node at every support, load point, change of section and joint. Members: name, i, j, material, section; PyNite subdivides members itself for results.
- Section data: A, Iy, Iz, J (use section_props / the profile tables for plated stiffeners: effective plating breadth matters). Material: E, nu (G follows), density only if self weight is wanted.
- Supports: fixed, pinned, roller_y / roller_x / roller_z or six flags [DX, DY, DZ, RX, RY, RZ]. A model with too few supports is a mechanism: the solver says so - add supports, do not loosen the check.
- Releases: member end hinges (a pinned end of a brace) as six flags per end.
- Loads: nodal (FX FY FZ MX MY MZ), member distributed (Fx Fy Fz, w1 to w2) with load cases and combinations (factors per case).
- Plates: a rectangular mesh (width, height, thickness, mesh size) with pressure and simply supported / clamped edges; use a mesh of at least 8 x 8 elements across, 20 x 20 for stresses.
- Hull girders and decks in a ship: model a transverse frame or a grillage with beams, a panel with plates; for a whole hull use the shell tools (cad_mesh / structure_to_mesh + CalculiX).
Do not invent section properties or loads: ask for them.
