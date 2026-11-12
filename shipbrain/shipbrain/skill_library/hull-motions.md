---
name: hull-motions
description: roll, heave and pitch natural periods and a regular-wave response of a generated hull, teaching estimates
when: roll period|natural (roll|heave|pitch) period|(roll|heave|pitch)ing? (period|response|amplitude)|ship motions? in (waves|a wave)|\bRAO\b|resonan
---
# Hull motions (hull_motions)

Natural periods of a generated hull at a KG: roll (IMO IS Code formula T = 2 C B / sqrt(GM), and the 0.4 B radius-of-gyration form), heave (hydrostatic stiffness over mass plus the semi-circle added mass) and pitch;
with wave_period_s also the one-degree-of-freedom response: heave in head waves (with the e^{-kT} Smith reduction) and roll in beam waves, damping ratios as inputs (defaults heave 0.2, roll 0.07, bare hull).
- Say what it is: closed-form teaching estimates with stated assumptions, no strip theory, no forward speed, not checked against model tests; heave and pitch periods are good to about 20 %.
- A roll period shorter than about 8 s for a ship means a stiff ship (high GM, uncomfortable); long means tender (low GM): link it to the GM from ship_hydrostatics / gz_curve.
- Near resonance the answer is governed by the damping assumed: say so and ask for a damping value (bilge keels raise the roll damping).
- Not covered: forward speed, irregular seas and sea states, motion sickness, wave bending moment, multihulls. A real seakeeping study needs a strip-theory or panel-method program.
