---
name: flow-browser-sim
description: FLOW browser simulation platform, FastAPI backend with FEA thermal CFD modal buckling solvers and a Fourier neural operator
when: \bFLOW\b simulation|browser (based )?(fea|simulation)|fourier neural operator|\bFNO\b|fea_classic|fea_v2|neural surrogate for (fea|cfd)
---
# FLOW (Vitalcheffe/flow)

FLOW (MIT; pack `flow`) is a browser engineering-simulation platform: FastAPI + NumPy / SciPy backend (`app/solvers`: 2D truss / beam FEA, modal, linear buckling, thermal, simple CFD, mesh and geometry helpers,
visualisation), a Fourier-neural-operator surrogate (`app/neural`), job API (`docs/API.md`) and a React / Three.js front end.
- The solvers are small 2D teaching-level codes (the buckling geometric stiffness is described by the code itself as simplified): for real work use ShipBrain's own FE (`cad_fea`, `pynite_fea`, CalculiX) and CFD (Elmer, OpenFOAM).
- Worth reading in the pack: the job API design (create simulation, poll status, results), the solver registry, and the FNO training loop as a model for a fast surrogate.
