# Taylor-Green Vortex (Convergence Study)

2D decaying Taylor-Green vortex — a transient benchmark with an exact analytical solution, used to verify spatial and temporal convergence of the Navier-Stokes solver.

## Problem Setup

- **Geometry:** Periodic domain [0, 2pi]^2
- **Physics:** Transient incompressible Navier-Stokes, implicit Euler
- **Exact Solution:**
  - u = -cos(x) sin(y) exp(-2 nu t)
  - v =  sin(x) cos(y) exp(-2 nu t)
  - p = -(cos(2x) + cos(2y)) exp(-4 nu t) / 4
- **Boundary Conditions:** Dirichlet velocity set to exact solution
- **Parameters:** nu=0.01 (default), configurable mesh sizes for h-convergence study
- **Stabilization:** SUPG/PSPG with adaptive tau

## Usage

```bash
python taylor_green.py
```

## Output

- Convergence table (L2 errors, convergence rates) printed to console
- `taylor_green_convergence.png`: log-log error vs mesh size
- `taylor_green_results.png`: speed, pressure, velocity error fields
- `taylor_green.mp4` (optional): time evolution animation
