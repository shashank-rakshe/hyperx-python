# Hyperelastic Beam (Neo-Hookean)

Large deformation of a rubber beam under torsion using a compressible Neo-Hookean material model.

## Problem Setup

- **Geometry:** 1.0 x 0.4 x 0.4 m beam (quadratic tetrahedra, order=2)
- **Material:** Rubber (E=10 MPa, nu=0.48, near-incompressible)
  - Strain energy: Psi = mu/2 (I1 - 3) - mu ln(J) + lam/2 (ln J)^2
- **Boundary Conditions:**
  - Left end (x=0): fully clamped
  - Right end (x=1): torsional Neumann traction t = C*(0, -dz, dy), C=2.4e7,
    integrated over the end facets with `FacetAssembler` (∫_Γ N_i t dA) to get
    a consistent nodal load. Applying the field as a per-node force instead
    over-loads the corner nodes and makes them distort excessively.
- **Solver:** LBFGS energy minimization with 10 load steps (ramped torsion)

## Usage

```bash
python hyperelastic_beam.py
```

## Output

- `hyperelastic_rubber.png`: deformed configuration (isometric view)
- Console: max displacement per load step
