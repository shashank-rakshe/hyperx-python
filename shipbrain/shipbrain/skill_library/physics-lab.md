---
name: physics-lab
description: flow / CFD, heat, fire, water and sloshing, sound, radar, magnetics, fracture, impact, gears, 3D printing - run a physics simulation
when: \b(cfd|flow|wake|airfoil|wing|drag|shock|supersonic|hypersonic|slosh\w*|dam break|wave|heat|thermal|temperature|fire|sound|acoustic|noise|radar|magnet\w*|motor|fracture|crack|impact|crash|gear\w*|3d print\w*|topology optimi[sz]\w*)\b
---
1. physics_lab(action="list", query=<the physics, e.g. "slosh", "heat", "gear">) - the checked example scenarios.
2. physics_lab(action="get", scenario=<closest example>) - read it: every number carries its unit in its key (length_m, pressure_pa).
3. physics_lab(action="run", scenario=<name>, changes={...the user's values in the same keys...}) - OpenPhysicsAI's own solver.
4. Answer with the main results and units, and how far the solver is trusted (its validation page in the knowledge).
5. Geometry / meshing / structural / topology-optimisation operations: mcp_tools(server="openphysics", query=...) then mcp_call.
   Big 3D flow cases can take many minutes on a CPU: say so before running them.
