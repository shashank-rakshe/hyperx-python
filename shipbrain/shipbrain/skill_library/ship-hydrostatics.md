---
name: ship-hydrostatics
description: draft, trim, KB, BM, GM and hydrostatic tables of a hull and its loading (Vessel.js)
when: hydrostatic|metacentr|\bGM\b|\bKB\b|freeboard|draft (of|at|for)|vessel\.?js|loading condition|will (it|the (ship|barge|vessel)) (float|capsize)
---
# Hydrostatics and initial stability (ship_hydrostatics)

For "what draft / GM / KB / BM does this hull have", "will it float or capsize", a hydrostatic table, or a Vessel.js ship specification file, call `ship_hydrostatics`
(Vessel.js, MIT, runs in Node.js - if Node is missing the tool says so; the install is https://nodejs.org).
- Hull: box (barge, pontoon), wigley (a smooth test hull), or a Vessel.js JSON the user uploaded (spec_file; its own weights and tanks are used).
- Weights: every item as mass in tonnes and centre of gravity [x from the aft end, y to port, z above the keel] in metres: lightship, cargo, ballast, fuel. Ask for what is missing; do not
  invent a KG. Fresh water: density 1000.
- Plain words: draft = how deep it floats; KB = height of the centre of buoyancy; BM = metacentric radius; GM = KB + BM - KG; GM below 0 = it capsizes; the usual minimum for initial stability is 0.15 m.
- Limits, say them: small-angle stability only (no GZ curve, no free-surface correction of tanks, no damage stability), upright hull forms from a table or box / Wigley; a real ship's lines must be
  given as a half-breadth table or a Vessel.js specification. Class intact-stability criteria need the full curve and the rules' loading conditions.
