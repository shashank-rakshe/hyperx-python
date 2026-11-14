---
name: hex-mesh-algohex
description: frame-field hexahedral mesh with AlgoHex for curved solid parts
when: algohex|frame.?field|all.?hex(ahedral)? mesh|better hex
---
# Frame-field hex meshes (hex_mesh_algohex)

AlgoHex (AGPL, cgg-bern, "Locally Meshable Frame Fields") makes hexahedral meshes that follow a smooth frame field - aligned with the
surface and sharp edges - instead of a voxel grid. Use it for curved solid parts when hex_mesh's voxel cells are not good enough at the surface.
ShipBrain makes the tetrahedral input from its own mesher (gmsh is never used), AlgoHex runs where the user installed it (their build, or the
"algohex" container image), and ShipBrain checks the result (hexes, inverted cells, scaled Jacobian, volume) and writes a CalculiX .inp.
If AlgoHex is not installed: give the install card, and use hex_mesh meanwhile. AlgoHex needs a lot of memory and time on big parts.
Results of AlgoHex built and run on GitHub (its demo and ShipBrain parts) are in the release "algohex-latest".
