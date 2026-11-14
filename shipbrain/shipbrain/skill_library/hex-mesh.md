---
name: hex-mesh
description: hexahedral (brick) mesh of a solid part for FEA - castings, foundations, shaft brackets, lugs, thick plates
when: \b(hex(ahedral)?|brick|solid mesh|castings?|forgings?|foundations?|shaft bracket|lugs?)\b
---
1. file_info(file) - solid or plates? Thin plates / stiffened panels are NOT for this: use shell meshes (panel_mesh,
   cad_mesh, plates_mesh). Hex bricks are for thick, compact parts.
2. Cell size: ask or propose - at most a third of the thinnest wall, about 1/20 of the part for a first look; finer
   (half the size) wherever stress concentrations matter (holes, fillets). hex_mesh(file, size, to="inp"|"bdf"|"fem").
3. Answer: elements and nodes, volume against the exact volume, the worst scaled Jacobian (above 0.3 is fine), the file,
   and the limits: a uniform grid follows curved surfaces in steps (snapped onto the surface), tiny features vanish
   below the cell size; stress at fillets / holes needs a finer run (halve the size and compare).
4. Next: analysis_run / solve on the file, or tensor_fem for a quick elastic check.
