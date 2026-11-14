---
name: cbfem
description: component-based finite element analysis of a steel connection: plate plasticity, bolt forces, prying, capacity factor
when: cbfem|component.based|connection (fe|finite element|capacity)|plastic strain.*(bolt|plate|joint)|prying
---
# CBFEM of steel connections (steel_cbfem)

When the user wants a finite element analysis of a steel connection (plate yielding, bolt forces, prying, "CBFEM", "like IDEA StatiCa"), call
`steel_cbfem`. It is ShipBrain's OWN component-based FEM (the published method): plates are elastic-plastic shells (fy, optionally fu), bolts are springs with EN 1993-1-8
tension, shear and bearing capacity, plates touch through compression-only contact, welds are shared nodes. IDEA StatiCa is a commercial program and is not used.

Kinds: end_plate (bolted moment joint beam to column flange), fin_plate (shear tab), base_plate (column on plate, 4 anchors). Not available: splices, welds as a check, buckling.
Inputs: sections (IPE / HEA / HEB / AISC W shapes), bolt "M20-8.8", rows, plate thickness; loads at the connection: V shear (kN, downward), M moment (kNm; beams positive =
hogging, top flange tension; column base about the strong axis), N axial (kN; base plate: compression positive). Ask for missing loads and sections first.
Answer in plain words: load factor of the first limit (plastic strain 5 %, bolt tension / shear / bearing / interaction, collapse), pass / fail at the design load, the most loaded
bolt, the peak plastic strain. A failing connection: change one thing that addresses the limit (thicker plate, more or larger bolts, more rows) and run again.
Runtime: fin plate and base plate about half a minute, end plate about 2-3 minutes: tell the user it takes a moment.
Accuracy to say when asked: T-stubs against the EN 1993-1-8 formulas, flange yielding +19 %, bolt-limited -16 %; plate plastic collapse within +13 % of the analytic value.
Use it to find the weak part and compare variants; keep the normal code check next to it. Mesh size: default 30-50 mm, smaller is slower; if CalculiX cannot solve a mesh size the tool tries neighbouring sizes.
