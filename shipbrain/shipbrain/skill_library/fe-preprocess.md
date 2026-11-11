---
name: fe-preprocess
description: pre-processing like HyperMesh / ANSA - geometry cleanup, mid-surface, meshing, element quality, model check, properties, loads, solver deck
when: \b(hypermesh|hyper mesh|optistruct|\.fem\b|ansa|pre-?process|element quality|mesh quality|jacobian|warpage|skew|taper|quality criteria|criteria file|model checker)\b
---
HyperMesh (Altair) is a paid pre-processor. ShipBrain does the same steps with its own free tools; a user who has
HyperMesh gets files it imports directly. Work in this order (the order HyperMesh users follow):
1. Import and look: file_info(file). CAD (STEP/IGES/BREP) -> step 2; an FE deck (.bdf/.fem/.inp) -> step 5.
2. Geometry cleanup (HyperMesh "geometry cleanup / defeature"): repair_model(file, request=<the user's words>)
   removes holes, fillets, chamfers, small faces, then sews free edges.
3. Mid-surface of plates (HyperMesh "midsurface"): surface_extract(file, kind="mid", mesh_size=<size>).
   Stiffened ship panels from a drawing or OCX: structure_to_mesh / plates_mesh / panel_mesh (ShipBrain's own mesher).
4. Meshing (HyperMesh "automesh"): mostly quads, size from the user (cargo hold ~ one element between stiffeners,
   fine mesh t x t at hot spots: fatigue_mesh). cad_mesh for solid parts.
5. Quality (HyperMesh "check elements" / "quality index"): fe_quality(file, mesh_size=<size>, criteria=<the user's
   limits>) -> aspect, warpage, skew, taper, Jacobian, corner angles, shortest edge, share of triangles, plus the model
   check. Use the limits the user or their class guideline gives; the built-in ones are typical, say so.
6. Connectivity (HyperMesh "edges / equivalence / free edges"): mesh_check(file); fe_edit ops equivalence{tol},
   remove_free_nodes, orient_normals, remove_degenerate, remove_small_parts - or repair for all of them.
7. Properties, materials, loads, constraints (HyperMesh "property / load collectors"): set_thickness via fe_edit;
   loads and supports through analysis_run / solve.
8. Solver deck (HyperMesh "export"): fe_convert(file, to=[...]) - fem = OptiStruct (HyperMesh opens it with the
   OptiStruct profile), bdf = Nastran, inp = Abaqus / CalculiX, mac = ANSYS. Run free: solve(file, solver="mystran")
   or analysis_run (CalculiX).
9. Answer in plain words: what was checked, how many elements fail which limit (with the worst values), what was
   fixed, which files were written, and the sets file that shows the failing elements in HyperMesh or any other
   pre-processor. Never claim a HyperMesh menu or Tcl command you are not sure of.
