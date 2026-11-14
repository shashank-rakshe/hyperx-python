---
name: gz-curve
description: GZ curve and IMO intact-stability criteria of a generated hull at a KG and displacement
when: \bGZ\b|righting (lever|arm)|stability (curve|criteria)|imo (intact|stability)|IS code|angle of (vanishing|maximum)|area under (the )?GZ|capsiz
---
# GZ curve and intact criteria (gz_curve)

For "GZ curve", "does it meet the IMO intact criteria", "will it capsize", "angle of vanishing stability": call `gz_curve` with the hull parameters (as hull_generate: L, B, D, T, bilge,
plan form ...), the KG, and the displacement (mass_t) or the draft. Optional: free_surface_m (the free-surface loss GG' of slack tanks, from the tanks' free-surface moments / displacement) and
flooding_angle_deg (the angle at which openings go under water).
- It integrates the heeled hull at the same displacement (level keel, hull up to the deck) and gives GZ every 2.5 degrees, the six criteria of IS Code 2.2 (areas 0-30, 0-40, 30-40 degrees, GZ at
  30 degrees, angle of maximum GZ, GM) with pass / fail, the deck-edge immersion angle and a picture.
- Without a flooding angle the deck-edge immersion angle is used: low freeboard fails early - say that, it is physics of the hull model (a real ship has its own down-flooding angle).
- Checked: a barge follows the wall-sided formula GZ = sin(phi) (GM + 1/2 BM tan^2(phi)) within 3 %; displacement is kept at every angle.
- Not covered: trim, damage stability, the weather criterion, grain, tanks beyond the free-surface loss, approved loading conditions - class approval needs the approved stability program.
