# Rayleigh-Benard Convection

2D natural convection in a heated rectangular cavity driven by buoyancy (Boussinesq approximation).

## Problem Setup

- **Geometry:** Rectangle [0, 2] x [0, 1] (aspect ratio 2:1)
- **Physics:** Boussinesq equations — coupled incompressible Navier-Stokes + heat equation with thermal buoyancy
- **Boundary Conditions:**
  - Velocity: no-slip on all boundaries
  - Temperature: T=1 at bottom, T=0 at top, no-flux on sides
- **Parameters:** Ra (Rayleigh number, configurable), rho=1.0, mu=0.1, kappa=0.1, g=10
- **Stabilization:** PSPG for pressure

## Usage

```bash
python rayleigh_benard.py
```

## Output

- `rayleigh_benard.png`: temperature field and velocity magnitude
