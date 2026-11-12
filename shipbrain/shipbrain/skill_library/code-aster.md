---
name: code-aster
description: code_aster finite element solver from EDF, comm command file, export file, MED mesh, mfront material laws
when: code.aster|\.comm\b|\.export\b|\bMED mesh\b|mfront|LIRE_MAILLAGE|AFFE_MODELE|MECA_STATIQUE|STAT_NON_LINE|DEFI_MATERIAU|CALC_CHAMP
---
# code_aster

code_aster (GPL-3, EDF R&D; pack `code_aster`, 70 000+ chunks: Fortran / C++ / Python sources, command catalogues, user documentation and the astest validation cases) is a general structural and thermal finite
element solver: linear and nonlinear statics, modal, dynamics, buckling, thermal and thermo-mechanics, contact, fracture, many material laws (also user laws written in MFront).
It is NOT run inside ShipBrain (large Linux install): ShipBrain helps to write and understand the input, then the user runs it.
- A case is: a mesh (MED format, from Salome or gmsh), a command file `.comm` (Python syntax) and an `.export` file that names the files and the memory / time.
- Typical static chain: `mesh = LIRE_MAILLAGE(FORMAT='MED')`, `model = AFFE_MODELE(MAILLAGE=mesh, AFFE=_F(TOUT='OUI', PHENOMENE='MECANIQUE', MODELISATION='3D'))`, `mat = DEFI_MATERIAU(ELAS=_F(E=..., NU=...))`,
  `fieldmat = AFFE_MATERIAU(...)`, boundary conditions `AFFE_CHAR_MECA(DDL_IMPO=..., FORCE_FACE=..., PRES_REP=...)`, solve with `MECA_STATIQUE` (linear) or `STAT_NON_LINE` (nonlinear),
  post-process `CALC_CHAMP(CONTRAINTE=('SIGM_ELNO',), CRITERES=('SIEQ_ELNO',))`, write `IMPR_RESU(FORMAT='MED', ...)`.
- Shells: MODELISATION='DKT' (triangles) or 'COQUE_3D'; beams: 'POU_D_E' with AFFE_CARA_ELEM; the shell thickness and beam section are given in AFFE_CARA_ELEM.
- Look up a command or a validation case in the pack: the astest folder holds a verified example for almost every command.
- Units are the user's; code_aster is unit-free like Nastran (mm, N, MPa is common).
