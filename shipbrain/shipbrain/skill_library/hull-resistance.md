---
name: hull-resistance
description: calm-water resistance and effective power of a hull at knots / Froude numbers (Holtrop-Mennen), with a trained surrogate
when: resistance of (the |a |my )?(hull|ship|vessel)|(ship|hull) resistance|effective power|holtrop|propulsion power|power (needed|required) (at|for)
---
# Hull resistance (hull_resistance)

Calm-water resistance Rt and effective power Pe = Rt x V of a hull given as hull_generate parameters, at speeds in knots or Froude numbers. Default method holtrop (Holtrop-Mennen through Vessel.js,
exact and fast); method surrogate answers from a model trained on 2,400 generated hulls (about 2 % mean error against Holtrop on hulls it had not seen, worst about 15 %).
- Holtrop holds for ordinary displacement ships only: 0.55 <= Cp <= 0.85, 3.9 <= L/B <= 14.9, 2.1 <= B/T <= 4.0, Fn <= 0.45. Outside that the tool refuses - say so, do not extrapolate.
- It is an estimate (roughly +-10-20 % against real ships), bare hull, calm water: shaft power needs the propulsive efficiency, and wind, waves, fouling and appendages add to it.
- The data does not make it "automatically accurate": the surrogate only reproduces the Holtrop labels; the exact Holtrop is as fast to run, so use it for answers and the surrogate for large sweeps.
- A flow (CFD) run on the hull surface (openfoam_flow with the STL) is the way to get beyond Holtrop; say it is slower and checked only on plates.
