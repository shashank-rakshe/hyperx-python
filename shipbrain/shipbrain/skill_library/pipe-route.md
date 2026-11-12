---
name: pipe-route
description: pipe routes from plain words - 3D pipe solid with exact bends (STEP), length, rise, bends, mass, and the input for the pressure-drop calculation
when: \b(rout(e|ing)|pipe run|run of pipe|isometric|go(es)? (east|west|north|south|up|down)|then (up|down|east|west|north|south))\b
---
1. Collect: the pipe outside diameter (and wall thickness if the mass matters), the legs in order with direction and length
   (east / west / north / south / up / down, mm - convert metres, feet), where it starts (default the origin), the bend type
   (long radius is the default; short radius if space is tight).
2. pipe_route(od, wall, legs, bend). A leg too short for its bends is refused: say which leg and what it needs, and offer a
   longer leg or a short-radius bend.
3. Answer: centre-line length, net rise, number of bends, bounding box, steel mass, the STEP file.
4. Pressure drop / pump for the route: pipe_flow with the segment pipe_route returned in pipe_flow_input (bore, length_m,
   rise_m, elbow counts), plus the flow and the fluid. Valves, strainers and coolers on the route are added as fittings.
5. Pipe sizes and wall thicknesses required by class: class_rule, not this tool.
