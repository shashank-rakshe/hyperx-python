---
name: reverse-cad
description: STL mesh (3D scan, 3D-print file, mesh export) to a STEP solid with its features - holes, threads, fillets, mass - and a check of the result
when: \b(stl|reverse.?engineer\w*|scan(ned)?|mesh to (step|cad|solid)|3d.?print\w*)\b
---
1. file_info(file) - say in one line what the mesh is (triangles, size, watertight or not).
2. reverse_cad(file, material=<the user's material, if named>) - ReverseCAD makes a STEP solid, lists the holes, ISO
   threads, fillets, chamfers, slots and cavities it recognised, mass properties, and checks the STEP against the mesh.
   For exact curved faces (planes, cylinders, cones, spheres, tori as true surfaces) also stl_to_step(file, unit).
3. Answer: the STEP file, size, volume (and mass only when a material was named), the features - say they are
   recognised from the mesh and must be checked on the part (a plain hole can be read as a tapped one) - and whether its
   verification passed. Mention once that ReverseCAD is for non-commercial use only.
4. Next steps as asked: cad_view_check for pictures, cad_mesh / repair_model for FEA, compare_structures for a
   comparison with a drawing or model.
