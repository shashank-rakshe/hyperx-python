---
name: pynite-tool-knowledge
description: what PyNite is and what it can do beyond the tool (capabilities, limits, where the knowledge is)
when: what is pynite|pynite (can|capabilit|feature)|pyniteFEA
---
# PyNite - tool knowledge

PyNite (PyNiteFEA, MIT, D. Craig Brinck) is a Python 3D structural FEA library: beams with releases, trusses, springs and spring supports, tension / compression-only members, quadrilateral (DKMQ) and rectangular plate
elements, meshing helpers (rectangles, cylinders, openings), shear wall and mat foundation tools, load cases and combinations, and P-delta, modal and pushover analysis of frames. ShipBrain's `pynite_fea` tool wraps
frames, member and nodal loads, combinations and rectangular plates; the full library (examples: space frames, braced frames, beam on elastic foundation, modal analysis, mat foundation) is in the knowledge pack
`Pynite` - search it for the API of anything the tool does not expose. Use `frame_solve` (ShipBrain's own 3D frame solver) for ship frames from the structure model; use pynite_fea for plates and combinations.
Limits: elastic, small displacement; rectangular plate meshes only through the tool.
