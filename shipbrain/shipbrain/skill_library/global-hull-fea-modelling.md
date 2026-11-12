---
name: global-hull-fea-modelling
description: global hull girder shell model of a tanker: three-point supports, end moments, equilibrium of loads
when: global (hull|ship) (fea|fem|analysis|model)|hull girder (fea|model)|whole.ship (fea|model)|cargo hold (fea|model)
---
# Global hull girder FE - modelling

A global model of the hull (tanker, bulk carrier) is a shell model of the whole hull with the longitudinal and transverse structure, used for the hull girder response and to feed local models.
- Geometry: plates as shells, stiffeners as beams (or smeared by equivalent thickness in a coarse model), girders and web frames; 3 to 4 elements between the frames / girders in the global model; one element over the
  web height of primary members. Use the structure_to_mesh / cad_mesh tools; keep the mesh quality check (mesh_check) green.
- Supports: do not fix the hull rigidly: use the inertia-relief / three-point (statically determinate) support set: aft end node centre line (X, Y, Z), forward end node (Y, Z) and one node on the other side (Z), or an
  inertia-relief load case. Rigid supports create spurious stresses.
- Loads: still-water bending moment and shear, wave bending, torsion and horizontal bending as end moments (rigid-body RBE3 / multi-point connection at the ends) or as distributed pressure and cargo loads in equilibrium;
  hydrostatic + dynamic pressure on the shell, tank and cargo loads, hull weights: the load case must be in equilibrium (sum of forces and moments zero) before any analysis.
- The class rules supply the load values; they are kept private - ask the user for the rule loads or the loading manual.
- Reference worked example (private pack of the repository, no licence): a tanker model with ANSYS command files for vertical bending, horizontal bending, shear force and torsion cases and a report.
