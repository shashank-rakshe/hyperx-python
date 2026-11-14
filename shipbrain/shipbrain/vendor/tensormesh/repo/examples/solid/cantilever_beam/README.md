# Cantilever Beam

Linear elastic deformation of a steel cantilever beam under a tip load.

## Problem Setup

- **Geometry:** 2.0 x 0.2 x 0.2 m beam (3D tetrahedral mesh, chara_length=0.08)
- **Material:** Steel (E=200 GPa, nu=0.3)
- **Boundary Conditions:**
  - Left end (x=0): fully clamped
  - Right end (x=2): distributed downward force F=-100 kN in y-direction
- **Solver:** Direct sparse linear solver via `LinearElasticityElementAssembler` + `Condenser`

## Usage

```bash
python cantilever_beam.py
```

## Output

- `cantilever_steel.png`: static comparison plot (deformed vs undeformed)
- Console: max displacement in mm
