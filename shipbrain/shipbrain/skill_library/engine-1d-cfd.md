---
name: engine-1d-cfd
description: ensim4 combustion engine simulator, one dimensional gas dynamics in intake and exhaust pipes, engine sound
when: ensim4|engine (sim|simulator)|exhaust (pipe|gas|sound)|intake runner|cylinder engine simulat|isentropic flow node
---
# ensim4: engine and exhaust gas dynamics

ensim4 (MIT, Gustav Louw; pack `ensim4`) is a small C23 real-time inline engine test bed: pistons, valves, intake plenum and runners, exhaust runners and plenum, a throttle, injectors and spark plugs, with the gas in the
pipes modelled by isentropic flow equations and one-dimensional CFD between nodes (volumes) that exchange mass, momentum and energy; the pressure waves make the engine sound. It needs SDL3 and runs on the desktop,
not in ShipBrain.
- Use it as knowledge: the node-and-flux layout of a 1D network, nozzle flow between volumes (choked and unchoked), gamma and gas properties, firing order and valve timing in `engine_3_cyl.h` / `engine_8_cyl.h`.
- For a 1D finite-volume solve inside ShipBrain use `fvm_1d`; for a full 3D pipe flow use `elmer_flow` or `openfoam_flow`.
- Ship relevance: diesel engine intake / exhaust pulse tuning, silencer and exhaust-line acoustics, funnel back pressure.
