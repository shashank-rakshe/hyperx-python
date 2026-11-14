# 3D Plasticity (J2 with Isotropic Hardening)

Elasto-plastic deformation of a steel cube under tension and unloading, using J2 flow theory with linear isotropic hardening.

## Problem Setup

- **Geometry:** 0.5 x 0.5 x 0.5 m cube (3D tetrahedral mesh, chara_length=0.04)
- **Material:** Steel
  - E=200 GPa, nu=0.3
  - Yield stress sigma_y=250 MPa
  - Hardening modulus H=1 GPa
- **Boundary Conditions:**
  - Left face (x=0): roller (u_x=0)
  - Corner pin (x=0, y=0, z=0): fully fixed
  - Right face (x=0.5): prescribed displacement u_x up to 0.20 m (40% strain)
- **Loading:** 50 loading steps + 50 unloading steps (100 total)
- **State Variables:** plastic strain tensor, equivalent plastic strain (alpha)
- **Solver:** LBFGS per load step with history variable tracking

## Usage

```bash
python plasticity_3d.py
```

## Output

- `plasticity_3d.mp4`: animation of deformed mesh + Von Mises stress + force-displacement curve
- Console: per-step force, displacement, max Von Mises stress
