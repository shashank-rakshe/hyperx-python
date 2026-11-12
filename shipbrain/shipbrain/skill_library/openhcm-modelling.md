---
name: openhcm-modelling
description: OpenHCM file structure: contours, stiffener trace lines, flanges, compartments and the ShipBrain conversion
when: openhcm|hull condition model|\.hcm\b
---
# OpenHCM modelling (openhcm_read)

OpenHCM is the open XML format of the OpenHCM Consortium (class societies, CAD vendors) for the ship structure and the condition of the hull. A model holds Plates (id, thickness, an outer contour and inner contours
of Vertex x y z - or a triangle mesh), Stiffeners (id, type, orientation, thickness, height, offset, a trace line, directions, flanges with breadth and thickness) and Compartments (names, for tank and space grouping).
- ShipBrain reads it with its own reader. Flat contour plates and straight stiffener segments become a shell mesh (mesh = true, element size in mm); triangle-mesh plates and curved (non-flat) plates are listed as
  skipped - say so and offer cad_mesh on a STEP of the hull instead.
- Coordinates and thicknesses are assumed mm: check the units before quoting masses; steel density 7850 kg/m3 is assumed.
- Stiffener types map to flat bar / T / L / bulb flat (HP); a type ShipBrain does not know becomes a flat bar of the given height and thickness - tell the user.
