# Lid-Driven Cavity

Steady-state incompressible Navier-Stokes in a cavity with a moving lid,
in 2D (`cavity.py`) and 3D (`cavity_3d.py`). Both scripts share the same
dimension-generic `NavierStokesAssembler`.

## Problem Setup

- **PDE:** steady incompressible Navier-Stokes, $\rho(\mathbf{u}\cdot\nabla)\mathbf{u} = -\nabla p + \mu\,\Delta\mathbf{u}$, $\nabla\cdot\mathbf{u}=0$
- **Geometry:** unit square $[0,1]^2$ (triangular mesh) / unit cube $[0,1]^3$ (tetrahedral mesh)
- **Boundary Conditions:**
  - Top ($y=1$): moving lid, $u_x=1$, other velocity components $0$
  - All other walls/faces: no-slip ($\mathbf{u}=\mathbf{0}$)
  - One node: $p=0$ (pressure pin to fix the constant null space)
- **Parameters:** Re=100 (default), $\rho=1.0$, $\mu=1/\mathrm{Re}$
- **Discretization:** equal-order P1-P1 velocity/pressure with SUPG/PSPG stabilization
- **Solver:** Picard linearization (previous-iterate velocity `w_prev` carries the convection term)

## Scripts

| Script | Domain | DOF layout | Output |
| --- | --- | --- | --- |
| `cavity.py` | 2D unit square | `[u, v, p]` per node | `cavity_results.png` (speed + pressure) |
| `cavity_3d.py` | 3D unit cube | `[u, v, w, p]` per node | `cavity_3d.vtu` (ParaView) + `cavity_3d.png` (z=0.5 slice) |

The assembler reads the spatial dimension from `gradu.shape[0]` and stamps a
`(dim+1) × (dim+1)` block per node, so the only difference between the two
scripts is the mesh, the per-node DOF count, and the visualization.

## Usage

```bash
python cavity.py        # 2D, writes cavity_results.png
python cavity_3d.py     # 3D, writes cavity_3d.vtu + cavity_3d.png
```

## Output

- `cavity_results.png`: 2D speed magnitude and pressure contour plots
- `cavity_3d.vtu`: full 3D volumetric fields (open in ParaView)
- `cavity_3d.png`: speed + pressure on the $z=0.5$ mid-plane slice (via PyVista)
