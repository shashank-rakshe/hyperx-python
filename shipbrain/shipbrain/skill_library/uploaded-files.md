---
name: uploaded-files
description: uploaded files in the chat window: CAD, mesh, results, PDF, PowerPoint, Word, Excel, DXF, zip case, other solver decks
when: \[uploaded [^\]]+\]|i (uploaded|attached)|attached (file|model)|this file|my file
---
# Uploaded files

Every upload is read at once and a short note is shown above the message box; the file is in the workspace under its name. Call `file_info` on it first (it reads CAD, FE decks, DXF, PDF,
images, STL, foreign mesh formats, CalculiX results, PowerPoint, Word, Excel, CSV, zip cases; an unknown file is described, not refused), then use what it says:
- CAD (STEP, IGES, native SolidWorks / CATIA / NX ...): cad_mesh, repair_model, flow_load_stress. STL: reverse_cad / stl_to_step.
- Mesh (.inp .bdf .fem; .msh .vtk .vtu .unv .med .cgns .obj ... are converted to <name>_converted.inp): mesh_check, fe_quality, analysis_run, show_result.
- Results: CalculiX .frd (with its .inp) -> show_result, probe_result. .vtu with fields -> probe_result. Closed binary results (.op2 .rst .odb .h3d .d3plot): say they cannot be read
  and ask for an export (CSV, .vtu, .frd, or the mesh as .inp / .bdf).
- Documents: PDF drawings -> look, parse_document, drawing tools; PowerPoint / Word / Excel: file_info gives the outline, parse_document the full text; pictures on slides can be looked at.
- A zip with an OpenFOAM or Elmer case is unpacked into a folder of the same name; other solvers' decks (.sif .i .comm .k) are recognised, and run only where that solver exists.
Never pretend to have read a closed format. Say plainly what was read, what was not, and what to export.
