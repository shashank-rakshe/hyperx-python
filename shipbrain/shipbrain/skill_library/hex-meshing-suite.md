---
name: hex-meshing-suite
description: five hexahedral meshing methods and which one to use: along vector extrusion, solid map, AlgoHex frame field, PolyCube, HOHQMesh
when: hex(ahedral)? mesh(ing)?|along vector|solid map|polycube|hohqmesh|algohex|brick mesh|jacobian optimi[sz]|all.hex
---
# Hexahedral meshing: pick the method by the shape

From the owner's unified hex meshing suite (pack `mayo-develop`, folder addon_hexmesh_suite) and ShipBrain's own tools. Auto mode first classifies the shape and runs the best method; after meshing check the Jacobian quality and export to the solver format.
- **Along vector (extrusion):** extrude a 2D quad / tri mesh through the thickness, with layers and bias. Best for ship plates, decks, hull panels, flanges.
- **Solid map:** project a source face mesh onto the opposite face (transfinite interpolation). Best for frames, brackets, bulkheads and curved panels.
- **AlgoHex (frame field):** automatic, aligned with surface and sharp edges. Best for complex free-form solids. ShipBrain tool: `hex_mesh_algohex` (needs AlgoHex built).
- **PolyCube:** map the solid to a polycube and back. For complex solids and research meshes.
- **HOHQMesh:** high-order hex / quad, for curved hull plates and sweep structures.
- ShipBrain's own voxel-based mesher: `hex_mesh` (simple, robust, aligned to the grid, not to curved surfaces). Judge any hex mesh by the scaled Jacobian, aspect ratio and warp; export to Nastran, Abaqus or CalculiX with `fe_convert`.
