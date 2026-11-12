---
name: global-hull-fea-analysis
description: analysing a global hull girder FE model: load cases, checks, stress read-out, what to compare with
when: global (hull|ship) (stress|result)|hull girder (stress|bending|check)|vertical bending moment|midship section modulus
---
# Global hull girder FE - analysis

- Load cases of the classical study: vertical bending (hogging and sagging), horizontal bending, shear force, torsion (and combinations); one run each, then combine by superposition with the rule factors.
- Check first: reactions are ~zero (equilibrium), the deflection of the hull girder follows beam theory (delta ~ M L^2 / (8 E I) of the midship section for a uniform moment), the neutral axis of the model equals
  that of the midship section: bending stress sigma = M z / I at the deck and keel is the hand check (see section_props / the midship section tools).
- Read von Mises (and the longitudinal stress for the bending cases) in the midship region away from the end load introduction (St Venant: about one beam depth), shear in the side shell and longitudinal bulkheads.
- Compare with the allowable of the class rule (private) or the yield with the stated safety factor; a hot spot over a small area needs a refined local model, not a conclusion from the coarse global mesh.
- Say plainly what the model leaves out: local pressure, buckling (use plate_buckling / the panel checks), fatigue.
