# Stabilized Nodal Magnetostatic Example

This example solves a three-dimensional magnetostatic problem with the
stabilized nodal Lagrange scheme from Badia and Codina, "A Nodal-based
Finite Element Approximation of the Maxwell Problem Suitable for Singular
Solutions", SIAM Journal on Numerical Analysis, 2012.

The physical setup is a smooth vertical current channel passing through the
middle of the unit cube. This makes the expected magnetic response easy to
recognize: away from the boundary, the magnetic field should mainly circle
around the current line.

## Magnetostatic Model

In magnetostatics, Ampere's law is

$$
\nabla\times\mathbf H=\mathbf J,
$$

with

$$
\nabla\cdot\mathbf B=0,
\qquad
\mathbf B=\mu\mathbf H.
$$

The code solves the equivalent magnetic vector potential formulation. Let

$$
\mathbf B=\nabla\times\mathbf A,
\qquad
\mathbf H=\nu\mathbf B,
$$

where \(\nu=1/\mu\) is the reluctivity. In this compact demo, the constant
coefficient is absorbed into the nondimensional scaling, so Ampere's law
becomes

$$
\nabla\times(\nabla\times\mathbf A)=\mathbf J.
$$

The scalar unknown \(p\) is a Lagrange multiplier used to impose the Coulomb
gauge condition

$$
\nabla\cdot\mathbf A=0.
$$

Thus the example solves

$$
\nabla\times(\nabla\times\mathbf A)-\nabla p=\mathbf J
\quad \text{in } \Omega,
$$

$$
\nabla\cdot\mathbf A=0
\quad \text{in } \Omega.
$$

After solving for \(\mathbf A\), the exported magnetic field is
\(\operatorname{curl}\mathbf A=\nabla\times\mathbf A\).

## Geometry and Boundary Conditions

The domain is the unit cube:

$$
\Omega=(0,1)^3.
$$

The code applies the homogeneous tangential vector-potential condition

$$
\mathbf n\times\mathbf A=0,
\qquad
p=0
\quad \text{on } \partial\Omega.
$$

On the axis-aligned cube, this means the two tangential components are fixed
on each face. For example, on \(x=0\) and \(x=1\), the constrained components
are \(A_y\) and \(A_z\). On edges and corners, the constraints from the
adjacent faces are combined.

## Current Source

The source is a smooth approximation of a straight current channel in the
\(z\)-direction. Let

$$
\rho=\sqrt{(x-x_c)^2+(y-y_c)^2}.
$$

The current density is

$$
\mathbf J(x,y,z)
=
J_0
\exp\!\left(
-\frac{\rho^2}{2\sigma^2}
\right)
\begin{pmatrix}
0\\
0\\
1
\end{pmatrix}.
$$

The current is independent of \(z\), so
\(\nabla\cdot\mathbf J=\partial J_z/\partial z=0\). In free space, such a
current would create an azimuthal magnetic field,

$$
\mathbf H \approx H_\theta\,\mathbf e_\theta,
\qquad
\mathbf e_\theta=
\begin{pmatrix}
-(y-y_c)/\rho\\
(x-x_c)/\rho\\
0
\end{pmatrix},
$$

which is exactly the qualitative behavior this example is meant to make
visible. The finite cube boundary perturbs the ideal circular pattern.

## Discrete Scheme

The script implements the stabilized curl formulation, equation (3.6) in the
paper, using continuous Lagrange finite elements for both unknowns. Find
\((\mathbf A_h,p_h)\in V_h\times Q_h\) such that

$$
a(\mathbf A_h,\mathbf v_h)
+ b(\mathbf v_h,p_h)
+ s_u(\mathbf A_h,\mathbf v_h)
= (\mathbf J,\mathbf v_h)
\qquad \forall \mathbf v_h\in V_h,
$$

$$
-b(\mathbf A_h,q_h) + s_p(p_h,q_h) = 0
\qquad \forall q_h\in Q_h.
$$

The forms are

$$
a(\mathbf A,\mathbf v)
= (\operatorname{curl}\mathbf A,\operatorname{curl}\mathbf v)_\Omega,
$$

$$
b(\mathbf v,p)
= -(\nabla p,\mathbf v)_\Omega,
$$

$$
s_u(\mathbf A,\mathbf v)
= \sum_{K\in\mathcal T_h}
h^2
(\nabla\cdot\mathbf A,\nabla\cdot\mathbf v)_K,
$$

$$
s_p(p,q)
= (\nabla p,\nabla q)_\Omega.
$$

For simplicity, this demo uses a constant stabilization length
\(h^2=\texttt{chara\_length}^2\) for every element.

## Run

```bash
python examples/maxwell/magnetostatic.py
```

To experiment with the mesh size or current source, edit the simple settings
near the top of `main()` in `magnetostatic.py`.

## Output

The script prints the mesh size, the \(L^2\) norm of \(\mathbf A\), the
\(L^2\) norm of \(\operatorname{curl}\mathbf A\), and the maximum nodal
magnitude of \(\operatorname{curl}\mathbf A\). It also writes:

```text
examples/maxwell/magnetostatic_3d.vtu
```

Open the VTU file in ParaView to inspect the two exported point fields:
`A` and `curl_A`.
