# Flow Past Multiple Obstacles

Steady-state 2D flow past six circular obstacles in a channel.

## Problem Setup

- **Geometry:** Channel [0, 3] x [0, 1] with 6 circular obstacles at various positions
- **Physics:** Steady incompressible Navier-Stokes, Picard linearization
- **Boundary Conditions:**
  - Inlet (x=0): parabolic velocity profile
  - Walls + obstacles: no-slip
  - Outlet (x=3): pressure=0
- **Parameters:** Re=150 (default), rho=1.0
- **Mesh:** Auto-generated via `MeshGen` with obstacle removal
- **Stabilization:** SUPG/PSPG

## Usage

```bash
python flow_obstacles.py
```

## Output

- `flow_obstacles.png`: speed and pressure contour plots
