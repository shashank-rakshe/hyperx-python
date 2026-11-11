---
name: mooring
description: mooring lines, anchor chains, catenary, fairlead tension, touchdown, power cables and risers - CableDyn
when: \b(moor\w*|anchor (line|chain)|catenary|fairlead|touch ?down|chain (size|grade)|R3S?|R4S?|R5|power cable|umbilical|lazy.?wave|bend stiffener)\b
---
1. A single chain line from numbers: mooring(depth, length, radius, d_mm, grade, kind, fairlead_z, current, condition).
   radius = horizontal distance fairlead -> anchor. Ask for any of depth / length / radius / chain size the user did
   not give (or say the value you assume).
2. A full model (several lines, buoys, clumps, fibre / wire, power cable, lazy wave, bend stiffener, waves, vessel
   motion): write or take a CableDyn / MoorDyn v2 deck and cable_run(deck).
3. Answer: fairlead tension and angle, anchor tension (an anchor must not be lifted: grounded length > 0), touchdown,
   breaking load and the API RP 2SK utilisation (intact 2.0 quasi-static / 1.67 dynamic; damaged 1.43 / 1.25). Say it
   is the static result; the design tension needs the dynamics with waves and vessel motion.
4. Chain properties used: studless mass 19.9 d^2 t/m, EA 0.854e8 d^2 kN (d in m), hydrodynamic diameter 1.8 d,
   MBL = c d^2 (44 - 0.08 d) kN (d in mm; c = 0.0223 R3, 0.0249 R3S, 0.0274 R4, 0.0304 R4S, 0.0320 R5).
