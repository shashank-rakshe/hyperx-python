# Hertzian Contact

2D contact mechanics between a circular indenter and an elastic block using the penalty method.

## Problem Setup

- **Geometry (2D):**
  - Indenter: circular disc (radius=1.0), Tri6 elements
  - Block: rectangle (1.0 x 2.0), Quad9 elements
  - Contact interface at x=0
- **Material:** Linear elastic, E=1000 Pa, nu=0.3
- **Boundary Conditions:**
  - Circle: left side (x<-1.8) clamped
  - Block: right boundary (x=1.0) prescribed displacement u_x=-0.15 (pushing left)
- **Contact:** Penalty method (penalty=2e6), two-way point-to-segment detection
- **Solver:** LBFGS energy minimization (25 iterations)

## Usage

```bash
python hertzian_contact.py
```

## Output

- `hertzian_contact.png`: Von Mises stress contours with BC visualization
- Console: contact pressure distribution, max displacement
