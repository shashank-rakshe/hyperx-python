---
name: propeller-analysis
description: propeller open-water analysis: KT KQ eta curves, operating point, cavitation number, momentum theory limit
when: open.water (curve|diagram|efficiency)|(KT|KQ) (curve|and)|advance ratio|cavitation number|bollard pull|actuator disk|propeller (efficiency|thrust|torque)
---
# Propeller analysis (propeller_bem)

- Read the curve first: KT falls with J and reaches zero at the hydrodynamic pitch (J near P/D for a flat section); the efficiency peaks at a J a little below that. Compare the operating J with the J of best efficiency.
- Operating point: thrust, torque, power from KT and KQ at the J of the ship speed and rpm; the actuator-disk (momentum) efficiency eta_i = 2 / (1 + sqrt(1 + CT)) is the upper limit - if the computed efficiency is
  near it, something is wrong; a lightly loaded large propeller gets closer to it.
- Cavitation: the cavitation number at 0.7R, sigma = (p_atm + rho g h - p_v) / (0.5 rho (V^2 + (0.7 pi n D)^2)), is reported; low values (below about 0.5) and high thrust loading mean cavitation is likely - the
  decision needs the cavitation chart of the class or a tunnel test, not this tool.
- Checked: zero thrust at J = P/D for non-lifting sections, efficiency under the momentum limit, monotonic KT and KQ, convergence with the number of elements. Not checked against a real propeller: the efficiency is
  optimistic by about 10 %; do not use it for a guarantee.
