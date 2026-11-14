---
name: nastran-pynastran
description: read or write Nastran bdf and op2 files with pyNastran, Nastran bulk data cards, PSHELL MAT1 SPC1 FORCE
when: pynastran|nastran (deck|file|model|bulk)|\bbdf\b|\bop2\b|\bf06\b|bulk data|\bCQUAD4\b|\bPSHELL\b|\bMAT1\b|\bSPC1\b
---
# Nastran files and pyNastran

pyNastran (BSD-3, pack `pyNastran`, installed with `pip install pyNastran`) reads and writes Nastran decks and results. ShipBrain tools: `nastran_read` (a .bdf/.nas/.dat deck: nodes, elements, element types, properties,
materials, loads, supports, mass, centre of mass, bounding box, SOL; an .op2: largest displacement and largest shell von Mises per subcase) and `nastran_plate_deck` (a cantilever plate deck: GRID, CQUAD4, PSHELL, MAT1,
SPC1, FORCE; SOL 101). Convert between Nastran / Abaqus / ANSYS decks with `fe_convert`; mesh checks with `fe_quality`.
- A deck has an executive control (SOL 101 static, 103 modes, 105 buckling, 106 nonlinear static, 111 / 112 dynamic), case control (SUBCASE, SPC, LOAD, output requests) and bulk data (BEGIN BULK ... ENDDATA).
- Nastran has no units: use one consistent set (SI: m, N, Pa, kg/m3, or mm, N, MPa, t/mm3). State the set.
- The units of the result are the units of the deck: a deck in metres gives displacements in metres.
- Cards: GRID (node), CQUAD4 / CTRIA3 (shell), CBAR / CBEAM / CROD (line), CTETRA / CHEXA (solid), PSHELL (thickness, material), MAT1 (E, G, nu, rho), SPC1 (fixed dofs), FORCE / PLOAD4 (loads).
- OP2 is Nastran's binary result file; F06 is the printed result: text, searched for maxima.
- Check the first thing after reading a deck: free nodes, supports present (rigid-body motion), the units, and the mass against hand estimate.
