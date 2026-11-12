---
name: stl-stability
description: hydrostatics, GZ curve and intact criteria of any hull STL (NavalToolbox), and slender catamaran demihulls (FAST-SHIPS)
when: stl|hull surface|catamaran|demihull|trim optimi[sz]ed|gz curve of (my|the|this) (stl|hull)|stability of (my|the|this) (stl|hull|model)
---
# STL hulls: stl_stability and catamaran_hull

- `stl_stability`: any hull STL in the workspace (from hull_generate, catamaran_hull or uploaded; metres, x along, y across, z up, keel at z = 0 - use scale for mm) -> hydrostatics at a draft or
  displacement, the GZ curve with the trim optimised at every angle, pass / fail of an intact criteria set (rule = is_code_2008_general by default; is_code_2008_complete, div222_intact_stability) and a picture.
  Ask for the KG (and LCG / TCG if not on the centre line); the draft or the displacement. Say it is a design check: no openings, tanks or approved loading conditions - not class approval.
  Two scripts of the library (hsc_2000_monohull_intact, is_code_2008_passenger) do not compile in its engine: the tool refuses them.
- `catamaran_hull`: slender catamaran demihull from L/B, B/T, Tt/T and the displacement volume or LWL (FAST-SHIPS hull generator), STL of the demihull and, with separation, of the catamaran; then stl_stability on it.
  The IS Code general criteria are written for monohulls: a catamaran's GZ peaks early (it can fail "angle of maximum GZ >= 25 deg" with a very large GZ) - say that, and do not apply them blindly.
- Cross-checked: NavalToolbox on the generated hull equals the hull generator's own hydrostatics (volume, LCB, waterplane) and the own GZ integration within a few percent; on a FAST-SHIPS demihull it reproduces the
  generator's displacement (100.0 m3 at the generator's draft) and length exactly.
