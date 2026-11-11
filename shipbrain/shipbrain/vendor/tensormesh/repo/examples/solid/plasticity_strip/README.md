# 2D Plasticity Strip (J2 with Isotropic Hardening)

Plane-strain elasto-plastic deformation of a steel strip under tension and unloading.

## Problem Setup

- **Geometry:** 1.0 x 0.2 m strip (2D plane strain, chara_length=0.02)
- **Material:** Steel
  - E=200 GPa, nu=0.3
  - Yield stress sigma_y=250 MPa
  - Hardening modulus H=1 GPa
- **Boundary Conditions:**
  - Left edge (x=0): roller (u_x=0)
  - Corner pin (x=0, y=0): fully fixed
  - Right edge (x=1): prescribed displacement u_x up to 0.10 m (10% strain)
- **Loading:** 10 loading steps + 10 unloading steps (20 total)
- **State Variables:** plastic strain tensor, equivalent plastic strain
- **Solver:** LBFGS per load step with history variable tracking

## Usage

```bash
python plasticity_strip.py
```

## Output

- `plasticity_strip.mp4`: animation of deformed mesh + plastic strain field + force-displacement curve
- Console: per-step force, displacement, max plastic strain
