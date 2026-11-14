---
name: piping-model
description: piping or pipe skid model - find pipes and elbows, make a 1D pipe model, check it
when: \b(pip(e|es|ing)|elbow|spool|skid)\b
---
1. pipe_extract(file, schedule=<SCH40 unless they say>) - pipes, elbows, runs, 1D pipe beam model (.bdf / .inp).
2. Say the sizes found, the total length and how many separate runs there are; many runs = flanges / valves break them.
3. If they want stresses: analysis_run(<piping .inp>, "static") after supports and loads are given (ask for them if missing).
4. Thin plate parts of the same model (skid frame, base plate): surface_extract(file, kind="mid").
