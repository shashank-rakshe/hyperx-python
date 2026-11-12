---
name: pipe-stress
description: pipe flexibility analysis to ASME B31.1 with psi - sustained and expansion code checks, support and anchor loads, movements
when: pipe stress|piping stress|b31\.?[13]|thermal expansion of (the |a |my )?pip|expansion loop|anchor (load|force)s?
---
# Pipe stress analysis (pipe_stress)

For "pipe stress", "B31.1 check", "thermal expansion", "do I need an expansion loop", "anchor / support loads", call `pipe_stress`.
It runs psi (Pipe Stress Infinity, GPL, copied in vendor/psi) and returns the ASME B31.1 code check:
- SUS (weight + water + pressure) against Sh, EXP (operating minus sustained) against the allowable range SA, support and anchor loads,
  movements. Units in and out: mm, deg C, bar, kN, kNm, MPa.

Turn the user's words into arguments: route as legs (east / west / north / south / up / down + length mm) or waypoints, or reuse the waypoints
and od from a pipe_route result; pipe size as nps (inch) + schedule, or od_mm of a standard pipe; operating temperature, installation
temperature (default 21 deg C), pressure (bar), water filled or empty; supports: anchors (default both ends), rests (one-way vertical), guides,
or rest_spacing_m for rests every so many metres on horizontal legs. Ask for missing size, route or temperature.

If the expansion check fails: suggest an expansion loop or offset (more pipe perpendicular to the growth), moving an anchor, or guides that let
the pipe grow, then run again. If the sustained check fails: more supports (smaller rest spacing).
Always state psi's limits: corners are sharp joints (bends are not yet implemented in psi - real elbows are more flexible and have a stress
intensification factor), one material (A53 grade A), B31.1-1967 only. Use it for early sizing; confirm a final design with a full pipe stress program.
Checked: weight and fully restrained thermal force exactly against hand formulas; an L-bend within 1.3 % of an independent frame model.
