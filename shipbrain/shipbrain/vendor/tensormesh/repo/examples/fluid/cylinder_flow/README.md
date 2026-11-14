# Cylinder Flow (Vortex Shedding)

Transient 2D flow past a circular cylinder in a channel, demonstrating vortex shedding (von Karman vortex street). Based on the DFG benchmark setup.

## Problem Setup

- **Geometry:** Channel [0, 2.2] x [0, 0.41] with cylinder at (0.2, 0.2), radius 0.05
- **Physics:** Transient incompressible Navier-Stokes, implicit Euler time integration
- **Boundary Conditions:**
  - Inlet (x=0): parabolic velocity profile
  - Walls + cylinder: no-slip
  - Outlet (x=2.2): do-nothing with pressure pin
- **Parameters:** Re=100, rho=1.0, D=0.1 (cylinder diameter)
- **Stabilization:** SUPG/PSPG with adaptive tau
- **Post-processing:** Vorticity field via L2 projection

## Usage

```bash
python cylinder_flow.py
```

## Utilities

- `render_video.py`: generates MP4 from VTU frame sequence (requires PyVista + ffmpeg)

## Output

- Frame sequence (PNG) saved every N steps
- `cylinder_flow_final.png`: final vorticity/speed/pressure snapshot
