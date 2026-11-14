---
name: pipe-hydraulics
description: ship piping hydraulics - pressure drop, head, pump power, pipe velocity for seawater cooling, ballast, bilge, fire main, fuel and lube oil lines
when: \b(pressure drop|head loss|pump (head|power|siz\w*)|pipe siz\w*|hydraulic|ballast|bilge|cooling water|fire main|fuel (oil )?(line|transfer)|lube oil|velocity in (the )?pipe)\b
---
1. Collect: flow (m3/h), the route as series segments (inner diameter mm, length m, rise m, valves / bends per segment),
   parallel branches if any, fluid (seawater, fresh water, MGO, HFO, lube oil, hydraulic oil - or density + viscosity
   in cSt at the operating temperature; fuel oil viscosity changes a lot with temperature). Ask or state assumptions.
2. pipe_flow(flow_m3h, segments, fluid, branches, pump_efficiency).
3. Answer: pressure drop (bar), head (m), the velocity in each pipe, laminar or turbulent, pump power (hydraulic and
   shaft). Say what it does not include: pump curve, strainers / coolers / heat exchangers unless given as fittings,
   fouling margin, two-phase or cavitation (check NPSH separately), transients (water hammer).
4. Pipe sizes from class rules (e.g. bilge main diameter) come from class_rule, not from this tool.
