---
name: native-cad
description: native CAD files (SolidWorks, CATIA, Inventor, Fusion 360, Rhino, FreeCAD, ACIS, IGES, NX, Creo) - open, check, measure, compare, convert to STEP without the CAD program
when: \.(sldprt|catpart|ipt|iam|f3d|3dm|fcstd|sat|sab|smt|igs|iges|pvz|prt)\b|solidworks|catia|inventor|fusion 360|rhino|freecad|native cad
---
1. native_cad(file, op="inspect") - say in one line what it is (format, version, bodies) and how well cadmpeg reads this
   format: STEP / IGES / FreeCAD / Fusion fully, SolidWorks / CATIA / Inventor / ACIS as solids, Rhino geometry only,
   NX and Creo .prt only listed (no geometry yet) - say so plainly instead of guessing.
2. native_cad(file, op="convert") -> STEP. Report the check result and what was not carried over (features / history /
   colours / PMI) from its decode report. If geometry was not transferred, say so and suggest a STEP export from the
   CAD program.
3. Then as asked, with the STEP (or the native file directly - the CAD tools convert it on the way in):
   file_info, cad_mesh / surface_extract for FEA, cad_view_check for pictures, compare_structures for comparisons,
   native_cad(op="measure", density=7850) for volume / mass / inertia, native_cad(op="diff", other=<file>) to compare two
   versions or a native file with its STEP export.
4. Encrypted or licence-locked files are refused by cadmpeg on purpose: never try to get around it.
