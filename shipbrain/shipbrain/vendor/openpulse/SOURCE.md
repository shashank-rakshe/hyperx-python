OpenPulse - https://github.com/MOPT-UFSC/OpenPulse (GPL-3.0; MOPT, Federal University of Santa Catarina; authors in AUTHORS.txt),
commit 737e250 (2026-08-13). Copied: every Python file of the `pulse` package UNCHANGED, except pulse/interface/data (10 MB of generated
resource modules, never imported by a calculation); icons, Qt .ui layouts, STL/OBJ models, docs, examples and the test data are left out.
tests/helpers.py is kept (it writes the temporary fluid / material libraries a run needs).

How ShipBrain runs it (shipbrain/pulsation.py, own code):
- OpenPulse meshes its geometry with gmsh. ShipBrain never uses gmsh, so pulsation.own_mesh() builds the same mesh data (nodal
  coordinates, line connectivity in OpenPulse's get_connectivity format, line maps) from the route, and OpenPulse's own preprocessor,
  assembly and solvers run on it.
- OpenPulse imports its desktop interface (PySide6 / Qt, molde / VTK, polars) at package level. shipbrain/openpulse_shim.py answers those
  imports with placeholders inside the separate OpenPulse process; gmsh gets a placeholder that refuses to run.
Real packages needed: numpy, scipy, h5py (project files), ordered-set.

Checked (tests/test_pulsation.py): acoustic modes of a closed-closed and an open-closed pipe equal n c / 2L and (2n-1) c / 4L (first mode exact,
higher modes within 0.03 %), with water the pipe-wall correction c / sqrt(1 + D K / (E t)) of Lin & Morgan as used by OpenPulse; a three-leg route
gives n c / 2 L_total (the corners connect); structural modes of a simply supported pipe equal the exact Timoshenko beam solution within 0.02 %.
OpenPulse's own regression tests use IGES geometry meshed by gmsh, so they are not run here.
