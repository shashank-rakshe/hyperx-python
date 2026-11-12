---
name: hull-generator
description: design a ship hull from parameters (block coefficient, bulb, V-ends), get coefficients, STL, picture, GM; random hull datasets
when: hull (form|shape|design)|design (a |the )?hull|parametric hull|block coefficient|\bCb\b|bulb(ous)?|hull dataset|ship-?d\b|prismatic coefficient|waterplane coefficient
---
# Hull generator (hull_generate)

ShipBrain's own parametric hull generator (written from scratch: the Ship-D code has no licence and is not used). Lengths in metres, angles in degrees:
- principal L, B, D, T; midship r_bilge, deadrise, flare; plan form ent, run (fractions of L), n_ent, n_run (fullness, 1 = straight .. 8 = full shoulders), transom (0 = pointed stern);
  vee (V-shaped ends, lowers Cb); bulb_len, bulb_b, bulb_h, bulb_z (all 0 = no bulb).
- `target_cb` solves the fullness (and the V-shape) for a block coefficient; if the plan form cannot reach it the answer says what range it can (longer ends, smaller transom ...).
- Result: Cb, Cp, Cm, Cwp, LCB, KB, wetted area, section area curve; a watertight STL (hull and bulb as two closed shells), a picture; with `kg` also GM and draft through Vessel.js.
- `samples` = N writes N random valid hulls with their coefficients as a CSV (a hull dataset to look through or learn from).
Say what it is: similar-section lofting of a midship section with tapered ends - good for concept studies and sensitivity (what does the bulb or a longer entrance do to Cb, KB, GM), not a fair
ship's lines plan. STL of a hull can go to openfoam_flow as a body (metres).
