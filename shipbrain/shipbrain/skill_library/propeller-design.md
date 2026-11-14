---
name: propeller-design
description: design a propeller for a required thrust, ducted propeller, optimum circulation, 3D blade surface STL, BladeX
when: design (a|the) propeller|propeller design|optimum (circulation|propeller)|ducted propeller|lifting.line|blade (surface|geometry|stl)|bladex|openprop|pythonprop|pitch (distribution|for a thrust)
---
# Propeller design and blade geometry

Two tools, both from licensed repositories (see packs `PythonProp`, `OpenProp`, `BladeX`):
- `propeller_design` (PythonProp, GPL-3; Epps lifting-line method of OpenProp): needs blades Z, rpm, diameter D, required thrust (N) and ship speed Va (m/s, the speed of advance after the wake). It returns the design
  KT, KQ, efficiency, torque, power, radial circulation, c/D, P/D, t/c, f/c along the radius and the off-design curve against J. `duct=true` adds a duct (tau = share of thrust on the propeller, default 0.9).
  `blade_stl=true` writes the blade as an STL.
- `blade_geometry` (BladeX, MIT): your own radii, chord lengths, pitch, rake, skew (deg) and NACA 4-digit sections -> closed STL.
- Check the result: KT must match T / (rho n^2 D^4) (the tool reports both), and efficiency must stay under the actuator-disk limit it prints. Lifting-line design says nothing about cavitation, blade strength or the
  final section shape: follow with `propeller_bem` for cavitation number, class rules for thickness, and a CFD or cavitation-tunnel check.
- Use `propeller_bem` when pitch ratio is already known; use `propeller_design` when the thrust is the requirement and the pitch is the answer.
- OpenProp itself is MATLAB (not run here); its pack is for knowledge: input files, theory notes, examples.
