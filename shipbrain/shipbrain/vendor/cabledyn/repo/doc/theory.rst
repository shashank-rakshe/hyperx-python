.. SPDX-License-Identifier: Apache-2.0

Theory
======

This chapter states the equations CableDyn solves: the kinematics and the two line
elements, the constitutive laws, the hydrodynamic and seabed loads, the static and dynamic
solution procedures, and the models for attached objects. Units, frames, sign rules, and the
tension definition are fixed in :doc:`conventions` and are not repeated here. The
element-level implementation of each path, and the secondary Cosserat path, are described in
:doc:`solver_paths`.

Symbols are defined in the section that uses them. A few letters are reused: :math:`\beta` is the
wave direction, the Syrope fast-stiffness slope, a Newmark parameter, and an eigenvalue
parameter of the sagging-cable modes; :math:`T` is a tension and, in the wave formulas, a
period.

.. contents:: On this page
   :local:
   :depth: 2

Kinematics and discretisation
-----------------------------

A line is a curve :math:`\mathbf{r}(s, t) \in \mathbb{R}^3`, parametrised by the unstretched
arc length :math:`s \in [0, L]`. It is built from sections joined end to end; each section is
meshed into two-node elements of unstretched length :math:`L_0`, with the local coordinate
:math:`\xi = (s - s_e)/L_0 \in [0, 1]` on element :math:`e`. The axial strain and the
centreline curvature are the exact large-deformation measures

.. math::

   \varepsilon = \lvert \mathbf{r}' \rvert - 1, \qquad
   \kappa = \frac{\lvert \mathbf{r}' \times \mathbf{r}'' \rvert}{\lvert \mathbf{r}' \rvert^{3}},
   \qquad (\cdot)' = \partial(\cdot)/\partial s .

Neither measure is linearised, so both elements are geometrically exact for arbitrary
displacement and rotation. Which element a section uses is set by the bending stiffness of
its line type: ``EI = 0`` selects the tension element, ``EI > 0`` the bending element.

The EI = 0 tension element
~~~~~~~~~~~~~~~~~~~~~~~~~~

Each node carries its position only (three degrees of freedom). For nodal positions
:math:`\mathbf{r}_a, \mathbf{r}_b`,

.. math::

   \boldsymbol{\delta} = \mathbf{r}_b - \mathbf{r}_a, \quad
   \ell = \lvert\boldsymbol{\delta}\rvert, \quad
   \mathbf{t} = \boldsymbol{\delta}/\ell, \quad
   \varepsilon = \ell/L_0 - 1, \quad
   T = EA\,\varepsilon .

The internal force and its exact tangent (material plus geometric stiffness) are

.. math::

   \mathbf{f}_\text{int} = \begin{bmatrix} -T\,\mathbf{t} \\ +T\,\mathbf{t} \end{bmatrix},
   \qquad
   \mathbf{K}_t = \begin{bmatrix} \mathbf{B} & -\mathbf{B} \\ -\mathbf{B} & \mathbf{B} \end{bmatrix},
   \qquad
   \mathbf{B} = \frac{EA}{L_0}\,\mathbf{t}\mathbf{t}^{\mathsf T}
              + \frac{T}{\ell}\left(\mathbf{I} - \mathbf{t}\mathbf{t}^{\mathsf T}\right).

In **tension-only** mode an element with :math:`\varepsilon < 0` carries zero elastic force and
zero material stiffness, so force and tangent remain consistent. The deck and coupled routes
march the dynamics tension-only: a slack chain or rope exerts no elastic force. Axial damping
(``BA``, below) stays active on a slack element, as in MoorDyn, so a slack element with
:math:`BA \ne 0` can carry a damping force while it stretches or shortens. The static initial
condition is the tension-only equilibrium of the same law (see
:ref:`static-ei0`). The consistent mass of an element is

.. math::

   \mathbf{M}_e = \frac{\rho_A L_0}{6}
   \begin{bmatrix} 2\mathbf{I} & \mathbf{I} \\ \mathbf{I} & 2\mathbf{I} \end{bmatrix},

with :math:`\rho_A` the dry mass per unstretched metre.

The cubic-Hermite bending element
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Each node carries its position and a material tangent, :math:`[\mathbf{r},\ \mathbf{m}]`
with :math:`\mathbf{m} = \mathbf{r}'`, so an element has 12 degrees of freedom and no rotation
variables. The centreline is the cubic-Hermite interpolant

.. math::

   \mathbf{r}(\xi) = H_1(\xi)\,\mathbf{r}_1 + H_2(\xi)\,\mathbf{m}_1
                   + H_3(\xi)\,\mathbf{r}_2 + H_4(\xi)\,\mathbf{m}_2,

   H_1 = 1 - 3\xi^2 + 2\xi^3,\quad H_2 = L_0(\xi - 2\xi^2 + \xi^3),\quad
   H_3 = 3\xi^2 - 2\xi^3,\quad H_4 = L_0(\xi^3 - \xi^2),

which is :math:`C^1` across nodes, so curvature is defined pointwise inside every element.
The magnitude :math:`\lvert\mathbf{m}\rvert = 1 + \varepsilon` carries the axial stretch at a
node; only its direction is a bending quantity. The element stores the axial-plus-bending
strain energy

.. math::

   U_e = \int_0^{L_0} \left( \tfrac{1}{2} EA\,\varepsilon^2 + \tfrac{1}{2} EI\,\kappa^2 \right)
         \mathrm{d}s ,
   \qquad
   \kappa^2 = \frac{\lvert \mathbf{a} \times \mathbf{b} \rvert^2}{\lvert\mathbf{a}\rvert^6},
   \quad \mathbf{a} = \mathbf{r}',\ \mathbf{b} = \mathbf{r}'' .

Using :math:`\kappa^2` directly, rather than :math:`\kappa`, keeps the energy smooth through
the straight state. The stress-free reference is straight, and the bending moment is
:math:`M = EI\,\kappa`; the node outputs recover it from nodal equilibrium
(:ref:`theory-output-recovery`).

At each Gauss point, :math:`\mathbf{a}` and :math:`\mathbf{b}` are fixed linear maps of the
12 element DOFs. The gradient and Hessian of the energy density with respect to
:math:`(\mathbf{a}, \mathbf{b})` are written in closed form and chained to the DOFs, giving
:math:`\mathbf{f}_\text{int} = \partial U/\partial \mathbf{q}` and the symmetric tangent
:math:`\mathbf{K}_t = \partial^2 U/\partial \mathbf{q}^2` exactly. Automatic differentiation of
the same energy is used only in the test suite, as an independent check of the closed form,
together with finite differences of :math:`\mathbf{f}_\text{int}`.

**Quadrature.** Axial and bending energies use Gauss–Legendre integration, four points each by
default. The two orders are independently selectable from 1 to 6 (options
``axial_quadrature_order`` and ``bending_quadrature_order``); unequal orders give a selective
integration. The consistent mass
:math:`\mathbf{M}_e = \rho_A \int_0^{L_0} \mathbf{N}^{\mathsf T}\mathbf{N}\,\mathrm{d}s` uses the same
Hermite shapes and a four-point rule, which is exact for the degree-6 integrand; it is
block-diagonal per Cartesian component. Distributed hydrodynamic loads use three-point Gauss
integration.

**Curvature recovery.** Curvature outputs are evaluated from the interpolated centreline, not
only at nodes or Gauss points. The peak curvature of an element is located by sampling 16
equal intervals and bisecting each at least five and at most twelve times, continuing where the
curvature departs from linear variation by more than 5 % of the local maximum. The same search
locates the extreme axial resultant :math:`N = EA(\lvert\mathbf{r}'\rvert - 1)` inside every
element, with a 2 % criterion relative to the largest local magnitude (at least 1 N).

The element follows the geometrically exact Kirchhoff-rod formulation of
:ref:`Boyer et al. (2011) <ref-boyer2011>` with the :math:`C^1` Hermite centreline
interpolation of :ref:`Meier, Popp & Wall (2015) <ref-meier2015>`, reduced to a torsion-free
cable. Torsion enters through the condensed line term of the statics and the nodal twist of the
dynamics below.

.. _theory-bend-stiffeners:

Bend stiffeners
~~~~~~~~~~~~~~~

A bend stiffener (``STIFFENERS``) is a sleeve of outer diameter :math:`D(s)`, bore :math:`d_i`,
modulus :math:`E_s` and density :math:`\rho_s` over a line end, made of conical segments in
which :math:`D` varies linearly with the arc length. Cable and sleeve bend together, as in the
stiffener design model of :ref:`Boef & Out (1990) <ref-boef1990>`, so over the stiffener

.. math::

   EI(s) = EI_c + E_s \frac{\pi}{64}\left(D(s)^4 - d_i^4\right),

with :math:`EI_c` the cable's bending stiffness. The sleeve carries no axial load and no torque
(:math:`EA` and :math:`GJ` are the cable's), and its material is linear elastic. The element
energy above takes one :math:`EI` per element, so an element over the arc :math:`[a, b]` of
length :math:`L` takes the compliance average

.. math::

   EI_e = L \left( \int_a^b \frac{\mathrm{d}s}{EI(s)} \right)^{-1},

which gives the exact relative end rotation of the element under a uniform moment: the stiff
root of a tapered sleeve is not allowed to stiffen a whole element that only partly lies on it.
On an ``EI = 0`` section of the line the bare part of an element has an infinite compliance,
so only an element the sleeve covers completely gains bending stiffness.
The element mass per length is the cable's plus :math:`\rho_s \tfrac{\pi}{4}\,
\overline{D^2 - d_i^2}`, where the bar is the mean over the element. Like a line type, the
element has one diameter, that of the displaced area of cable and solid sleeve,
:math:`\sqrt{d^2 + \overline{D^2 - d_i^2}}` with :math:`d` the cable diameter, for its
buoyancy (the dry part above the surface included), added mass, Froude–Krylov force and drag;
with the bore equal to the cable diameter it is the sleeve's outer diameter. The integrals use six-point Gauss–Legendre quadrature on each
part of the element a segment covers. With these one-per-element values the taper is resolved
by the mesh, as in a segmented line model; the driver notes a stiffener that spans fewer than
ten elements.

The node outputs do not use :math:`EI_e`. It stands for the whole element, so under a taper it
steps at every node although the section does not, and the softer side would overstate the
curvature by about :math:`h\lvert EI'\rvert/(2 EI)`, first order in the element length
:math:`h`. A node takes :math:`EI(s)` at its own arc instead, from the stiffener rows, one limit
from either side. The section moment :math:`M` (:ref:`theory-output-recovery`) is continuous and
second-order accurate, so the curvature :math:`\kappa = (1+\varepsilon) M/EI(s)` is too. Cable
and sleeve take that curvature and share the moment in proportion to the stiffnesses: the cable
carries :math:`EI_c\,M/EI(s)`, reported as ``BendMom``, and the sleeve the rest,
:math:`(EI(s) - EI_c)\,M/EI(s)`, reported as ``StfMom``.

The two limits differ only at a real step of the section: at the bare tip, between stiffener
rows whose end diameter, bore or modulus do not match, and between line types of different
:math:`EI`. There the side of the larger curvature gives the values, the bare one at the tip;
no threshold on the stiffness ratio is involved. A node past a tip inside an element is bare.

An element's interpolation bends under :math:`EI_e`, so on an element with a sleeve its curvature
is the curvature of no section: :math:`EI_e` times it is the linear fit of the moment over the
element, so at an element's end it is off by the same first-order step against :math:`EI(s)`,
high where the curvature falls toward the tip and low where it rises, and :math:`EI_e` times it
is low by :math:`h^2 M''/12` against :math:`M`. Two outputs that read the interpolation elsewhere read
the section here. The peak of such an element in ``.elements.out`` is the largest
:math:`(1+\varepsilon)\lvert M(u)\rvert/EI(s(u))` along it, with :math:`M(u)` the quadratic
through the recovered moments of the end nodes that keeps the mean of the fit; a row end inside the element,
or the tip, is a step of :math:`EI(s)` that the search keeps. Below the stiffness that resolves
the recovered moment (:ref:`theory-output-recovery`) both the nodes and the peak fall back on
the interpolation's curvature times :math:`EI_e/EI(s)`. ``OutputRecovery element`` reports
the recovered moment over :math:`EI(s)` on such an element, the same value as the equilibrium
recovery, and the exact trace on every other element. The geometric traces themselves stay
available as ``CD_HermiteCable_Dyn_Curvature_Exact``, and the mesh diagnostics
(:math:`h\kappa`) read them.

The deflection angle
``FairDefl``/``AnchDefl`` is :math:`\arccos(\hat{\mathbf F}\cdot\hat{\mathbf d})` between the
end force :math:`\mathbf F` and the direction :math:`\mathbf d` the end connection holds (into
the line), the angle through which the stiffener turns the cable.

The planar check ``driver_bend_stiffener`` compares a hang-off clamped through a 5 m stiffener
(a cylindrical root and a cone, 16 times the cable's stiffness at the root) with an independent
collocation solution of the extensible elastica
:math:`\theta' = (1+\varepsilon)^2 M/EI(s)`,
:math:`M' = -(1 + \varepsilon)(\cos\theta\,n_z - \sin\theta\,n_x)`,
:math:`\mathbf n' = (0, w(s))`: on 0.05 m elements the cable's moment over the stiffener and
3 m beyond follows the elastica within 0.01 % of its root value, cable and sleeve moments add up
to the section moment within 0.01 % at the root, the deflection angle agrees within 0.0001°, and
the node positions within 0.03 mm. Node by node, the curvature and the cable's moment follow the
elastica within 0.27 % of their local value on 0.1 m elements and 0.06 % on 0.05 m, 0.99 % on
0.2 m, under either output recovery, and the peaks of ``.elements.out`` under the stiffener
as closely. The local value is floored at 0.1 % of the root curvature, as the curvature changes
sign near the tip. On the same hang-off, the curvature along the stiffener follows OrcaFlex
11.6d with its stiffener given as a line attachment within 0.5 % of the root curvature.

.. _theory-output-recovery:

Node tension, curvature and bend moment
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

**Section force.** For the energy density :math:`W(\mathbf{a}, \mathbf{b})` of the element, the
force across a section (exerted by the part of the line beyond :math:`s` on the part before it)
and the conjugate of the material tangent are

.. math::

   \mathbf{F} = \frac{\partial W}{\partial \mathbf{a}} - \left(\frac{\partial W}{\partial \mathbf{b}}\right)',
   \qquad
   \mathbf{m} = \frac{\partial W}{\partial \mathbf{b}}
              = EI\,\frac{(\mathbf{a}\times\mathbf{b})\times\mathbf{a}}{\lvert\mathbf{a}\rvert^{6}} .

The energy is unchanged by a rotation of the whole line, so
:math:`\mathbf{r}\times\mathbf{F} + \mathbf{a}\times\mathbf{m}` changes along the line only by
the moment of the loads: the section moment is :math:`\mathbf{a}\times\mathbf{m}`, not
:math:`\mathbf{m}`, which is the conjugate of the tangent. With :math:`\kappa` the curvature of
the stretched line, the energy :math:`\tfrac12 EI\kappa^2` per unstretched metre gives

.. math::

   \lvert\mathbf{m}_\perp\rvert = \frac{EI\,\kappa}{(1+\varepsilon)^2},
   \qquad
   M = \lvert\mathbf{a}\times\mathbf{m}\rvert = \frac{EI\,\kappa}{1+\varepsilon},
   \qquad
   \kappa = (1+\varepsilon)\,\frac{M}{EI} .

On a stiff-``EA`` cable :math:`\lvert\mathbf{a}\rvert = 1 + \varepsilon` with
:math:`\varepsilon \ll 1`, :math:`\mathbf{a}\cdot\mathbf{b} = O(\varepsilon)` and
:math:`\mathbf{b} = \kappa\,\mathbf{n}`, so that
:math:`\partial W/\partial\mathbf{a} = (EA\,\varepsilon - 2EI\kappa^2)\,\mathbf{t}` plus normal
terms, :math:`\mathbf{m} \approx EI\,\kappa\,\mathbf{n}`, and
:math:`(\partial W/\partial\mathbf{b})'\cdot\mathbf{t} = EI\,\mathbf{b}'\cdot\mathbf{t} = -EI\kappa^2`.
The axial internal force of the rod, the effective tension that balances the loads, and the
bend moment are therefore

.. math::

   N = \mathbf{F}\cdot\mathbf{t} = EA\,\varepsilon - EI\,\kappa^2,
   \qquad
   M = EI\,\kappa \quad\text{to } O(\varepsilon) .

The curvature output is the geometric one, the reciprocal of the bend radius of the stretched
line: what the bend radius limit and the bending strain :math:`y\kappa` of a section point read.
``BendMom`` is :math:`M`, the moment that balances the forces, and at a line end the moment of
the end connection, whose potential depends on the direction of the tangent only. The check
``driver_curvature_stretch`` holds both against the elastica of this energy on a cable strained
up to 1.2 %: within 0.006 % and 0.001 % of the local value, against the 2.3 % and 1.2 % that
reading :math:`\lvert\mathbf{m}_\perp\rvert` as the moment gives. The stretch at a node is
:math:`\lvert\mathbf{r}'\rvert`, the length of its tangent, the one the discrete moment balance
holds with exactly; on a coarse stiff-``EA`` line it carries the pointwise oscillation above,
of order :math:`10^{-4}` of the curvature.

The bending energy measures the curvature per deformed length, and its dependence on the
stretch puts :math:`-EI\kappa^2` into the axial force: :math:`EA(\lvert\mathbf{r}'\rvert - 1)`
is a formulation quantity, not the tension, and exceeds :math:`N` by :math:`EI\kappa^2` on any
mesh (161 N on a 1.2 kN tension at the sag bend of the lazy-wave cable of
``iea15mw_umaine_mixed_cabledyn.dat``, :math:`\kappa = 0.09` 1/m). Global equilibrium fixes
:math:`N` whatever the formulation: on a suspended run the horizontal component of
:math:`\mathbf{F}` is constant and the vertical one changes by the submerged weight, so :math:`N`
is what any code converges to, the OrcaFlex effective tension and the MoorDyn segment tension
on a fine mesh among them.

**Pointwise oscillation.** With a stiff ``EA`` the cubic interpolation cannot keep
:math:`\lvert\mathbf{r}'\rvert` constant where the line must bend over an element (a nodal
seabed reaction, a section junction): the pointwise axial resultant oscillates about the element
mean by several times the tension, and the element means alternate between neighbours. On that
cable on the example's former 87-element mesh (10 m on the grounded run, tension 1.2 kN) the
pointwise resultant spans -41.5 to +91.8 kN and the length-weighted element means at the nodes
reach -173 N; at 1 m elements the pointwise field still spans -5.9 to +11.9 kN.

**Recovery from nodal equilibrium.** The node outputs are recovered from the element end
forces, the classical recovery of the finite-element nodal forces. For element :math:`e` the
end residual

.. math::

   \mathbf{g}_e = \mathbf{f}_{\text{int},e} + \mathbf{f}_{\text{damp},e} - \mathbf{f}_{\text{ext},e}
                + \mathbf{M}_e\,\mathbf{a}_e

holds only the element's own distributed loads: consistent submerged weight, the buoyancy lost
above the free surface, drag, Froude-Krylov force, structural and added-mass inertia, and the
seabed reaction of its end nodes, each nodal reaction spread uniformly over the grounded part of
the node's tributary length (the distributed floor reaction it stands for; without it a line
resting on the floor would report the fixed-end moment :math:`w L_0^2/12` of its own weight; at a
held line end whose end element lies on the floor, the reaction of the end half is the
floor-support share of the weight, the share that the static and dynamic residuals carry on the
end tangent rows). A half-element whose far node is on the floor is grounded whole; the
touchdown element, on the floor at one end only, is grounded from that end to the touchdown
point, where the clearance interpolated linearly between its two nodes reaches the contact onset
height (at most its half). The grounded stretch reaches the half-element as the suspended node
reaches the floor, and vanishes with the reaction as the grounded node lifts off, so the node
outputs vary continuously as nodes ground and lift off. With the reaction of the first grounded
node spread over its grounded half-element alone, the tension near touchdown carried a local
error that depended on where the touchdown point fell in its element and fell only at the first
order (at most 4.3, 1.9 and 1.0 N at 1.6, 0.8 and 0.4 m elements on the lazy-wave cable of
``lazy_wave_buoyancy_smeared.dat``, line tension 270 N there; 2.1, 0.7 and 0.2 N with the
grounded stretch), and it stepped as each node grounded.
:math:`\mathbf{g}_e`
is the generalised force the two end nodes exert on the element: its position rows at the
End-B side of the internal arc are the section force :math:`\mathbf{F}_j^-` just before node
:math:`j`, minus its rows at the other end the section force :math:`\mathbf{F}_j^+` just after
it, and its tangent rows are :math:`\mathbf{m}` there. An interior node reports

.. math::

   N_j = \mathbf{t}_j\cdot\tfrac{1}{2}\left(\mathbf{F}_j^- + \mathbf{F}_j^+\right),
   \qquad
   M_j = \lvert\mathbf{r}'_j\rvert\,
         \lvert \mathbf{m}_j - (\mathbf{m}_j\cdot\mathbf{t}_j)\,\mathbf{t}_j \rvert,
   \qquad
   \kappa_j = \lvert\mathbf{r}'_j\rvert\, M_j / EI ,

with :math:`\mathbf{t}_j` the unit nodal tangent, :math:`\mathbf{m}_j` the mean of the two
one-sided values, and at a section junction the larger of :math:`\kappa_j` on the two sides (under
a bend stiffener :math:`EI` is the stiffness at the node, :ref:`theory-bend-stiffeners`). The
recovered moment carries an error that does not depend on :math:`EI`, of the order of the largest
consistent-load moment :math:`w L_0^2/12` of an element (a section junction leaves a jump of that
order between the two one-sided moments), so over a soft section dividing by :math:`EI` amplifies
it. A section whose :math:`EI` is below :math:`\max_e(\lvert w_e\rvert L_{0,e}^2)/12` times 1 m,
the stiffness whose elastic moment at a 1 m bend radius equals that error, takes its curvature
from the exact geometric trace instead, as an element with :math:`EI = 0` does (on the 87-element
lazy-wave cable with :math:`EI` lowered to 100 N m\ :sup:`2` the
recovered curvature reaches 6.9 1/m against a geometric peak of 0.12 1/m; the bend moment of such a
section remains the recovered one, with that error). The
difference of the two one-sided forces is the point load left at the node (seabed friction, an
attachment) plus, where the nodal seabed reaction varies from node to node (the touchdown, a
rounded crease of the bathymetry), the difference between its spread and its nodal form, about
0.094 times its second difference along the line. The seabed reaction spread here is the one the
residual applies, with the crease increment of the penalty potential inside a rounded crease. At
the converged static state the nodal section forces satisfy the discrete
equilibrium exactly. In a dynamic run the recovery is the balance at the output time
:math:`t_{n+1}`, with the position, velocity and acceleration the step committed there: the
inertia term :math:`\mathbf{M}_e\mathbf{a}_e` uses the step's acceleration
:math:`\mathbf{a}_{n+1}` at :math:`\mathbf{q}_{n+1}`. The integrator balances the generalised-alpha
combination of the :math:`t_n` and :math:`t_{n+1}` states, so the recovered forces differ from
the integrator's balance by :math:`O(\Delta t)`; the recovered forces carry none of the pointwise
oscillation. A line end reports the ``FairTen``/``AnchTen`` end force and its one-sided moment;
the segment tension of an element is the mean of the axial components of its own two end forces.
The recovery costs one element evaluation per element and output row.

The end node tension and the interior node tension are therefore different quantities. The end
value is the end reaction, the force on the support or the platform: it holds the end element's
internal force and the end node's share of the weight, buoyancy, drag and contact, but not
inertia, added mass or seabed friction, which stay in the coupled load. The interior value is the
recovered section force, built from end forces that include those terms. At rest and in a
quasi-static march the two agree; under acceleration the interior values carry the inertia and
added-mass terms of the two neighbouring elements, and the end values do not.

On the 87-element lazy wave the interior node tension departs from the equilibrium of the
converged line by at most 60 N (1552 N for the element means), 12 N at twice the mesh density
and 0.3 N at 1 m elements (516 N); the largest curvature error falls from 64 % to 30 % of the
peak at 87 elements and from 2.1 % to 0.8 % at 1 m. The peak curvature at a
touchdown meshed coarser than the bending length is limited by the solution itself, not by the
recovery.

The condensed torque of a line restrained in torsion is not part of :math:`\mathbf{g}_e`: it adds
a shear normal to the tangent and does no work on bending rotations. Including its element terms
on ``torsion_lazy_wave_hangoff_twist.dat`` (two turns, torque 3.5 kN m) moves the tension by
at most 0.45 N of 9.4 kN and moves the bend moment away from :math:`EI\kappa`.

``OPTIONS`` ``OutputRecovery element`` restores the element definitions: the length-weighted
mean of the element-mean axial forces :math:`EA(\lvert\mathbf{r}'\rvert - 1)` at an interior
node, the larger one-sided exact curvature (the section's on an element with a bend stiffener
sleeve, :ref:`theory-bend-stiffeners`), and the midpoint axial resultant as the segment
tension. The material-strain checks (``tensile_safety``, the static compression notes) judge
:math:`EA\varepsilon` under either setting.

.. _theory-section-curvature:

Curvature on the section axes
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``CurvX<L>N<J>`` and ``CurvY<L>N<J>`` resolve the nodal curvature vector
:math:`\kappa\mathbf{n}`, which points to the centre of curvature, on two axes of the cable's
cross section. The vector is the one whose length is ``Curv<L>N<J>``: the normal part of the
recovered section moment over :math:`EI` on the side that gives the curvature, or the exact
trace :math:`(\mathbf{r}' \times \mathbf{r}'') \times \mathbf{r}'/|\mathbf{r}'|^4` where
the recovery falls back to it (:ref:`theory-output-recovery`).

The section axis :math:`\mathbf{d}_1` (x) starts at End A normal to the End A → End B tangent
:math:`\mathbf{t}`:

- on a line restrained in torsion, along End A's torsion normal ``Nx``, which turns with the
  hang-off; on a line restrained at End B only (End A free to twist), along End A's own
  section: End B's ``Nx``, rolled by End B's ``Pretwist``, carried to End A and turned by the
  twist of the line (:ref:`a free end <theory-free-end>`);
- otherwise along the static start's upper normal, the projection of global +z normal to the
  End A tangent (global +x where the tangent is vertical). It is fixed in the hang-off's axes
  when End A is clamped or held by a finite rotational stiffness, so it turns with the vessel,
  and fixed in global axes at a pinned End A, where the roll of the section is undefined.

It is carried to every node by parallel transport along the centreline, eight smallest
rotations between the Hermite tangents per element, which does not twist it about the tangent.
On a line in torsion it is then turned about :math:`\mathbf{t}` by the twist from End A, the
torque times the End A compliance plus :math:`\sum l_0/GJ` from End A, right-handed about
:math:`\mathbf{t}`. In the dynamics, with the :ref:`nodal twist <theory-nodal-twist>`,
it is the material director of each node, on the same convention. With :math:`\mathbf{d}_2 = \mathbf{t} \times \mathbf{d}_1` (y),
``CurvX`` :math:`= \kappa\mathbf{n} \cdot \mathbf{d}_1` and ``CurvY``
:math:`= \kappa\mathbf{n} \cdot \mathbf{d}_2`. A fibre at :math:`(x, y)` in the section is
strained in bending by :math:`-(\kappa_x x + \kappa_y y)`. On a line twisted 90 degrees from
End A to End B the carried axes reach End B within 3e-6 rad of its own pretwisted normal.

.. _theory-torsion:

Condensed torsion
~~~~~~~~~~~~~~~~~

A line restrained in torsion at both ends (``END CONNECTIONS`` ``TorsStiffness``, see
:doc:`driver_format`) adds the twist of an isotropic Kirchhoff rod without adding degrees of
freedom. For an isotropic section with no distributed torque the twisting moment
:math:`M = GJ\,u_3`, with :math:`u_3` the material twist rate, is uniform along the rod
(:ref:`van der Heijden et al., 2003 <ref-vanderheijden2003>`). The twist field
then condenses to one scalar per line, and the line energy gains

.. math::

   E_t = \frac{(\Phi - \Theta(\mathbf{q}))^2}{2C}, \qquad
   M = \frac{\Phi - \Theta}{C}, \qquad
   C = \sum_e \frac{L_{0,e}}{GJ_e} + \frac{1}{k_A} + \frac{1}{k_B} .

:math:`\Phi` is the imposed relative roll of the End B frame with respect to the End A frame
(``Pretwist`` and the ``motionFile`` roll column), :math:`k_A, k_B` are the optional torsional end
springs (:math:`1/k = 0` for ``Rigid``), and :math:`\Theta(\mathbf{q})` is the geometric twist of
the centreline: the angle about the End B direction :math:`\mathbf{d}_B`, right-handed, from the
End B reference normal :math:`\mathbf{n}_B` to the End A normal :math:`\mathbf{n}_A` carried to End B
by parallel transport. Each end frame :math:`(\mathbf{d}, \mathbf{n})` turns with the body or vessel
that holds the end. A clamped end has :math:`\mathbf{d}` equal to its end tangent; at a
bending-pinned end :math:`\mathbf{d}` is the connection direction and the transport starts with
the smallest rotation from :math:`\mathbf{d}` to the tangent.

Because the Hermite centreline is :math:`C^1`, the transport factorises into one holonomy per
element and a chain of smallest rotations between the unit node tangents
:math:`\mathbf{t}_k = \mathbf{m}_k/\lvert\mathbf{m}_k\rvert`:

.. math::

   \Theta = \sum_e h_e + \chi, \qquad
   h_e = \int_e \frac{\mathbf{t}_1 \cdot (\mathbf{a} \times \mathbf{b})}
                     {\lvert\mathbf{a}\rvert^2 \left(1 + \mathbf{t}_1\cdot\mathbf{a}/\lvert\mathbf{a}\rvert\right)}
         \,\mathrm{d}s ,

with :math:`\mathbf{t}_1` the tangent at the element's first node, :math:`\mathbf{a} = \mathbf{r}'`,
:math:`\mathbf{b} = \mathbf{r}''` at the Gauss points of the bending rule, and :math:`\chi` the
angle of the smallest-rotation chain
:math:`\mathbf{d}_A \to \mathbf{t}_1 \to \dots \to \mathbf{t}_N \to \mathbf{d}_B` applied to
:math:`\mathbf{n}_A`. For differentiation, each link of the chain is written with a gauge frozen at
the current configuration as a sum of signed solid angles
:math:`\Omega(\mathbf{x}, \mathbf{y}, \mathbf{z}) = 2\operatorname{atan2}(\mathbf{x}\cdot(\mathbf{y}\times\mathbf{z}),
1 + \mathbf{x}\cdot\mathbf{y} + \mathbf{y}\cdot\mathbf{z} + \mathbf{z}\cdot\mathbf{x})` of geodesic
triangles, each of which involves at most two neighbouring tangents. The gradient and Hessian
of :math:`\Theta` are therefore local, in closed form, and have the half-bandwidth of the cable
tangent; the value of :math:`\Theta` is taken from the sequential product. This is the
discrete parallel transport and holonomy of :ref:`Bergou et al. (2008) <ref-bergou2008>` applied
to the Hermite centreline. The test suite checks the closed form against automatic
differentiation of an independent reference implementation, against finite differences, and
for invariance under rigid rotation.

:math:`\Theta` is known modulo :math:`2\pi`. The solver carries its unwrapped value as a state
of the line, unwraps each new evaluation to the branch nearest the last accepted value, and
accepts no step that changes :math:`\Theta` by more than :math:`\pi/2`; such a step is cut. A
link or Gauss point at which the tangent turns by more than 120° within one element or between
neighbouring nodes (:math:`1 + \mathbf{t}_1\cdot\mathbf{t} < 0.5`) stops with a named error; a
mesh that resolves the curvature is far from it.

**Residual and tangent.** The torsion term adds :math:`-M\,\nabla\Theta` to the residual and

.. math::

   \mathbf{K} = \underbrace{\mathbf{K}_c - M\,\nabla^2\Theta}_{\mathbf{B}\ \text{(banded)}}
               + \frac{1}{C}\,\nabla\Theta\,\nabla\Theta^{\mathsf T}

to the tangent. The rank-one term is not banded; each Newton step solves the bordered system
by Sherman–Morrison on the band factorisation of :math:`\mathbf{B}` with two right-hand sides,
:math:`\mathbf{B}\mathbf{y} = -\mathbf{R}`, :math:`\mathbf{B}\mathbf{z} = \nabla\Theta`,
:math:`\mathbf{x} = \mathbf{y} - \mathbf{z}\,(\nabla\Theta\cdot\mathbf{y})/(C + \nabla\Theta\cdot\mathbf{z})`,
and accepts it on a backward-error test, with a shifted factorisation and iterative refinement
as the fallback. Dropping the rank-one term would leave a Newton iteration that converges only
linearly, at the rate :math:`\nabla\Theta^{\mathsf T}\mathbf{B}^{-1}\nabla\Theta / C`; on the
post-buckled states of the validation (see :doc:`validation`) that rate is 0.05 to 0.22. The
same term enters the dynamic effective tangent, scaled by :math:`1 - \alpha_f` of the force
blend, and is frozen together with a reused factorisation.

**Statics and stability.** The imposed twist is the last static load stage (on a line with
``ATTACHMENTS``, after the attachment polish, on the discrete equilibrium), ramped from the
geometric twist of the untwisted equilibrium in steps of at most :math:`\pi/4`. Each converged
stage is tested for stability by the inertia of :math:`\mathbf{K}` on the free DOFs,
:math:`\operatorname{neg}(\mathbf{K}) = \operatorname{neg}(\mathbf{B}) -
[1 + \nabla\Theta^{\mathsf T}\mathbf{B}^{-1}\nabla\Theta/C < 0]`, with the negative eigenvalues
of :math:`\mathbf{B}` counted by a banded :math:`\mathbf{L}\mathbf{D}\mathbf{L}^{\mathsf T}`
factorisation. Above a buckling onset the straight twisted state is a saddle to which Newton
converges quadratically; the static solve then descends along the lowest mode with energy
acceptance onto the buckled branch, and reports the descent. The onset is that of a
clamped–clamped rod under the dead tension :math:`T`, eq. (33) of
:ref:`van der Heijden et al. (2003) <ref-vanderheijden2003>`; at :math:`T = 0` it reduces to
:math:`\tan x = x`, :math:`x = ML/2EI`, so :math:`M_{cr} = 8.9868\,EI/L`. At large tension it
approaches the localised value :math:`2\sqrt{EI\,T}` of an infinite rod from above, reported in
the same paper. A bending-pinned end restrained in torsion transmits the torque about the
bisector of the connection direction and the tangent (a *semi-tangential* end, a
constant-velocity joint), for which :math:`\tan x = -x/3` and :math:`M_{cr} = 4.9113\,EI/L` at
zero tension, not the :math:`2\pi EI/L` of Greenhill's axial-torque hinge. OrcaFlex's
bending-free end with a twisting spring gives the same value (see :doc:`validation`).

**Dynamics and loads.** A deck line carries the nodal twist below in the dynamics, with the
condensed torsion as its limit of a negligible polar inertia; a line built through the API
without the polar inertia keeps the condensed torsion, whose torque follows the imposed twist
within the step, without a torsional wave. Either enters the force-blended residual like the
internal force, so a dynamic deck with torsion requires ``True alpha_force_blend`` (the
default). In the condensed torsion, the moment of the torque on the object at End A is :math:`M\,\partial\Theta/\partial\boldsymbol{\omega}_A`, the derivative with
respect to a rotation :math:`\boldsymbol{\omega}_A` of that object (for a clamped end, of its frame
and the end tangent together), so the virtual work of the body moment is exact; for a straight
line it is the torque along the line axis. The static body equilibrium uses the same moment and
its stiffness :math:`\mathbf{a}\mathbf{a}^{\mathsf T}/C`, :math:`\mathbf{a} = \partial\Theta/\partial\boldsymbol{\omega}_A`.

**Torque–tension coupling.** The helical armour of a power cable or a wire rope couples
stretch and twist. With the coupling :math:`K` of the section (``GJ|K`` in the ``GJ`` column, see
:doc:`driver_format`), the section laws are

.. math::

   T = EA\,\varepsilon + K\,\tau, \qquad M = GJ\,\tau + K\,\varepsilon ,

with :math:`\tau` the material twist rate and :math:`EA\,GJ > K^2`. The torque is still uniform
along the line, so the twist rate :math:`\tau = (M - K\varepsilon)/GJ` follows the strain
pointwise and the condensation stays exact. The cable carries the axial stiffness
:math:`EA - K^2/GJ` of a section free to twist, and the twist the ends see is

.. math::

   \Theta_{\text{eff}} = \Theta - \sum_e \frac{K_e}{GJ_e}\,(l_e - L_{0,e}), \qquad
   M = \frac{\Phi - \Theta_{\text{eff}}}{C} ,

where :math:`l_e = \int_e \lvert\mathbf{r}'\rvert\,\mathrm{d}s` is the stretched element
length, integrated on the bending rule with its gradient and Hessian. Everything else above,
including the rank-one tangent, the step limit and the stability test, holds with
:math:`\Theta_{\text{eff}}`. The coupling part has no :math:`2\pi` ambiguity, so the first
evaluation unwraps the holonomy alone. A line free to twist at one end carries no torque and
the axial stiffness :math:`EA - K^2/GJ`, and its free end turns by the element twists,
:math:`-\sum_e (K_e/GJ_e)(l_e - L_{0,e})` (see the free end below). Restrained at both ends, a
straight stretched line
cannot twist, so it carries :math:`T = EA\,\varepsilon` and :math:`M = K\varepsilon`. The node
tension adds the element's :math:`(K/GJ)\,M`, and the twist channels sum the element twists
:math:`M L_0/GJ - (K/GJ)(l - L_0)`.

.. _theory-nodal-twist:

**Nodal twist (dynamics).** The dynamics give every node :math:`k` a twist angle
:math:`\varphi_k`: the angle about the unit node tangent :math:`\mathbf{t}_k` from a reference
director :math:`\mathbf{u}_k` to the material director. Over each step the reference directors
follow their tangents by the smallest rotation (time-parallel transport), so the axial angular
velocity of the section is :math:`\dot\varphi_k`. The material twist of element :math:`e`
between nodes :math:`k` and :math:`k+1` is :math:`\varphi_{k+1} - \varphi_k + m_e`, with the
reference twist :math:`m_e = \beta_e - h_e`: :math:`\beta_e` the angle from :math:`\mathbf{u}_k`,
carried to node :math:`k+1` by the smallest rotation, to :math:`\mathbf{u}_{k+1}`, and :math:`h_e`
the element holonomy above. Transport around the geodesic quadrilateral of the committed and
present tangents gives

.. math::

   \beta_e = \beta_e^n - \Omega(\mathbf{t}_k^n, \mathbf{t}_k, \mathbf{t}_{k+1})
                     - \Omega(\mathbf{t}_k^n, \mathbf{t}_{k+1}, \mathbf{t}_{k+1}^n) ,

local to the element's 12 DOFs, with the closed-form gradient and Hessian of the solid angles.
The turns of the line live in the angles, so no :math:`2\pi` branch is tracked. This is the
time-parallel reference frame of discrete elastic rods (:ref:`Bergou et al., 2008
<ref-bergou2008>`) on the Hermite centreline. The element carries the torque

.. math::

   M_e = \frac{GJ_e}{L_{0,e}}\,\hat\tau_e + \frac{B_{t,e}}{L_{0,e}}\,\dot{\hat\tau}_e, \qquad
   \hat\tau_e = \varphi_{k+1} - \varphi_k + m_e + \frac{K_e}{GJ_e}\,(l_e - L_{0,e}) ,

the elastic torque of the energy :math:`\tfrac12 (GJ/L_0)\,\hat\tau^2`, which with the cable's
axial stiffness :math:`EA - K^2/GJ` is the section energy of the torque–tension coupling, and
the Kelvin–Voigt torsional damping :math:`B_t` (``GJ|K|Bt``), whose rate takes the nodal rates
and :math:`\nabla\hat\tau\cdot\dot{\mathbf{q}}`. The damping is stiffness-proportional: the
torsional mode of frequency :math:`\omega` has the damping ratio :math:`\omega B_t/(2GJ)`. The
polar rotary inertia :math:`I_{rn}` (``Irn``) is lumped at the nodes. An elastic end adds its
spring between the end node and the end frame's normal carried to the node; a rigid end takes
that normal as its node's director and holds the node's angle (0 at the first node of the solve
order, End B, and :math:`\Phi` at End A), so a turn of the frame enters the end element's
reference twist through the same solid angles. A turn of an end frame by more than
:math:`\pi/2` about the line within one step is refused, and the step is cut.

The held end section turns with its frame. Its spin about the tangent, relative to the
time-parallel reference, is the frame's angular velocity projected by the derivative of the end
element's reference twist with respect to the frame's rotation. Its polar inertia (half the end
element's) carries the kinetic energy of that spin and loads the frame through the reaction
moment. A bending-pinned or elastic end lets the end tangent :math:`\mathbf{t}` move off the
director :math:`\mathbf{d}`, and the section's director, the frame's normal carried by the
smallest rotation :math:`G(\mathbf{d} \to \mathbf{t})`, then spins about :math:`\mathbf{t}` as
well:

.. math::

   c = \frac{(\mathbf{t} \times \mathbf{d})\cdot\dot{\mathbf{t}}}{1 + \mathbf{d}\cdot\mathbf{t}},
   \qquad \lvert c\rvert \le \tan\tfrac{\theta}{2}\,\lvert\dot{\mathbf{t}}\rvert ,

with :math:`\theta` the end bend angle. The model leaves this carry spin out of the kinetic
energy, out of the line's equations of motion and out of the reaction moment alike, so the
three stay consistent: with the end frames held, the energy without the carry spin keeps the
same band at a polar inertia of 0.02 and of 1 kg m. Including the spin would give the end tangent
a configuration-dependent rank-one polar mass :math:`I\,\nabla c\,\nabla c^{\mathsf T}` with its
gyroscopic velocity terms. Its kinetic energy :math:`\tfrac12 I c^2` is of order
:math:`(d^2/2l^2)\tan^2(\theta/2)` of the end element's translational kinetic energy (section
diameter :math:`d`, element length :math:`l`). The test suite measures it on a 10 m line pinned
in bending and rigid in torsion at both ends, twisted by 4 rad and swinging with a 13° end bend
angle: 6e-8 of the peak kinetic energy at :math:`I_{rn} = 0.02` kg m and 4e-6 at an extreme
1 kg m, against the step's own energy band of 6e-3 at :math:`\rho_\infty = 1`. The modal analysis
and the OpenFAST linearisation take the same lumped polar mass on the angles, with a held end's
angle not a coordinate, so they leave the carry spin out too.

.. _theory-free-end:

**A free end.** A line restrained in torsion at one end only has its other end free to twist:
an infinite end compliance, so the condensed compliance :math:`C` is infinite and the condensed
torque :math:`(\Phi - \Theta_{\text{eff}})/C` zero. The statics are then those of the line
without torsion (with the axial stiffness :math:`EA - K^2/GJ`), and every element twists by
:math:`\hat\tau_e = 0`, i.e. by :math:`-(K_e/GJ_e)(l_e - L_{0,e})` of material twist; their sum
is ``Twist<L>``, the turn of End B relative to End A against the restrained end's frame
carried along the line (a free End A turns by its negative). In the dynamics the free end's node has no spring and no held angle: its angle
is free, its lumped inertia :math:`I_{rn} L_0/2` and its element's torque balance it, and its
end frame is a gauge that nothing reads (the free end's ``Nx`` and ``Pretwist`` are not used).
The torque vanishes at the free end, so torsional waves reflect there, and the line's modes are
the clamped–free ones, :math:`\omega_n = (2n - 1)\,\pi/(2L)\,\sqrt{GJ/I_{rn}}` for a uniform
line held rigidly at the other end; a roll :math:`A\sin\Omega t` of the restrained end turns
the free end by :math:`A/\cos kL` (:math:`k = \Omega\sqrt{I_{rn}/GJ}`) and loads the
restrained end with :math:`GJ A k \tan kL`. Exactly one end is restrained, so no rigid spin of
the angles is left free. The modal analysis and the OpenFAST linearisation take the free end's
angle as a coordinate (no spring term in the twist Hessian) and give these clamped–free modes,
and a free end has no roll stiffness. The test suite checks these frequencies, the driven
response at :math:`kL = \pi/4` and :math:`3\pi/4` and the free end's coupling turn against
the continuum.

In the limit of a negligible inertia the element torques are uniform and equal the condensed
torque; the test suite holds the two models to 1e-6 on a rolling, swaying, bowed line with
clamped, bending-pinned and elastic ends, and checks the torque of a driven torsional wave
against the continuum, the decay of the first torsional mode under :math:`B_t`, and the energy
of a free vibration (see :doc:`validation`).

The angles join the generalised-α step with the same Newmark scheme. The tangent couples them
to the tangent DOFs of their elements: the step factorises one band in the order
:math:`[\mathbf{r}, \mathbf{m}, \varphi]` per node (half-bandwidth 13 instead of 11), into which
the cable's tangent, the angle rows and columns, the lumped inertia and the damping are
assembled; the angle rows converge on the nodal torque balance, scaled as the force rows are by
the nodal loads. The committed reference twists are advanced with the step's own solid angles, so
the committed state reproduces the converged iterate bit for bit, and the twist state is part of
the snapshot, the recovering step and the checkpoint mirror. A host write of the coupled end
between steps (the direct feedthrough) twists the end element against the frozen interior, as
the end's translation stretches it. The node torque (``Torq<L>N<J>``) is the mean of its two
elements', and the material twists of the elements sum to the twist channels.

**Active line control.** A length command on a controlled element (see Active line control
below) changes every torsion term that reads :math:`L_0`: the condensed compliance
:math:`C = \sum_e L_{0,e}/GJ_e + 1/k_1 + 1/k_2`, the element stiffness :math:`GJ/L_0` and damping
:math:`B_t/L_0` of the nodal twist, the coupling term :math:`(K/GJ)(l - L_0)` and, through the
Hermite interpolant, the element holonomy. Each is evaluated with the lengths of its time level,
as the rest of the residual: the committed force with the lengths the committed state was reached
with, the step's force with the new ones. The lumped polar inertia :math:`I_{rn} L_0/2` is rebuilt
with the consistent mass (its rate term is not modelled either), and a torsional damping written
as :math:`-\zeta` is resolved again at the new length, :math:`B_t = \zeta L_0 \sqrt{GJ I_{rn}}`, so
the element keeps its fraction of critical damping; a positive :math:`B_t` is a section property
and stays (the axial ``BA`` keeps its initial resolution, as in MoorDyn). The torsional damping
takes the rate of the twist per unit length :math:`\hat\tau/L_0` that the elastic torque reads, as
the axial damping takes the rate of the strain:

.. math::

   M_e = \frac{GJ_e}{L_{0,e}}\,\hat\tau_e + B_{t,e}\,\frac{d}{dt}\frac{\hat\tau_e}{L_{0,e}}
       = \frac{GJ_e}{L_{0,e}}\,\hat\tau_e + \frac{B_{t,e}}{L_{0,e}}
         \Big(\dot{\hat\tau}_e - \hat\tau_e\,\frac{\dot L_{0,e}}{L_{0,e}}\Big) .

At fixed :math:`\mathbf{q}` the twist changes with :math:`L_0` through the coupling term and the
element's shape. Write :math:`\mathbf{a}_1, \mathbf{a}_2` for the tangent DOFs of the element's two
nodes (the nodal :math:`\mathbf{m} = d\mathbf{r}/ds`). The reference twist :math:`m_e` depends on
them only through :math:`L_0\mathbf{a}_i` (the Hermite :math:`\mathbf{r}'` and
:math:`\mathbf{r}''`) and :math:`\mathbf{a}_i/|\mathbf{a}_i|`, and the stretched length
:math:`l_e` only through :math:`L_0\mathbf{a}_i`, so with :math:`c_e = K_e/GJ_e`
:math:`L_0\,\partial(m_e + c_e l_e)/\partial L_0 = \sum_i \mathbf{a}_i\cdot\partial(m_e + c_e
l_e)/\partial\mathbf{a}_i`, and

.. math::

   \dot{\hat\tau}_e = \dot\varphi_{k+1} - \dot\varphi_k + \nabla\hat\tau_e\cdot\dot{\mathbf{q}}
     + \frac{\dot L_{0,e}}{L_{0,e}}\Big(\mathbf{a}_1\cdot\frac{\partial\hat\tau_e}{\partial\mathbf{a}_1}
     + \mathbf{a}_2\cdot\frac{\partial\hat\tau_e}{\partial\mathbf{a}_2} - c_e L_{0,e}\Big) ,

with the matching tangent terms. A segment paid out at a constant twist per length carries no
damping torque. The test suite checks the quasi-static torque :math:`GJ\Phi/L(t) + K(H - L)/L` of a
taut line paid out and hauled in (condensed and nodal twist), the Kelvin–Voigt torque of a constant
pay-out, the length-rate term against finite differences on a bowed line, the energy a length
change puts into a ringing twist, and that the step does not lag at :math:`\alpha_f > 0`.

**Limits.** Seabed friction does not resist twist, so the laid part of a line twists freely
(the friction torque of a cable on the seabed can be comparable with the twist torque near
touchdown). There is no anisotropic or pre-twisted section, and no self-contact: a loop that
closes on itself is not resolved. The model is that of :ref:`Meier, Popp & Wall (2014) <ref-meier2014>` and
:ref:`Bergou et al. (2008) <ref-bergou2008>` restricted to the isotropic, torque-free-span case;
it is not a new formulation.

Constitutive laws
-----------------

Axial response is chosen per line type. Stateful laws advance their committed internal state
once per converged step, from the converged kinematics, in a single commit that is rolled back
together with the positions if any part of the step fails.

Linear elasticity
~~~~~~~~~~~~~~~~~

:math:`T = EA\,\varepsilon`. On the ``EI = 0`` path the dynamic law is tension-only, as above.
On the Hermite path the axial law is two-sided: the energy
:math:`\tfrac{1}{2}EA\,\varepsilon^2` is used for both signs of :math:`\varepsilon`, which keeps the
bending equations well posed in locally slack regions.

**Tensile audit (Hermite path).** Option ``tensile_safety`` inspects the axial force of the
line after each converged step. The audited force is the one that enters equilibrium, as in
the static branch audit below: the element-mean axial force (the three-point Gauss mean of the
signed resultant :math:`EA\,(|\mathbf r'| - 1)`), averaged over each element and its two
neighbours weighted by length (one neighbour at a line end). The pointwise resultant of a
stiff-``EA`` cubic-Hermite element oscillates about that mean, and a single element mean dips
next to a nodal seabed-contact reaction, by amounts that grow with the element length: judged
pointwise, a coarse mesh whose tensions and curvatures are converged reads as compressed (the
Gulf of Mexico 80 m lazy-wave cable of :ref:`Lozon et al. (2025) <ref-lozon2025>` under a
3 m, 12 s heave: tens of kN on 48 elements, where the fairlead
tension and the peak curvature are within 1 % of a 1024-element mesh). A compressed span of
three or more elements is never averaged away. A step is flagged when the three-element mean
falls below :math:`-\epsilon_\text{tol}\,\overline{EA}`, with :math:`\overline{EA}` the
length-weighted ``EA`` of the same elements and :math:`\epsilon_\text{tol} = 2\times10^{-6}` by
default (``tensile_strain_tolerance``). In ``error`` mode the step is rejected; in ``warn``
mode it is committed and the worst event is reported (force, threshold, centre element, time).
The audit is a response diagnostic and does not change the constitutive law.

Axial damping
~~~~~~~~~~~~~

Axial Kelvin–Voigt damping adds a resultant proportional to the strain rate. On the
``EI = 0`` path, for an element with tangent :math:`\mathbf{t}` and nodal velocities
:math:`\mathbf{v}_a, \mathbf{v}_b`,

.. math::

   T_d = \frac{BA}{L_0}\,\mathbf{t}\cdot(\mathbf{v}_b - \mathbf{v}_a),

applied along :math:`\mathbf{t}` with the MoorDyn sign convention
(:ref:`Hall & Goupee, 2015 <ref-hall2015>`). On the Hermite path the same law is integrated
over the element,

.. math::

   \dot\varepsilon = \frac{\mathbf{t}\cdot\mathbf{v}_{,\xi}}{L_0}, \qquad
   \mathbf{t} = \frac{\mathbf{r}_{,\xi}}{\lvert\mathbf{r}_{,\xi}\rvert}, \qquad
   \mathbf{f}_{d,a} = \int_0^1 BA\,\dot\varepsilon\,H'_a(\xi)\,\mathbf{t}\,\mathrm{d}\xi ,

with exact position and velocity Jacobians. A negative ``BA`` column value is a target
damping ratio :math:`\zeta = -BA_\text{input}` of the axial mode of each segment, resolved per
element as

.. math::

   BA = \zeta\,L_0\,\sqrt{EA\,\rho_A},

using the final element length after any mesh refinement. The damping share is included in
the reported tension.

**The damping ratio form depends on the mesh.** ``BA`` resolved this way is proportional to the
element length, so it is a property of the discretisation, not of the material. For a uniform
line of :math:`N` elements the axial mode :math:`n` (wavenumber :math:`n\pi/L`) has the damping
ratio

.. math::

   \zeta_n = \frac{BA\,\omega_n}{2\,EA} = \zeta\,\frac{n\pi}{2N} ,

so the element-scale modes (:math:`n \approx N`) are damped at up to :math:`(\pi/2)\,\zeta`, as intended
(the convention suppresses segment-scale axial noise, the same one as MoorDyn's negative
``BA``), while the line's global axial modes are damped much less, and less again on a finer
mesh: ``BA = -1`` on 100 elements gives the first axial mode 1.6 %, and 0.8 % on 200 elements.
Results that depend on the axial damping (tension peaks of snatch loads, the decay of axial
oscillations) therefore change with the mesh. The initialisation of a dynamic run notes, for every
line with a negative ``BA``, the damping ratio this gives its first axial mode on its final mesh:
the Rayleigh quotient :math:`\zeta_1 = \mathbf u^\mathsf T\mathbf C\mathbf u /
(2\,\omega_1\,\mathbf u^\mathsf T\mathbf M\mathbf u)` of the first mode :math:`\mathbf u` of the
line's axial chain with both ends held (element stiffness :math:`EA/L_0`, damping
:math:`BA/L_0`, the dry mass lumped at the nodes), which is :math:`\zeta\sin(\pi/(2N))` on a
uniform line and holds for a composite one.

**First-mode damping ratio** (``mode1 axialDampingRatio``, :doc:`options`). A negative ``BA`` is
then the damping ratio of the line's first axial mode, the same on any mesh:

.. math::

   BA = \frac{2\,\zeta\,EA}{\omega_1}

on every element, with :math:`\omega_1` the first axial natural frequency of the line with both
ends held, from its sections' unstretched lengths, ``EA`` and dry mass per length (the first mode
of the axial chain on a fixed internal mesh of 2048 elements, so independent of the line's mesh;
:math:`\omega_1 = (\pi/L)\sqrt{EA/\rho_A}` on a uniform line, to 1e-7). The damping is then
proportional to the stiffness, :math:`\mathbf C = (2\zeta/\omega_1)\,\mathbf K`, so the first
axial mode of a composite line is damped at :math:`\zeta` too and the mode :math:`n` at
:math:`\zeta\,\omega_n/\omega_1`. Added mass and the tension are left out of :math:`\omega_1`. A
viscoelastic or Syrope section has no single ``EA`` that sets the first mode, so a line with one
and a negative ``BA`` is refused under this option; ``BA`` in N·s is used as given under both
conventions.

Viscoelastic rope (MoorDyn ``ElasticMod`` 2 and 3)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The viscoelastic law of :ref:`Hall, Duong & Lozon (2023) <ref-hall2023>` is a four-parameter
series-Kelvin solid: a fast Kelvin–Voigt branch (spring :math:`EA_D` parallel to dashpot
:math:`BA_D`) in series with a slow Kelvin–Voigt branch (spring :math:`EA_1` parallel to dashpot
:math:`BA_s`). It reduces to the standard linear solid only when :math:`BA_D = 0`. The slow
spring is chosen so that the static composite stiffness equals the line-type ``EA``:

.. math::

   EA_1 = \frac{EA_D\,EA}{EA_D - EA}, \qquad EA_D > EA .

Each element carries the slow-branch stretch :math:`\Delta l_1` as a state. With
:math:`\Delta l = \ell - L_0`,

.. math::

   \dot{\Delta l_1} = \frac{EA_D\,\Delta l - (EA_D + EA_1)\,\Delta l_1 + BA_D\,\dot\ell}
                           {BA_D + BA_s},
   \qquad
   T = \frac{EA_1\,\Delta l_1 + BA_s\,\dot{\Delta l_1}}{L_0} .

The series chain is tension-only: the element carries :math:`\max(T, 0)`, and while
:math:`T = 0` the slow branch relaxes under zero load, :math:`BA_s\,\dot{\Delta l_1} + EA_1\,\Delta l_1 = 0`.
At :math:`T = 0` the loaded and slack states coincide, so the force and the state are continuous
through slack. MoorDyn's formulation applies the slack condition to the elastic part when
:math:`\Delta l < 0`, so the two formulations differ through slack while
:math:`\Delta l_1 \ne 0` and agree whenever MoorDyn's tension is non-negative with
:math:`\Delta l \ge 0`. Inside a time step
the state equation is linear in :math:`\Delta l_1`, so backward Euler eliminates it in closed form,

.. math::

   \Delta l_1(\mathbf{q}, \mathbf{v}) =
   \frac{\Delta l_{1,n} + \Delta t\,(EA_D\,\Delta l + BA_D\,\dot\ell)/B}
        {1 + \Delta t\,(EA_D + EA_1)/B}, \qquad B = BA_D + BA_s ,

giving an element load with exact position and velocity Jacobians inside the implicit step.
The initial state is the zero-rate partition
:math:`\Delta l_1 = \Delta l\,(EA_D - EA)/EA_D`, at which the tension equals the static
:math:`EA\,\Delta l/L_0`, so the static equilibrium is an exact fixed point of the dynamics.

``ElasticMod`` 3 makes the dynamic stiffness depend on the mean load. For
:math:`\Delta l_1 > 0` and :math:`k = EA/L_0`,

.. math::

   EA_D = \tfrac{1}{2}\left(\alpha_\text{MBL} + v_\beta\,\Delta l_1\,k + EA
   + \sqrt{\alpha_\text{MBL}^2 + 2\alpha_\text{MBL}\,k\,(v_\beta\,\Delta l_1 - L_0)
   + k^2\,(v_\beta\,\Delta l_1 + L_0)^2}\right),

and :math:`EA_D = \alpha_\text{MBL}` for :math:`\Delta l_1 \le 0`. It is evaluated from the
committed state and held over the step. Parameter sets with :math:`EA_D \le EA`, a stiffness
condition :math:`(EA_D + EA)/(EA_D - EA) > 10^3`, negative dashpots, or :math:`BA_D + BA_s = 0`
fail closed. The viscoelastic law applies to ``EI = 0`` lines.

Syrope polyester model
~~~~~~~~~~~~~~~~~~~~~~

The Syrope model (:ref:`Falkenberg, Åhjem & Yang, 2017 <ref-falkenberg2017>`), in its
MoorDyn-F/C form, describes polyester from an **original working curve** (OWC), a
strain–tension table :math:`\varepsilon_\text{owc}(T)`. The strain is split into a fast part
with the load-dependent stiffness

.. math::

   \varepsilon_\text{fast}(T) = \frac{1}{\beta}\ln\!\left(1 + \frac{\beta}{\alpha}\,T\right),
   \qquad \frac{\mathrm{d}T}{\mathrm{d}\varepsilon_\text{fast}} = EA_d = \alpha + \beta\,T,

and a slow part :math:`\varepsilon_\text{slow} = \varepsilon_\text{curve}(T) - \varepsilon_\text{fast}(T)`,
where :math:`\varepsilon_\text{curve}` is the active curve (the OWC or the working curve below).
:math:`T_\text{curve}(\varepsilon_\text{slow})` denotes the inverse of this slow-strain relation:
the mean tension at which the active curve has the slow strain :math:`\varepsilon_\text{slow}`.
Loading beyond the running maximum mean tension :math:`T_\text{max}` follows the OWC. Below it
the line follows a **working curve** regenerated from :math:`T_\text{max}` with 30 samples
between :math:`\varepsilon_\text{min}` and :math:`\varepsilon_\text{max} = \varepsilon_\text{owc}(T_\text{max})`,
of linear, quadratic, or exponential shape; for :math:`x \in [0, 1]` along the curve the
tension is :math:`T_\text{max}x`, :math:`T_\text{max}x\,(p_2 x + 1 - p_2)`, or
:math:`T_\text{max}(1 - e^{p_2 x})/(1 - e^{p_2})`, with
:math:`\varepsilon_\text{min} = \varepsilon_0 + p_1(\varepsilon_\text{max} - \varepsilon_0)`
(or :math:`\varepsilon_\text{max} - T_\text{max}/p_1` for the linear form with :math:`p_1 \ge 1`).
The shape parameters are the settings-file keys, :math:`p_1 = k_1` and :math:`p_2 = k_2`. The
accepted ranges are :math:`k_1 \ge 0` for the linear shape, :math:`0 \le k_1 < 1` and
:math:`0 < k_2 \le 1` for the quadratic shape, and :math:`0 \le k_1 < 1` and
:math:`10^{-6} \le k_2 \le 700` for the exponential shape (beyond 700 the exponential
overflows; below :math:`10^{-6}` the ratio loses its digits to cancellation).

Each element carries two states: the slow strain :math:`\varepsilon_\text{slow}` and
:math:`T_\text{max}`. With :math:`T_\text{mean} = T_\text{curve}(\varepsilon_\text{slow})`,
:math:`K_1 = \alpha + \beta\,T_\text{mean}`, and ``BA = BA_s|BA_d``,

.. math::

   \dot\varepsilon_\text{slow} =
   \frac{K_1\,\bigl(\varepsilon - \varepsilon_\text{curve}(T_\text{mean})\bigr) + BA_d\,\dot\varepsilon}
        {BA_s + BA_d},
   \qquad
   T = T_\text{mean} + BA_s\,\dot\varepsilon_\text{slow}.

A compressed segment (:math:`\varepsilon < 0`) carries no mean tension, only
:math:`BA_s\,\dot\varepsilon_\text{slow}`, and a tension-only line clamps a negative result
to zero.

The slow strain is eliminated implicitly in every in-step evaluation: a projected, bracketed
backward-Euler solve,
:math:`\varepsilon_\text{slow}^{n+1} = \varepsilon_\text{slow}^{n} + \Delta t\,\dot\varepsilon_\text{slow}(\varepsilon_\text{slow}^{n+1}, \varepsilon, \dot\varepsilon)`
constrained to :math:`\varepsilon_\text{slow} \ge 0`, gives the slow strain that the force
uses (safeguarded Newton steps, finished by bisection where they stall next to a kink of the
interpolated curves, as at the top of the working curve; a residual so steep that it changes
sign between two adjacent reals gives the root to machine precision). The tangent carries :math:`\partial\varepsilon_\text{slow}^{n+1}/\partial(\varepsilon, \dot\varepsilon)`
from the implicit-function theorem. The step commits that same slow strain, so the force applied
to the nodes equals the reported tension. The working curve is the one regenerated at the
committed :math:`T_\text{max}`. The branch follows the evaluated slow strain: the working curve
applies below the OWC slow strain at :math:`T_\text{max}`, and the OWC applies at or above it,
so the recovered mean tension is continuous across the switch. :math:`T_\text{max}` then
ratchets and regenerates the working curve when the mean tension exceeds it.

**Initial condition.** The static solve uses the rest curve of the initial load history: the
OWC for a virgin rope, or, with ``SYROPE IC``, the working curve regenerated at
:math:`T_\text{max,0}` (zero tension below its zero-tension strain, the OWC above its top
strain :math:`\varepsilon_\text{OWC}(T_\text{max,0})`). Each element's secant axial stiffness of
that curve is iterated to the curve's strain at its solved tension, the line otherwise built as
any ``EI = 0`` line
(its drag in a deck current included). Each element then starts with the running maximum
:math:`\max(T_\text{max,0}, T_e)` (:math:`T_e` for a virgin rope), where :math:`T_e` is its
static tension, and with the slow strain whose kernel tension at the static strain and zero
strain rate equals :math:`T_e`. The dynamic state therefore starts in the static equilibrium,
with no initial transient: every element's static strain lies on the rest curve, where that slow
strain is the curve's rest point. (With one secant for a whole section, an element away from the
mean tension sat off the curve and its slow strain crept at :math:`(T_e - T_\text{mean})/BA_s`.) With fixed line ends the mean tension follows from the
geometry and :math:`T_\text{max,0}`, so :math:`T_\text{mean,0}` does not enter the state. A
value that differs from the static mean tension by more than 1 % is reported on the console.
A strain below the working curve's zero-tension strain (a slack rope on that history) stops at
initialisation.

The OWC table must cover the motion. An initial strain outside the table, or a state that
leaves it (a slow strain above the last row's, or a total strain above the last table strain on
the OWC branch), stops with an error rather than extrapolating. The slow strain is well defined
only while the fast spring is stiffer than the working curve: its slope must stay below
:math:`\alpha + \beta T` along the whole curve. For a given table and constants this holds
only for some running maxima. For example, the shipped EXP example constants
(:math:`\alpha = 1.53\times10^8` N, :math:`\beta = 23.12`, :math:`k_1 = 0.2`, :math:`k_2 = 1.5`)
need :math:`T_\text{max} \gtrsim 7.4\times10^5` N. Initialisation scans the table range. A
pretension or ``Tmax0`` outside the admissible range is reported with the offending tension and
the next admissible :math:`T_\text{max}`.

An optional ``SYROPE IC`` row supplies the prior history
:math:`(T_\text{max,0}, T_\text{mean,0})`; see the initial condition above. The model applies
to single-section ``EI = 0`` taut lines, which take the seabed, the Morison loads below, current,
waves, a host's fluid field and VIV as any ``EI = 0`` line does (MoorDyn's line hydrodynamics); see
:doc:`capabilities` for the supported combinations.

Hydrodynamic loads
------------------

Fluid loads follow the Morison equation (:ref:`Morison et al., 1950 <ref-morison1950>`),
decomposed into components normal and tangential to the local unit tangent :math:`\mathbf{t}`.
Reference areas and coefficient names are listed in :doc:`conventions`; :math:`d` is the
hydrodynamic diameter and :math:`A = \pi d^2/4`.

Drag
~~~~

With the relative velocity :math:`\mathbf{u}_r = \mathbf{u}_f - \mathbf{v}` split into
:math:`\mathbf{u}_{r,t} = (\mathbf{u}_r\cdot\mathbf{t})\,\mathbf{t}` and
:math:`\mathbf{u}_{r,n} = \mathbf{u}_r - \mathbf{u}_{r,t}`, the drag per unit length is

.. math::

   \mathbf{f}_D = \tfrac{1}{2}\rho\,d\,C_{d,n}\,\lvert\mathbf{u}_{r,n}\rvert\,\mathbf{u}_{r,n}
                + \tfrac{1}{2}\rho\,\pi d\,C_{d,t}\,\lvert\mathbf{u}_{r,t}\rvert\,\mathbf{u}_{r,t}.

Its derivatives with respect to position (through :math:`\mathbf{t}`) and velocity enter the
implicit tangent exactly. The length is the element's unstretched length :math:`L_0` on the
``EI = 0`` path (with the chord tangent and the wet-weighted relative velocity) and
the deformed length :math:`\lvert\mathbf r_{,\xi}\rvert\,\mathrm{d}\xi` of the cubic centreline
on the Hermite path (three Gauss points per element). At rest in a current the end reactions
(``FairTen``/``AnchTen``, ``Point<P>F``) balance the weight and this drag to the static
tolerance, about :math:`10^{-8}` of the end force, pinned or clamped ends alike. A check of the
balance must integrate the drag the same way: on straight chords between the nodes of a
finite-EI line it misses by a share that falls with the square of the element length
(:math:`3\times10^{-5}` of the end force on 1.25 m elements of a cable in a 1 m/s current,
:math:`4.5\times10^{-4}` on 5 m elements), and per unstretched length by about the axial strain
times the drag.

Added mass and fluid inertia
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The added-mass matrix per unit length and the Froude–Krylov plus fluid-inertia force for a
fluid acceleration :math:`\dot{\mathbf{u}}_f = \dot{\mathbf{u}}_{f,n} + \dot{\mathbf{u}}_{f,t}` are

.. math::

   \mathbf{m}_a = \rho A\left[C_{a,n}\left(\mathbf{I} - \mathbf{t}\mathbf{t}^{\mathsf T}\right)
                + C_{a,t}\,\mathbf{t}\mathbf{t}^{\mathsf T}\right],
   \qquad
   \mathbf{f}_I = \rho A\left[(1 + C_{a,n})\,\dot{\mathbf{u}}_{f,n} + (1 + C_{a,t})\,\dot{\mathbf{u}}_{f,t}\right].

The fluid acceleration is the local (Eulerian) acceleration of the wave field.

.. _theory-viv:

Cross-flow vortex-induced vibration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Lines can carry the cross-flow lift of the synchronisation model of
:ref:`Thorsen et al. (2014) <ref-thorsen2014>` and :ref:`(2016) <ref-thorsen2016>` in the form
MoorDyn v2 implements it: a LINE TYPES row with a lift coefficient :math:`C_L > 0` (see
:doc:`file_formats`). On an ``EI = 0`` line, at an interior node with unit tangent :math:`\mathbf{q}` (the chord of its
neighbours) and normal relative flow :math:`\mathbf{v}_n` of speed :math:`U = \lvert\mathbf{v}_n\rvert`,
each node carries a vortex-shedding phase :math:`\phi` and the lift

.. math::

   \mathbf{F}_L = \tfrac{1}{4}\rho\,d\,C_L\,(l_{i} + l_{i+1})\,U\cos\phi\;\mathbf{q}\times\mathbf{v}_n ,

the per-length :math:`\tfrac{1}{2}\rho d C_L U^2\cos\phi` over the node's half elements (wetted
fraction included). The phase follows the cross-flow motion
:math:`\dot y = \dot{\mathbf{r}}\cdot\mathbf{e}`, :math:`\ddot y = \ddot{\mathbf{r}}\cdot\mathbf{e}`
along :math:`\mathbf{e} = \mathbf{q}\times\mathbf{v}_n/U`:

.. math::

   \dot\phi = 2\pi\,\hat f\,\frac{U}{d}, \qquad
   \hat f = c_F + d_F \sin(\phi_{\dot y} - \phi), \qquad
   \phi_{\dot y} = \operatorname{atan2}\!\left(-\frac{\ddot y}{\ddot y_\text{rms}},\,
                   \frac{\dot y}{\dot y_\text{rms}}\right),

so the shedding frequency locks onto the cross-flow motion inside the band
:math:`c_F \pm d_F` (MoorDyn's defaults 0.18 and 0.08). The running RMS values average over
``VIVrmsWindow`` seconds, by default 500 steps of ``dtM`` as in MoorDyn, and the phases start at
:math:`2\pi i/N` at node :math:`i` counted from the deck's End A (MoorDyn's ``AttachA``), also on
a line written anchor first, which the reader turns around. The node tangent
:math:`\mathbf{q}` runs from End A to End B, as MoorDyn's; turning it around turns the lift and
:math:`\mathbf{e}` around and starts the same motion from the phases plus :math:`\pi`, with
:math:`\phi_{\dot y} = \pi` instead of MoorDyn's 0 at a node with no cross-flow motion (a node at
rest, a held end of a finite-EI cable), so the lift field is MoorDyn's whichever end a deck writes
first. On a finite-EI mesh the static solve
refined, the deck nodes keep that seed and the nodes it added take the seed interpolated in
arc length. The static equilibrium carries no lift.

The seed decides which response the line settles on where two lock-in branches coexist. On the
taut line of the ``viv_lockin`` test, between about 0.21 and 0.33 m/s, a line locked in its first
mode at 0.18 m/s stays there as the current rises, while one coming down from 0.30 m/s stays in
its second mode, and a start from rest with the spread seed settles in the second mode, as
MoorDyn-C does. MoorDyn-F (v2.3.8, OpenFAST v5.0.0) sets the same seed but does not copy it into
the state vector it integrates, so its phases start at zero at every node: a uniform lift that
excites the symmetric modes only, after which the line stays in its first mode. ``zero
VIVphaseSeed`` starts every phase at zero, and reproduces that start (:doc:`options`).

In the implicit step the phase is explicit: the step's lift takes the phase predicted at
:math:`t_{n+1}` from the step-start rate (the generalised-α level under the configuration blend),
and the committed phase is the trapezoidal (Heun) update with the rate at the converged end
state. The lift's position and velocity derivatives enter the tangent. The cross-flow motion of
the phase and the velocity in the lift are the node values averaged with the neighbours,
:math:`(\mathbf{x}_{i-1} + 2\mathbf{x}_i + \mathbf{x}_{i+1})/4`. That keeps a resolved mode of
wavenumber :math:`k` to :math:`\cos^2(k l_0/2)` and removes the mesh-scale zig-zag mode exactly.
With the node's own kinematics, a step that resolves the zig-zag mode lets the synchronisation
loop pump it until the line loses lock-in; a coarse step only hides this behind the
integrator's numerical damping.

On a finite-EI (cubic-Hermite) cable the lift is a distributed load per unit deformed length,

.. math::

   \mathbf{f}_L = \tfrac{1}{2}\rho\,d\,C_L\cos\phi\;U\;\mathbf{t}\times\mathbf{v}_r ,

with :math:`\mathbf{t}` the unit tangent of the centreline, :math:`\mathbf{v}_r` the relative flow
(its normal part has speed :math:`U`) and :math:`\cos\phi` interpolated linearly between the
element's end nodes. It is integrated against the Hermite shape functions at the three Gauss
points of the drag (a point above the surface carries none), and its exact position and
velocity derivatives enter the tangent. Each node carries a phase, driven as above by the
node's cross-flow motion along its own tangent, the slope degrees of freedom; :math:`d`,
:math:`c_F` and :math:`d_F` at a node are the length-weighted averages over its lifting
elements. The phase is explicit with the Heun commit as on ``EI = 0`` lines, and no smoothing is
needed: the Hermite tangent and the integrated lift leave no mesh-scale mode for the loop to
pump, and the response is the same from ``dtM`` 5e-4 to 1e-2 s. A finite-EI line with
:math:`EI \to 0` reproduces the ``EI = 0`` line's lock-in. The standalone Hermite march
and the multibody march (a cable on a body or rod, or beside free points) carry it, including
deck waves and current through the held fluid field, on a line with one or two moving ends.

VIV runs on every route that carries the line: the standalone driver, the coupled OpenFAST
and FAST.Farm routes and the standalone runner of a mixed ``EI = 0`` / finite-EI deck. On the
coupled routes the phase follows the host's fluid field (a SeaState current or waves), and the
phases, the running mean squares and the averaging time are part of the checkpoint state, so a
restart continues the uninterrupted run bit for bit. The OpenFAST correction iterations rewind
them with the rest of the state.

.. _theory-dry-buoyancy:

Buoyancy and wetting
~~~~~~~~~~~~~~~~~~~~

Self-weight and buoyancy enter as the submerged weight per unstretched metre,
:math:`w = (\rho_A - \rho A)\,g` (positive downward). An ``EQUIVALENT BUOYANCY`` row specifies
:math:`w` and :math:`d` directly and is converted to :math:`\rho_A = w/g + \rho A`.

On the ``EI = 0`` path, an element crossing the free surface uses its wetted fraction
:math:`f`, the linear-interpolation fraction of the chord below the local surface elevation.
Drag, added mass, and fluid inertia act on the wetted part (drag with the wet-weighted relative
velocity), and a recovery load :math:`-(1 - f)\,\tfrac{1}{2}\rho A g L_0` on each end node removes
the buoyancy of the dry part; the derivatives of :math:`f` with respect to the nodal heights are
included in the tangent. On the Hermite path the hydrodynamic loads are integrated over the
deformed element length at three Gauss points, and a Gauss point above the local surface
carries no load. This is exact for fully submerged elements, the regime of lazy-wave cables and
moorings, and approximates the wetted length of a surface-piercing element by the Gauss
sampling. The Hermite buoyancy recovery is exact: the waterline crossings of the cubic
centreline height are located on each element, and the load :math:`\rho g A` is integrated in
closed form against the Hermite shape functions over the dry intervals,

.. math::

   \mathbf{f}_{z} = \rho g A \int_\text{dry} \mathbf{N}^{\mathsf T}\,\mathrm{d}s,
   \qquad
   \frac{\partial \mathbf{f}_{z}}{\partial \mathbf{q}_{z}} = \rho g A\,L_0 \sum_{c}
   \frac{\mathbf{N}(\xi_c)\,\mathbf{N}(\xi_c)^{\mathsf T}}{\lvert z'(\xi_c)\rvert},

where :math:`\xi_c` are the crossings and :math:`z' = \mathrm{d}z/\mathrm{d}\xi`; the tangent is
the exact rate at which the crossings move. The surface is the still waterline of the drag
configuration, or the element's sampled elevation with a host-held field. The Hermite static
solve uses the same recovery at the deck waterline, :math:`z = 0`.

The EI = 0 path assembles the added mass at the current configuration, with its
configuration derivative in the tangent. The Hermite path evaluates the consistent added mass
:math:`\int \mathbf{N}^{\mathsf T}\mathbf{m}_a\mathbf{N}\,\mathrm{d}s` at the start of each step and
holds it over the step. The spatial gradient of the wave field is omitted from the tangent on
both paths; the residual is exact, so the converged state is unaffected.

.. _theory-waves:

Waves
~~~~~

Regular waves use linear (Airy) theory (:ref:`Dean & Dalrymple, 1991 <ref-dean1991>`). For
height :math:`H`, period :math:`T`, water depth :math:`h`, and direction :math:`\beta` (the
direction of travel, see :doc:`conventions`), the wavenumber solves the dispersion relation

.. math::

   \omega^2 = g\,k\tanh(k h), \qquad \omega = 2\pi/T,

by monotone bisection in :math:`kh` to a relative interval of :math:`10^{-15}`. With
:math:`\theta = k(x\cos\beta + y\sin\beta) - \omega t`,

.. math::

   \eta = \tfrac{H}{2}\cos\theta, \qquad
   u_h = \tfrac{H}{2}\,\omega\,\frac{\cosh k(z' + h)}{\sinh kh}\cos\theta, \qquad
   u_z = \tfrac{H}{2}\,\omega\,\frac{\sinh k(z' + h)}{\sinh kh}\sin\theta,

where :math:`u_h` acts along :math:`(\cos\beta, \sin\beta, 0)`. The accelerations are the time
derivatives at a fixed point, :math:`\dot u_h = \tfrac{H}{2}\omega^2 \frac{\cosh k(z'+h)}{\sinh kh}\sin\theta`
and :math:`\dot u_z = -\tfrac{H}{2}\omega^2 \frac{\sinh k(z'+h)}{\sinh kh}\cos\theta`. The
vertical velocity is exactly zero at the bed.

**Wheeler stretching** (:ref:`Wheeler, 1970 <ref-wheeler1970>`) evaluates the kinematics at the
stretched coordinate

.. math::

   z' = (z - \eta)\,\frac{h}{h + \eta},

which maps :math:`[-h, \eta]` onto :math:`[-h, 0]`; points above the instantaneous surface
receive zero kinematics. The mapping is undefined when the trough reaches the bed
(:math:`h + \eta \le 0`); that state fails closed with a named error. Without stretching,
:math:`z' = z`.

**Irregular waves** are long-crested sums of Airy components,
:math:`\eta = \sum_i a_i\cos\theta_i`, with :math:`\theta_i = k_i(x\cos\beta + y\sin\beta) - \omega_i t + \phi_i`.
The total elevation is summed first and one Wheeler mapping against that total is applied to
every component. The built-in JONSWAP spectrum (:ref:`Hasselmann et al., 1973 <ref-hasselmann1973>`)
is discretised as follows:

- 200 equal frequency bins on :math:`[0.2\,\omega_p,\ 5\,\omega_p]`, with
  :math:`\omega_p = 2\pi/T_p` and bin width :math:`\Delta\omega = 4.8\,\omega_p/200`; component
  :math:`i` sits at :math:`\omega_i = 0.2\,\omega_p + (i - 1 + u_i)\,\Delta\omega` with
  :math:`u_i` uniform on :math:`(0, 1)`;
- spectral shape
  :math:`S(\omega) \propto \omega^{-5}\exp\!\left[-\tfrac{5}{4}(\omega_p/\omega)^4\right]\gamma^{r}`,
  :math:`r = \exp\!\left[-(\omega/\omega_p - 1)^2/(2\sigma^2)\right]`, with
  :math:`\sigma = 0.07` for :math:`\omega \le \omega_p` and :math:`0.09` above, :math:`\gamma \ge 1`;
- amplitudes :math:`a_i = \sqrt{2 S(\omega_i)\,\Delta\omega}`, with :math:`S` scaled so that the
  discrete zeroth moment is :math:`m_0 = H_s^2/16`;
- phases :math:`\phi_i = 2\pi v_i` with :math:`v_i` uniform on :math:`(0, 1)`.

The draws :math:`u_i, v_i` come from the ``WaveSeed`` option (default 1) through the
Park–Miller MINSTD generator (multiplier 48271, modulus :math:`2^{31} - 1`), so a given
:math:`(H_s, T_p, \gamma, \beta)` and seed always produce the same sea on every platform, and
different seeds give independent realisations. Because the component frequencies are not
commensurate, the record does not repeat (an equally spaced comb would repeat after
:math:`2\pi/\Delta\omega \approx 42\,T_p`). To reproduce a specific external realisation, supply
its component table (amplitude, frequency, phase), for example a WaterKin ``WaveKinMod`` 1
elevation history, which is reduced once to its Fourier components on the run time base.

The phase of a component of an elevation history or a ``WaveKin 7`` table is

.. math::

   \theta_i = k_i\big[(x - x_r)\cos\beta_i + (y - y_r)\sin\beta_i\big] - \omega_i t + \phi_i,

with :math:`(x_r, y_r)` the ``WaveRefX``, ``WaveRefY`` point where the record was measured, the
origin by default. The sea of a record referred to a point is therefore the same sea with the
deck translated, and a vessel RAO takes the vessel's position relative to that point. A history
has one direction :math:`\beta_i = \beta`. The rows of a ``WaveKin 7`` table may each have
their own: a short-crested sea, whose elevation and kinematics are the sums of those of its
directions, stretched by the one total elevation.

The mean :math:`\bar\eta` of an elevation history, or the ``omega = 0`` row of a ``WaveKin 7``
table, is a steady level. A WaterKin history raises the still-water level by it: the wave numbers
are those of the depth :math:`h + \bar\eta`, and the stretching maps the water column under the
raised level. A MoorDyn-C file (``WaveKin 3`` or ``7``) adds it to the elevation alone, as
MoorDyn-C does: the wave numbers stay those of :math:`h`, and the stretching maps
:math:`[-h,\ \bar\eta + \eta]` onto :math:`[-h,\ 0]`.

Every point sums every component of the elevation. The sums run in interleaved partial sums
added up in a fixed order, so a result does not depend on the vector width or the thread
count, and each point is a function of its position and time alone: nothing carries from one
step to the next. The velocity, acceleration and dynamic pressure sums run in order of
increasing :math:`k_i`. For :math:`-h \le z' \le 0` both depth
ratios :math:`\cosh k(z' + h)/\sinh kh` and :math:`\sinh k(z' + h)/\sinh kh` fall as
:math:`k` grows, so the cosh ratio of the last summed component times the remaining
:math:`\sum_{j \ge i} a_j\omega_j`, :math:`\sum a_j\omega_j^2` and :math:`\sum a_j\omega_j^2/k_j`
bounds the rest of each sum. The sums stop once those bounds are below half an ulp of the
magnitudes already summed. A deep point therefore skips the short components that have
decayed to nothing there, and the result changes at round-off only. This matters for an
elevation history, which keeps its components up to the ``WvHiCOff`` cut-off (0.5 Hz by
default) or, with ``none``, all :math:`T_{max}/(2\,\Delta t_{wave})` of them up to the Nyquist
frequency of ``dtWave``.

**Regular nonlinear waves.** A ``stream`` wave is Dean's stream-function wave
(:ref:`Dean, 1965 <ref-dean1965>`) solved numerically by the Fourier method of
:ref:`Rienecker & Fenton (1981) <ref-rienecker1981>`. In the frame moving with the celerity
:math:`c`, with :math:`X = x' - ct` and :math:`Y = z + h` measured from the bed,

.. math::

   \psi(X, Y) = -\bar U Y + \sum_{j=1}^{N} B_j\,\frac{\sinh jkY}{\cosh jkh}\cos jkX,

and :math:`k`, the surface elevations :math:`\eta_m` at :math:`X_m = m\pi/(Nk)`
(:math:`m = 0 \ldots N`, crest to trough), :math:`B_j`, :math:`\bar U`, :math:`Q` and
:math:`R` satisfy the kinematic condition :math:`\psi(X_m, h + \eta_m) = -Q` and the Bernoulli
condition :math:`\tfrac12\lvert\nabla\psi\rvert^2 + g\eta_m = R` on the surface, a zero mean
level, :math:`\eta_0 - \eta_N = H`, and :math:`k\bar U T = 2\pi` (no Eulerian mean current,
:math:`c = \bar U`). Newton's method solves the :math:`2N + 5` equations in units of
:math:`h` and :math:`g`, stepping the height up from a linear wave; ``StreamOrder`` sets
:math:`N` (default 20). The fixed-frame velocity is
:math:`u = \sum jkB_j \cosh(jkY)/\cosh(jkh)\cos jkX`,
:math:`w = \sum jkB_j \sinh(jkY)/\cosh(jkh)\sin jkX`, the local acceleration
:math:`-c\,\partial/\partial X` of these, the surface elevation the cosine interpolant of the
:math:`\eta_m`, and the dynamic pressure :math:`p/\rho + gz = R - \tfrac12\lvert\nabla\psi\rvert^2`.
The field is exact up to the free surface, so no stretching is applied; points above the
surface see still water, and the start-up ramp scales the whole field. Airy and irregular
seas keep the Wheeler stretching above.

**Other spectra, spreading and multiple trains.** Besides JONSWAP, a spectral train can be
ISSC / Pierson–Moskowitz (Bretschneider, :ref:`Pierson & Moskowitz, 1964 <ref-pierson1964>`),
Torsethaugen two-peak (:ref:`Torsethaugen & Haver, 2004 <ref-torsethaugen2004>`), or
Ochi–Hubble two-peak (:ref:`Ochi & Hubble, 1976 <ref-ochi1976>`). With
:math:`\omega_p = 2\pi/T_p`, the one-sided densities are

.. math::

   S_{PM}(\omega) = \tfrac{5}{16} H_s^2 \omega_p^4 \omega^{-5}
   \exp\!\left[-\tfrac{5}{4}(\omega_p/\omega)^4\right],\qquad
   S_{J} = (1 - 0.287\ln\gamma)\,S_{PM}\,\gamma^{r},

   S_{OH}(\omega) = \frac{1}{4}\sum_{j=1}^{2}
   \frac{\left(\tfrac{4\lambda_j + 1}{4}\omega_{pj}^4\right)^{\lambda_j}}{\Gamma(\lambda_j)}
   \frac{H_{sj}^2}{\omega^{4\lambda_j + 1}}
   \exp\!\left[-\tfrac{4\lambda_j + 1}{4}(\omega_{pj}/\omega)^4\right].

The Torsethaugen sea follows DNV-RP-C205 (:ref:`DNV, 2021 <ref-dnvc205>`): with
:math:`T_f = 6.6\,H_s^{1/3}`, a wind-dominated sea (:math:`T_p \le T_f`) has the primary
wind sea :math:`H_1 = r H_s`, :math:`r = 0.7 + 0.3\exp[-(2\epsilon_l)^2]`,
:math:`\epsilon_l = (T_f - T_p)/(T_f - 2\sqrt{H_s})`,
:math:`\gamma_1 = 35\,(2\pi H_1/g T_p^2)^{0.857}`, and a swell of
:math:`H_2 = \sqrt{1 - r^2}\,H_s` at :math:`T_{p2} = T_f + 2` s; a swell-dominated sea has
:math:`r = 0.6 + 0.4\exp[-(\epsilon_u/0.3)^2]`, :math:`\epsilon_u = (T_p - T_f)/(25 - T_f)`,
:math:`\gamma_1 = 35\,(2\pi H_s/g T_f^2)^{0.857}(1 + 6\epsilon_u)` and a wind sea at
:math:`T_{p2} = 6.6\,H_2^{1/3}` (:math:`\epsilon` clamped to [0, 1], :math:`\gamma_1 \ge 1`,
:math:`\gamma_2 = 1`). Each partition is
:math:`E_j G_0 A_{\gamma} \tilde\omega^{-4}\exp(-\tilde\omega^{-4})\gamma_j^{r}` with
:math:`\tilde\omega = \omega T_{pj}/2\pi`, :math:`E_j = H_j^2 T_{pj}/(32\pi)`,
:math:`G_0 = 3.26` and :math:`A_\gamma = (1 + 1.1(\ln\gamma)^{1.19})/\gamma`.

A spectral train is synthesised like the JONSWAP sea: ``WaveComponents`` (default 200) jittered
components over :math:`[0.2\,\omega_{p,\min}, 5\,\omega_{p,\max}]` of its partition peaks,
random phases, and amplitudes scaled so the train's discrete :math:`m_0` is exactly
:math:`H_s^2/16` (:math:`(H_{s1}^2 + H_{s2}^2)/16` for Ochi–Hubble). A train with a spreading
exponent :math:`s > 0` spreads its energy with the cos-2s function

.. math::

   D(\theta) = K(s)\cos^{2s}(\theta - \theta_p),\quad |\theta - \theta_p| \le \pi/2,\qquad
   K(s) = \frac{\Gamma(s + 1)}{\sqrt{\pi}\,\Gamma(s + 1/2)},

discretised into ``WaveDirections`` (default 9) equal-angle bins whose weights are the bin
integrals of :math:`D`; each direction has its own jittered frequency set, and component
:math:`i` travels along its own heading :math:`\beta_i`. Several trains (``wavetrain`` rows) are
superposed component by component, each with its own heading and seed offset, and the
kinematics of the whole sea follow the irregular-wave conventions above: the total elevation
first, one Wheeler mapping against it, then the component sums. A long-crested JONSWAP train
reproduces the JONSWAP synthesis above for the same seed.

The optional ``rampTime`` :math:`T_r` multiplies every wave amplitude by
:math:`r(t) = \tfrac{1}{2}\left[1 - \cos(\pi t/T_r)\right]` for :math:`t < T_r`; the fluid
acceleration then includes the ramp rate, :math:`r\,\dot{\mathbf u} + \dot r\,\mathbf u`. The
current is not ramped, because the static initial condition already includes it.

Currents
~~~~~~~~

A current is uniform or given as a profile of :math:`N \ge 2` levels
:math:`(z_j, \mathbf{u}_j)` with strictly increasing :math:`z_j`. The velocity is interpolated
linearly between levels and held at the end values outside the profile. A WaterKin
``CurrentMod`` 1 depth table uses the same interpolation. In OpenFAST (maintained by NLR, the National Laboratory of the
Rockies, formerly NREL), the SeaState field supplies waves and current; SeaState's standard ``CurrMod = 1`` steady current (sub-surface
power law :math:`U_{ss}\,[(z + h)/h]^{1/7}`, linear near-surface profile, and depth-independent
part) is reproduced so that wave and current contributions can be separated when a WaterKin
file selects them independently. ``CurrMod = 2`` user currents cannot be separated and are
rejected whenever separation is required.

The fluid velocity seen by the drag is the sum of the current and the wave velocity. In a
coupled run the fluid velocity, acceleration, and local surface elevation are sampled by the
host at the nodes and held over the step.

Seabed contact
--------------

Contact acts at the line nodes on the translational DOFs. With the penetration
:math:`g = z_\text{floor}(x, y) - z` and the nodal stiffness :math:`k_n` (:doc:`conventions`),
the normal force is a :math:`C^1` penalty law with blend width :math:`\delta = 10^{-6}\,\mathrm{m}`:

.. math::

   f_n^{(k)}(g) =
   \begin{cases}
     0, & g \le -\delta, \\[2pt]
     k_n\,\dfrac{(g + \delta)^2}{4\delta}, & -\delta < g < \delta, \\[6pt]
     k_n\,g, & g \ge \delta .
   \end{cases}

The force and its tangent are continuous through first contact, which avoids an active-set
kink in Newton's method; beyond the blend the law is exactly linear. A normal damper acts only
while the node moves into the bed,

.. math::

   f_n^{(c)} = -c_n\,\chi(g)\,\min(v_z, 0),

where :math:`\chi` rises linearly from 0 to 1 across the blend. With the total normal reaction
:math:`N = f_n^{(k)} + f_n^{(c)}`, seabed friction is a stick-slip spring on the horizontal
motion of every node, on the ``EI = 0`` and the finite-EI lines alike. Node :math:`i` holds a
horizontal spring of stiffness :math:`k_i`, the nodal normal contact stiffness (the shear
stiffness equals the normal stiffness, OrcaFlex's default), to its anchor
:math:`\mathbf{a}_i`. With :math:`\mathbf{d} = \mathbf{x}_i - \mathbf{a}_i` the horizontal
stretch, the spring sticks and slides:

.. math::

   \mathbf{f}_t = \begin{cases} -k_i\,\mathbf{d}, & k_i\lvert\mathbf{d}\rvert \le \mu N,\\
   -\mu N\,\mathbf{d}/\lvert\mathbf{d}\rvert, & \text{otherwise},\end{cases}

and at every committed state a sliding spring's anchor moves to the capacity distance behind
the node (return mapping), so the force carries over exactly into the next step; a node that
leaves the seabed takes its anchor with it. The anchors are state: they roll back with a
failed or subdivided step, join the aggregate snapshot, and are part of the OpenFAST
checkpoint. The force and its position and velocity Jacobians (through :math:`N`) are exact.
Unlike a velocity-regularised Coulomb law, the spring holds its force at rest.

**Mesh resolution.** Because friction acts at the nodes, the tension along the laid part changes
in steps of up to :math:`\mu w L` (:math:`w` the submerged weight per length, :math:`L` the
element length) instead of continuously, and as the line lands and lifts at touchdown each node
locks or releases that much. On a coarse grounded mesh the tension of the laid part and near
touchdown then swings in time by about that amount. On a 600 m lazy-wave cable in 200 m of
water (:math:`\mu = 0.35`) the standard deviation of a grounded segment tension was 491, 136, 42
and 33 N with 10, 5, 2.5 and 1 m elements, where :math:`\mu w L` is 46, 22, 11 and 4.5 % of the
touchdown tension. When a finite-EI line's grounded elements exceed 15 %, the initialisation
report notes it with the grounded element length that resolves it.

.. _static-friction:

**Friction in statics.** With seabed friction a static equilibrium is not unique: a grounded
run can rest anywhere its friction holds it. Like OrcaFlex, CableDyn resolves this by assuming
the position in which the line was originally laid and letting friction act toward it.
OrcaFlex (Orcina's documentation, *Line data: statics*,
https://www.orcina.com/webhelp/OrcaFlex/Content/html/Linedata,Statics.htm, and *Friction
theory*, https://www.orcina.com/webhelp/OrcaFlex/Content/html/Frictiontheory.htm) offers the
statics seabed friction policies *none*, *as laid* and *restart*. As laid, with a step 1
statics method other than *prescribed*, the line is assumed laid starting with its bottom end
at its position, in the *lay azimuth* direction away from it, following the seabed profile, and
its top end then moved slowly to its position; the friction targets are spaced along the
seabed by the unstretched segment lengths and the *as laid tension*, so a line with every node
on its target carries that tension throughout. Friction applies in statics only to line-seabed
contact and only when the policy is not *none*; each node's force acts toward its target and
is capped at :math:`\mu R`, and dynamics then starts from the target positions of statics.
OrcaFlex warns that a lay azimuth far from the vertical plane through the line ends makes the
statics harder to converge. The documentation consulted does not state the defaults of these
three data items.

CableDyn implements the *as laid* and *none* policies (``staticsFriction``; *restart* has no
counterpart, and there is no prescribed starting shape). *None* is the default, as in MoorDyn:
the static solve is frictionless in still water, and in a deck current the friction springs
below hold the line from its still-water equilibrium (the same line solved without the current
first). It is conservative for anchor loads, since an as-laid run pulled taut is held back by
its friction (below). With ``asLaid`` the reference of
node :math:`i` is the as-laid position: the line is laid from its lower end (the anchor, or the
fairlead when that is lower) along the azimuth :math:`\alpha` away from it (``layAzimuth``; by
default the horizontal direction of the chord from that end, the vertical plane through the
line ends) on the seabed at the tension :math:`T_\text{laid}` (``asLaidTension``, default 0),
so that the seabed path from that end to node :math:`i` is :math:`s_i = \sum_{e<i} l_{0,e}(1 + T_\text{laid}/EA_e)` long; on a
bathymetry the horizontal distance follows from integrating
:math:`\mathrm{d}s = \sqrt{1 + z_{,\alpha}^2}\,\mathrm{d}d` in sub-steps of at most 1 m. A
laid node sinks into the penalty seabed along its normal by its static penetration, which on a
slope moves it horizontally by :math:`w_i\,(z_{,x}, z_{,y})/k_i`, with :math:`w_i` its nodal
load: its share of the line's submerged weight, plus the net weight of a discrete attachment
lumped at it (the finite-EI solve first smears an attachment over the two elements at its
node, then rebuilds the reference for the discrete loads before it polishes to them). It is the
normal load the solver applies to the node resting at its laid position: a finite-EI section
that lies within its radius of the still-water level there (a seabed shallower than the cable
radius) carries the buoyancy of its dry part, as in the static solve and the dynamics
(:ref:`buoyancy recovery <theory-dry-buoyancy>`), at the height the node sinks to under that
load, :math:`z_f - w_i s^2/k_i`, and an attachment above the level its dry weight. The seabed
lies below the still-water level everywhere (a positive ``WtrDpth`` and positive bathymetry
depths), so a grounded node with its attachment stays submerged; an ``EI = 0`` line, whose
submergence follows its node heights, is wholly submerged where it is grounded. Where
the slope varies, the laid tension turns at every node and adds
:math:`-T_\text{laid}\,(\mathbf{t}_{i}^{+} - \mathbf{t}_{i}^{-})\cdot\mathbf{n}_i` to the
normal load (it presses the line into a crest and lifts it from a hollow), with
:math:`\mathbf{t}_{i}^{\pm}` the unit tangents of the laid path on either side of the node and
:math:`\mathbf{n}_i` the upward normal; a normal load :math:`P` deepens the normal penetration by
:math:`P/k_i` and so moves the node horizontally by :math:`P\,(z_{,x}, z_{,y})/(k_i s)`, with
:math:`s = \sqrt{1 + z_{,x}^2 + z_{,y}^2}`. The reference moves with the node, so the normal
sink adds no spurious friction deflection (a deflection normal to the seabed is not a friction
deflection, as in OrcaFlex's in-plane law): the spring of a node laid at rest carries only the
load along the seabed that friction holds there, the slope component of its load (none on a
level seabed). The sink and the turning force depend on the element lengths (a node at a
section change carries a share of either section), so the reference is laid on the mesh of each
static solve, under that mesh's lumped loads and nodal stiffnesses: a mesh the finite-EI statics
refines (adaptive refinement, the bending-length and stability refinements) or coarsens (the
mesh-sequenced and coarse-current passes) has the reference of its own nodes, and the march
takes it on the final mesh. The static solve then holds every node in
contact with a friction spring toward its reference, capped smoothly at :math:`\mu N`,

.. math::

   \mathbf{f}_t = -\frac{k_i\,\mathbf{d}}{\sqrt{1 + (k_i\lvert\mathbf{d}\rvert/\mu N)^2}},

with :math:`\mathbf{d}` the horizontal displacement from the reference and the anisotropic
capacity :math:`\mu(\mathbf d) N` below when the axial and lateral coefficients differ. This is
the regularised Coulomb law of the stick-slip spring of the dynamics: the same stiffness, the
same capacity, a smooth corner where the dynamics has a sharp one (OrcaFlex ramps the force
linearly to :math:`\mu R` over :math:`D_\text{crit} = \mu R/(k_s a)`). The springs act in
still water and in a current alike; they are memoryless, so the equilibrium does not depend on
how the loads are brought in. On the finite-EI path their capacities are frozen (with the drag
of a current) in the fixed-point passes and live in the final Newton solve; on the ``EI = 0``
path they are frozen at the line-search base point of the energy step. The ``EI = 0`` solve
tries the as-laid seed first: the nodes up to a lift-off node on their references, the rest
hanging as the suspended catenary to the fairlead, the lift-off node the first at which that
catenary leaves the seabed tangentially (on a line whose fairlead lies below its other end, as
a FAST.Farm shared line may, the reference and this seed are laid from the fairlead). The
finite-EI solve starts its bending-stiffness continuation from the ``EI = 0`` equilibrium with
the same friction, in 3D (only the two ends held) when the lay azimuth leaves the vertical plane
of the chord or the seabed under the laid run slopes across that plane: the seabed normal then
pushes the run out of the plane against its friction, which a solve in the plane would leave
unbalanced at the start of the march. A grounded run on a slope
of angle :math:`\theta` then holds where :math:`\sin\theta \le \mu` (the horizontal friction
force :math:`w\tan\theta` per unit length against the capacity :math:`\mu w/\cos\theta`;
OrcaFlex's in-plane law holds while :math:`\tan\theta \le \mu`, and the two limits differ by
under 1.6 % in :math:`\mu` for slopes up to 10°), and a line longer than its span rests where it was laid
instead of sliding down the slope or folding past its anchor. A run pulled taut from its laid
position is held back by friction toward the anchor, so its anchor tension is lower than in a
frictionless static by up to :math:`\mu w` times the grounded length (``asLaidTension`` equal
to the run's tension removes this). In the IEA-15 MW mixed example (850 m chains in 200 m of
water, ``frictionMu 0.35``) ``asLaid`` lowers the chains' anchor tension from 1351.6 to
368.2 kN (FairTen +0.16 %) and the laid power cable's from 1230 N to 0.36 N. With
``staticsFriction none`` the still-water static solve is
frictionless.

A line longer than the seabed run from its anchor to the point under its fairlead plus its
hang is laid past that point, and its suspended part turns back over the grounded run at the
touchdown. The ``EI = 0`` path solves this fold; on the finite-EI path the bending stiffness
must round it into a hook of the bending length, from which the static solve may not converge
(the solve then fails closed with its route diagnostics): a lay azimuth across the span
(``layAzimuth``), a shorter line, or the default ``staticsFriction none`` with a line that hangs as a
catenary avoid it.

After the static solve the stick-slip anchors of the march start at :math:`\mathbf{a}_i =
\mathbf{x}_i - \mathbf{f}_s/k_i` for the static spring force :math:`\mathbf{f}_s`, so the
march starts in the static equilibrium (OrcaFlex likewise starts dynamics from the targets of
statics) and a line held at rest keeps its static end tensions. Without static friction the
anchors are the static node positions and carry no force. Standalone, coupled OpenFAST and C
API runs share this model (they build their lines with the same routines).

**Anisotropic friction.** With ``frictionMuAxial`` :math:`\mu_a` and ``frictionMuLateral``
:math:`\mu_n` (the OrcaFlex axial and normal coefficients) the capacity depends on the slip
direction. With :math:`\hat{\mathbf a}` the unit horizontal projection of the local line axis
(the nodal tangent on the finite-EI path, the chord through the neighbouring nodes on the
``EI = 0`` path), :math:`\hat{\mathbf n} = \mathbf e_z\times\hat{\mathbf a}`, and
:math:`d_a = \mathbf d\cdot\hat{\mathbf a}`, :math:`d_n = \mathbf d\cdot\hat{\mathbf n}`,

.. math::

   \mu(\mathbf d) = \frac{\sqrt{(\mu_a d_a)^2 + (\mu_n d_n)^2}}{\lvert\mathbf d\rvert},

so a slip along the line is resisted by :math:`\mu_a N`, one across it by :math:`\mu_n N`, and
the force stays collinear with :math:`\mathbf d`. Both laws above use the capacity
:math:`\mu(\mathbf d) N` in place of :math:`\mu N`, the return mapping included. The line axis
is evaluated at every residual evaluation; the Jacobians carry the dependence of the capacity
on the slip direction but omit its dependence on the line axis.
A vertical axis (no horizontal projection) takes
:math:`\mu_n`. An equal pair runs the isotropic law unchanged.

A structured bathymetry grid gives :math:`z_\text{floor}(x, y)` by bilinear interpolation,
clamped to the nearest edge outside the grid, with the creases of that surface rounded.
Along every interior grid line the bilinear surface has a crease: its slope across the line
jumps by :math:`J` (the second difference of the tabulated depths). A node that must rest in a
concave crease, a valley along a grid line or the bottom of a pit, takes the normal of one cell
or the other and has no static equilibrium there; a slack chain piled at the bottom of a
trench and a frictionless grounded run slid sideways into a valley both end there. Each
crease is therefore rounded within a band of half-width :math:`\delta_k`, 5 % of the smaller
grid spacing next to line :math:`k`. Along one axis the interpolant :math:`g(x)` becomes

.. math::

   \tilde g(x) = g(x) + J_k\,h(x - x_k), \qquad
   h(u) = \frac{(\delta_k - |u|)^3}{6\,\delta_k^2} \quad (|u| < \delta_k), \qquad h = 0 \text{ elsewhere}.

:math:`h'(0^+) - h'(0^-) = -1` cancels the slope jump, and :math:`h`, :math:`h'` and :math:`h''`
vanish at :math:`|u| = \delta_k`, so :math:`\tilde g` is :math:`C^2`. Its curvature
:math:`J_k (\delta_k - |u|)/\delta_k^2` has the sign of the jump, so a valley stays convex and
gains no spurious pit. The surface is the tensor product of the two rounded interpolants,
:math:`z_\text{floor} = f + h_x J_x(y) + h_y \big(J_y(x) + h_x M\big)`, with :math:`f` the
bilinear surface, :math:`J_x(y)` the jumps of the grid rows across the :math:`x` line
interpolated linearly along it, :math:`J_y(x)` likewise, and :math:`M` the mixed second
difference of the grid where two lines cross. Its height, gradient and curvature are
continuous everywhere within the grid. Outside the bands it is the bilinear surface, and
inside the band of one line it moves by at most :math:`|J|\,\delta/6`; where two bands
cross the two roundings and the mixed term add. A 0.2 slope jump on a 10 m grid moves
it by 1.7 cm, within the static penetration of a chain (``w/(kBot Diam)``, 11 cm for a
120 mm chain at ``kBot = 1e5``). A crease that would move the surface by less than 1 µm is not
rounded: an exactly planar grid and every patch without a crease keep the bilinear surface
exactly. A plane written to two or three decimals has creases of the size of its rounding,
which are rounded by a fraction of a millimetre. The grid edges are not rounded, and outside the grid the
surface stays level. Every height and gradient query uses this one surface: the contact of
the ``EI = 0`` and the Hermite path, statics and dynamics, the friction frame and capacity,
the seabed clearance and touchdown outputs, and the Python post-processing
(``cabledyn.Bathymetry``). The friction capacity uses the normal force :math:`f_n^{(k)}(g/s)`;
inside a band it leaves out the curvature term of the contact force below, of the order of
the penetration times the curvature. A ``Fixed`` point placed at the
tabulated depth of a creased grid node lies up to :math:`|J|\,\delta/6` below the rounded
surface; it rests on the seabed and is placed on the rounded surface.

On a sloped patch the elastic contact is
frictionless and normal to the surface, on the ``EI = 0`` and the Hermite path alike: with
:math:`s = \sqrt{1 + z_{,x}^2 + z_{,y}^2}` the force is :math:`f_n^{(k)}(g/s)\,\mathbf{n}`,
:math:`\mathbf{n} = (-z_{,x}, -z_{,y}, 1)/s`, and its tangent
:math:`f_n^{(k)\prime}\,\mathbf{n}\mathbf{n}^{\mathsf T}` (the twist of a bilinear cell is not
differentiated); on a level floor this is exactly the vertical law above. Inside a crease band,
where the surface curves, the elastic force is the gradient of the penalty potential
:math:`E(g/s)` of the normal penetration, :math:`-f_n^{(k)}\,\partial(g/s)/\partial\mathbf{q}`:
the normal force plus :math:`f_n^{(k)}\,g\,\nabla s/s^2`, a term of the order of the
penetration times the curvature, and its tangent is the Hessian of that potential (third
derivatives of the surface left out). The static energy minimisation then agrees with the
force up to the twist of the bilinear cell, which is left out of the tangent as on a sloped
patch, and a node held in a rounded valley by its curvature has a consistent stiffness. Its
damping acts on
the velocity along :math:`\mathbf{n}`, and a friction capacity is :math:`\mu` times its
magnitude. The static solve and the dynamics use the same law, so a grounded run on a slope
rests at a static equilibrium of the march; its tension changes along the slope by the weight
component :math:`w\sin\theta` per unit length, and a run pushed down the slope into its anchor
is compressed there. On the Hermite path the contact acts on the nodal position DOFs only, not
on the tangent DOFs.

**Free and Connect points.** A clump weight or a buoy (a ``Free`` or ``Connect`` point with
``Mass`` or ``Vol``, or a ``Point3`` buoy, whose ``Body<N>`` attachment point steps as a free
point with the BODY ``Mass`` and ``Vol``) has its own seabed contact, the line law above with
the stiffness :math:`k_p = k_\text{Bot} A` and the damping :math:`c_p = c_\text{Bot} A` over its
contact footprint

.. math::

   A = V^{2/3}, \qquad V = \begin{cases} \text{Vol}, & \text{Vol} > 0, \\
   \text{Mass}/\rho_s, & \text{otherwise}, \end{cases}

the face area of a cube of the point's volume, CableDyn's own area-equivalent of a compact
body (a point carries no shape), with :math:`\rho_s = 7850\ \mathrm{kg/m^3}`: a clump declared
by its mass alone, its buoyancy left out, takes the volume of solid steel of that mass. A point
with neither (a massless line junction) has no footprint. Without it only the end nodes of the
attached lines held a point on the bed, over their tributary length: a 50 t clump between two
polyester lines (``kBot = 1e5``) sank 2.8 m into the seabed; on its 3.44 m² footprint it rests
0.95 m deep, within the 1.43 m that its weight alone would press it in, and the lines no longer
hang it from the seabed. The contact acts along the surface normal of a sloped or rounded
bathymetry, in the point static equilibrium and in the monolithic and staggered point steps
alike (in the staggered step its stiffness and damping are linearly implicit, like the end
blocks of the attached lines), so a grounded point starts at rest. A ``Point3`` buoy is not
placed by the static solve (it starts at its deck position; under ``bodyIC static`` the run notes
the force its line, weight, buoyancy, drag and contact leave on it there and the distance to its
balance as a ``Free`` point) but carries the same contact in
every march, the monolithic and staggered steps and the coupled point step of the OpenFAST
aggregate and the C API. The contact is frictionless: the point routes reject ``frictionMu``. A
point clear of the seabed sees exactly no contact load, and its results are unchanged.

Static equilibrium
------------------

Every run starts from a converged Newton equilibrium of
:math:`\mathbf{R}(\mathbf{q}) = \mathbf{f}_\text{int}(\mathbf{q}) - \mathbf{f}_\text{ext}(\mathbf{q}) = \mathbf{0}`
on the free DOFs, not from dynamic relaxation. External loads are the submerged weight, the
seabed reaction, end-connection
springs, on the ``EI = 0`` path the steady current, and, on the Hermite path, prescribed nodal
loads. The seabed reaction enters every residual and tangent evaluation; only the load
continuation of the ``EI = 0`` path (step 4 below) scales it during its intermediate stages.
Waves act from the start of the dynamic march, whose initial acceleration is computed
consistently with them.

.. _static-ei0:

EI = 0 path
~~~~~~~~~~~

The static-only deck route and the dynamic initial condition (``TMax = 0`` included) call the
same initialiser, so both report the same equilibrium. An ``EI = 0`` line cannot carry
compression: the accepted state is the tension-only equilibrium, with no element compressed
beyond a :math:`10^{-6}` relative round-off band; a slack element reports zero tension.

1. **Seeds**, tried in order until one gives an admissible equilibrium: the analytical
   extensible catenary (grounded when the anchor lies within
   :math:`\max(1\,\mathrm{mm}, 10^{-5}\lvert z_\text{floor}\rvert)` of the seabed, on the seabed
   plane through the anchor with its slope along the span; otherwise fully suspended); on a
   bathymetry, a grounded run draped on the actual seabed profile that lifts off tangentially
   into a suspended catenary; the catenary on the seabed lowered by the static penalty
   penetration :math:`w/(k_\text{Bot} d)` (a soft seabed); for a grounded line longer than span
   plus rise, the :math:`H \to 0` limit (a straight hanging leg with the excess on the seabed:
   where the seabed keeps falling past the fairlead the excess slides down the frictionless
   slope and folds back, with zero tension at the fold; otherwise it lies slack); the other
   catenary variant; and a two-leg polyline of the line length that never compresses the line.
   With static seabed friction the as-laid seed (:ref:`friction in statics <static-friction>`) is tried first.
   Seed nodes deeper below the seabed than their static penetration are lifted onto it.
2. **Compression-capable Newton** at the full load (Armijo line search on
   :math:`\tfrac{1}{2}\lVert\mathbf{R}\rVert^2`, :ref:`Armijo, 1966 <ref-armijo1966>`). A converged
   state with every element in tension is the tension-only equilibrium and is accepted; a
   compressed strut or arch is rejected.
3. **Tension-only Newton** otherwise: the compressed branch gets a stiffness :math:`r\,EA`, with
   :math:`r\,EA` of order :math:`10^{-3}` and then :math:`10^{-7}` of the largest nodal load (too
   weak to hold an arch), and finally :math:`r = 0`. Each stage is a Levenberg-Marquardt Newton
   iteration whose line search descends the potential energy (strain energy, seabed penalty
   potential, load potential; a steady-current drag is frozen at the base point of each search),
   so it approaches stable equilibria only; its shift never drops below :math:`10^{-12}` of the
   geometric stiffness scale, which keeps directions without stiffness (a grounded node between
   slack elements) solvable.
4. **Load continuation** in the stages 0.25, 0.5, 0.75, 1.0 is the fallback of each law. Each
   stage scales the seabed stiffness with its load factor, which keeps a stiff contact well
   conditioned from a cold seed; the final stage restores the full stiffness, so the converged
   equilibrium is unchanged.
5. **Convergence.** :math:`\lVert\mathbf{R}\rVert_\infty / s < 10^{-8}` or
   :math:`\lVert\mathbf{R}\rVert_\infty < 10^{-14}`, where :math:`s` is the largest of the
   infinity norms of the external load, the seabed reaction, and any current drag; a residual
   that stops decreasing inside the round-off floor
   :math:`16\,\epsilon\,\max(EA/L_0)\max(\lvert q\rvert, L_0)` of the nodal forces is converged,
   whether it stays flat or cycles between values (three iterations without a new minimum).
   A line with no admissible equilibrium fails closed, naming the line, the seeds and stages
   tried, and the reason.

The march gives the part of a line above the still-water level its dry weight, through the
recovery load of *Buoyancy and wetting* above, with or without a seabed, and the static start
does the same; drag and added mass act on the wetted part only. The recovery depends on the wetted lengths, so the line is
solved again with the recovery of the last solution as a constant load until its nodes move by
less than :math:`10^{-9}` m. This fixed point contracts at the ratio of the recovery's stiffness
:math:`\rho g A/\sin\theta` (:math:`\theta` the inclination at the surface) to the line's own,
a few :math:`10^{-3}` for a hanging chain. A chain hung from 5 m above the surface then starts in
the equilibrium its march holds, and the coupled and standalone starts agree; with its buoyancy
kept above the surface it moved by :math:`10^{-3}` of its fairlead load in the first step. A line
wholly below the surface has no recovery and is solved once. The force balance of ``Connect`` and ``Free`` points and of free bodies and rods
below takes its lines with the same dry weight, so these objects start balanced against the march
too; a finite-EI line, which enters it without its bending stiffness, takes its dry weight there
as its cubic-Hermite cable does.

A steady current (uniform, or a depth profile sampled at each node's own elevation as in the
march) enters the static equilibrium as Morison drag on the line at rest, so the out-of-plane
offset is part of the initial condition. ``Connect`` and ``Free`` points are then placed at
their static force balance: a trust-region Newton iteration on the point positions whose
residual sums the attached lines' end forces (each line re-solved for the moving ends), the
point's weight and buoyancy, its current drag, and its own seabed contact (see Seabed
contact above). It is the rigid-body equilibrium solve described under *Rigid-body initial
condition* below, with points as the only unknowns.

A tension-only line on a seabed that does not hold it can reach a folded (hairpin)
equilibrium: a current toward the anchor, or a seabed falling past it, drives the grounded run
beyond the anchor, and the run folds back to it with zero tension at the fold; a slack line can
likewise be laid out and back. The equilibrium is kept, and the driver prints one note per such
line, on every ``EI = 0`` route (static, ``TMax = 0`` and the dynamic initial condition, the
point and multibody systems, and the OpenFAST aggregate, whose line report returns it and whose
OpenFAST initialisation report prints it): ``the static layout carries the grounded run ... m
past its anchor, where it folds back (a hairpin)`` when grounded nodes lie more than 1 % of the
horizontal span plus 0.5 m beyond a grounded end whose other end is suspended, measured along
the horizontal chord (the criterion of the finite-EI note below; only for a horizontal span of
at least a tenth of the water depth at that end, or of the height of the other end above it if
that is larger, so that a near-vertical line, whose side away from its other end is not
defined, is left to the next test), or ``the static layout folds the grounded run back on
itself (a ... deg turn at node ...)`` when the run turns by more than 150°
at a node whose two neighbours are also grounded (within 5 cm of the floor); the node is the
deck node, numbered as the ``<J>`` of the node channels (1 = End A; an ``EI = 0`` line is never
refined, so its deck nodes are its mesh nodes). The note names the
cause: a deck current acting on the line (a current profile that vanishes at the seabed still
pulls the run through the suspended span), a seabed steeper than 0.5° at the fold, or neither
(a slack run). Its remedy follows the deck's static friction. Without ``frictionMu``: friction
against a current, or friction toward the as-laid position (``staticsFriction asLaid``) on a
slope, since with the default ``staticsFriction none`` the static solve applies friction against
a deck current only. With ``frictionMu`` and ``staticsFriction none`` on a slope:
``staticsFriction asLaid``. With friction that already acts and still does not hold the run, or
on a deck whose route rejects ``frictionMu`` (``Connect``/``Free`` points, ``Point3`` buoys) or
``staticsFriction asLaid`` (the multibody march): a shorter line. A run without ``dtM`` and
``TMax`` takes the static-only line solve, which carries no seabed friction at all, so there
the note adds that friction needs ``dtM`` and ``TMax`` (``TMax = 0`` for the statics alone).
Under ``staticsFriction asLaid`` no note is made when the as-laid reference itself (the line
laid on the seabed from its lower end, the anchor or the fairlead when that is lower, along
``layAzimuth`` or by default toward the other end, over its length) reaches past the grounded
end by more than the threshold above: the deck lays the run there, for example from the anchor
away from the fairlead, or from a lower fairlead toward the anchor and beyond it. The same rule
and the same causes and remedies apply to the finite-EI note below. The note never changes a
result. No
example deck and no ``EI = 0`` line of the statics test matrices prints it except the folded
layouts it describes.

Hermite path
~~~~~~~~~~~~

A finite-bending deck cable is initialised by the practice of "catenary statics, then full
statics" (``continuation cable_statics``, the default; ``sequenced cable_statics`` runs the
mesh-sequenced route described below first and this route as its fallback):

1. **Exact EI = 0 seed.** The multi-segment extensible catenary of the same sections (signed
   submerged weight, so buoyancy sections are included) is solved through the endpoints, on the
   declared seabed plane (flat ``WtrDpth``, or the least-squares plane of a structured bathymetry
   along the chord) or hung in mid-water when there is no seabed. The solve runs in the vertical
   plane of the chord, translated to the anchor, so a translated or rotated deck gives the same
   numbers to round-off. A line whose End A (the fairlead) rests on the seabed below its End B,
   such as a cable written from a seabed termination up to a floater, is seeded from End A, the
   same catenary seen from its other end, with its nodes put back in order. Over a bathymetry that is not a plane along the chord (a surveyed
   seabed with roughness, bumps or dips), the seed laid on the fitted plane meets the actual bed
   wherever the bed rises above that plane: every seed node deeper below the actual bed than its
   static penalty penetration (nodal submerged weight over the nodal contact stiffness
   ``kBot`` :math:`\times` ``Diam`` :math:`\times` length) is lifted onto the bed, and the
   continuation below, which queries the full surface, settles the contact. Such a seed is
   never rejected for its penetration; the equilibrium it leads to is audited like any other.
   When the only catenary through the endpoints passes below a planar
   seabed (flat, or a structured bathymetry whose profile under the chord is straight), the
   line is too long for its span to hang as a catenary. Without buoyant sections the line is a
   convex curve between the chord and the seabed, so it cannot be longer than the path down to
   the seabed, along it to below the fairlead and up; a longer line is in the same case. Its
   bending stiffness can still hold an equilibrium: the excess length stands up as a bow in
   the vertical plane, carried in compression by the bending stiffness. That state is reached
   by displacement control, as a line is laid: the anchor is moved back along the chord (by the
   excess length plus a tenth of the line, then half as far again until the catenary exists),
   the line is solved there by the steps below, and the anchor is walked back to its position
   in steps, each a minimisation of the potential energy from a secant predictor (plain Newton
   in a current, whose drag is not a potential force), the step halved on a failure and
   doubled after a success. The walked state is polished, audited and checked for stability
   like any other; the driver then reports its element-mean compression. When the walk ends
   short of the anchor (the bow snaps through, or the line would have to lie on itself), or the
   bathymetry does not continue its plane behind the anchor, the run stops and names the
   geometry: no admissible planar equilibrium clear of the seabed was found, the line being too
   long for its span to hang as a catenary, with where the walk stopped. A line too long for
   the plane fitted to a non-planar bathymetry is walked the same way, the moved anchor kept
   at its height above the bed under it and the seed draped as above; as such a bed can hold
   the excess length in its dips, a failed walk there proves nothing, and the mesh-sequenced
   route runs before the run stops. A walked state that
   the audit below rejects (self-contact, instability) hands over to the mesh-sequenced route,
   and is named the same way when that finds none; with ``tensile_safety True`` a walked state
   in compression is rejected by name (a bow held by bending is compressed).
   The walked arch faces the anchor. When the walk fails or its state is rejected, a line in
   still water over a flat seabed is also traced to the bow on the other side of the line
   hanging from the fairlead, which the walk cannot reach without passing the arch through
   that line. The anchor is placed beyond the fairlead, as far from it as the walk moved it
   back, where the arch faces away from the real anchor, and walked toward the fairlead. Each
   step is bounded so as not to pass the point where the grounded run, folded back about its
   touchdown point, reaches the real anchor (to 2 % of the span), and the walk stops there or
   at the last state before the arch turns over. The grounded run is folded, the corner at
   the touchdown relaxed by an energy minimisation, and the anchor walked the rest of the way
   into place; the state is polished, audited and checked for stability like the walked one.
   The bow is compressed, so it is not traced with ``tensile_safety True``, nor in a current.
   On a mesh with elements shorter than :math:`\sqrt{EI/EA}` the continuation below has an
   iteration budget of :math:`2\times10^{6}` divided by the element count (a solve that
   converges there does so within it), and no other route follows a failure: the run stops in
   seconds and names the mesh.
2. **Continuation in** ``EI``. The family :math:`\lambda\,EI` is traced from a fraction whose
   bending length :math:`(\lambda EI/|w|)^{1/3}` is below a quarter of the element length up to
   :math:`\lambda = 1`, every load at full value. Each stage minimises the total potential energy
   (elastic, weight, buoyancy lost above the surface, seabed penalty, end springs) by a modified
   Newton iteration: the tangent is shifted until a banded Cholesky factorisation succeeds, so
   every direction descends toward a *stable* equilibrium, and the step length follows an Armijo
   line search on the energy. Close to equilibrium full Newton steps on the complete tangent
   take over, because the seabed contact and waterline laws are only piecewise smooth (and the
   curvature of a structured bathymetry grid is not differentiated). Stages that jump
   further than a small fraction of the line are retried at a smaller step; a first stage that
   does not converge is restarted at full ``EI``. Such a descent from the seed (and the one past
   a limit point of the continuation) can run for more than a thousand iterations while the
   energy falls and the residual rises and falls, and that count scatters with the last digits
   of the input, such as the line's azimuth. Past its allowance it therefore runs on while the
   two-norm of the scaled residual keeps halving within an allowance, to one and a half
   allowances (a longer descent can settle on a folded branch that the other routes avoid).
3. **Polish and diagnosis** on the deck mesh at the static tolerance. A residual floor above it
   is accepted at :math:`10^{-6}` (or, for a line on the seabed, :math:`10^{-5}`, nodes
   alternating across the 1 µm contact blend) and reported. An element folded beyond
   :math:`L_0\kappa = 0.7` on the deck mesh is refined locally, from the polished state, until
   no element exceeds :math:`L_0\kappa = 0.35`; ``adaptive_mesh`` refines the same way, to its
   own target. A refinement pass splits into :math:`2^k` equal elements every element whose
   sampled :math:`L_0\kappa` exceeds 0.12 (or the requested target, when stricter), that is
   longer than half its bending length :math:`(EI/|w|)^{1/3}`, or, at a line end, longer than
   its boundary layer :math:`\sqrt{EI/T}`, and the elements about a node whose seabed contact
   differs from both neighbours; :math:`k` is the smallest that meets the criterion, at most 4
   (16 elements per deck element). The neighbours are then split until no element is more than
   twice as long as the next one (or than the ratio the deck mesh already has there) and none
   is left longer than both of its neighbours with fewer splits than either (a single coarser
   element between finer ones carries a spurious axial oscillation), the state is carried to
   the new mesh by the Hermite interpolant of each element and polished, and the pass is
   repeated on the polished state while the target is not met and an element can still be
   split (at most 12 passes), within 8192 elements: a pass that would exceed them gives up the
   bending-length splits first, then the grading, and only then the curvature, end-layer and
   contact splits. Elements the criteria leave alone keep their deck length, so
   a single coarse section costs only its own refinement (a 462-element lazy
   wave whose 180 m top section has two elements: 492 elements, where refining the whole line
   by the factor of its worst element gave 7392). A deck mesh too coarse for the bending length
   whose continuation or polish fails, or whose folded element the local refinement does not
   resolve, repeats the route on a mesh refined until the elements are at most
   half the bending length (when the continuation on that mesh runs out of its iteration
   budget, on the coarser powers of two down to twice the deck mesh) and, when that fails too,
   on the deck mesh with each element split only into the power of two (at most 16) that brings
   it to half the bending length. A uniform refinement keeps a graded deck's ratios and refines
   its short elements with the long ones: a lazy wave meshed 4 m at its sag bend, 0.9 m over its
   buoyant section and 10 m at its touchdown failed in an oblique current on the deck mesh and on
   the 8x refined one, and solves on the mesh refined element by element (within 1.2e-3 of its
   fairlead tension of the same deck on 2 m elements); a rotationally
   restrained end whose boundary layer :math:`\sqrt{EI/T}` is shorter than its element, which
   shows as a polish that does not converge or a compression at that end, repeats it on a mesh
   graded geometrically toward that end. The refined mesh is reported.
4. **Physical-branch audit.** The converged state must be clear of self-contact (no two
   non-adjacent elements closer than their diameters), unfolded, and stable (positive definite
   tangent). Element-mean axial compression of a stable bent equilibrium is admissible and is
   reported; with ``tensile_safety True`` it is rejected. That contract is judged, as in the
   dynamics, on the element-mean axial force averaged over each element and its two
   neighbours, compared with the tighter of the strain band :math:`2\times10^{-6}\,EA` (with the
   ``EA`` of the centre element) and a thousandth of the peak tension (the largest pointwise
   resultant); the pointwise resultant of a coarse element oscillates about that mean (tens of
   kN on the Gulf of Mexico 80 m lazy wave at 48 elements) without entering equilibrium, and
   does not drive the mesh refinement. Before rejecting, the static solve
   splits the elements whose three-element mean falls below the band (and their neighbours) and
   solves again, since a coarse element can dip where the line is in tension; it stops, and the
   solve names the compression, when two passes do not relieve it, when it is the reaction of a
   held end (the minimum settled on the end node over two passes, which no splitting changes),
   when the polish on the split mesh does not converge, or at an element budget. The report is
   judged on element-mean forces: the mean over each element and its two neighbours
   (length-weighted) beyond the
   admissible band, or a nodal material axial force (the length-weighted mean of the two
   adjacent element means) in compression by more than a tenth of the peak tension.
   The nodal seabed-contact reaction kinks the line at the touchdown node, and the
   element there can carry a small negative mean between tensile neighbours at any mesh; that dip
   does not enter equilibrium and is not reported. A failing route falls back to the
   mesh-sequenced solve below, audited alike. On the Lozon cables the two routes give the same
   equilibrium to the solver tolerance (positions within 2e-5 m, curvature within 1e-6 1/m).

A line longer than its span with little net weight for its bending stiffness has no catenary
to start from. With no weight at all it bows under the axial compression its bending stiffness
carries, the Euler elastica (about :math:`\pi^2 EI/L^2`). Both routes can then end on the
compressed straight strut, a saddle, or stall at the round-off of the axial forces,
:math:`EA\,\varepsilon\,|\mathbf r|/h` (the axial strain is formed from coordinate differences over
an element of length :math:`h`), which a weightless line's unit force scale puts above the
tolerance. When both routes fail on a slack line with :math:`|w| < 100\,EI/L^3` (largest
:math:`EI`), the line is solved with the auxiliary weight :math:`w_a = 100\,EI/L^3` added to every
element, of the sign of its net weight and downward for a weightless one, which the routes
handle. That equilibrium is carried back to the line's own weight by a continuation in the
weight, held in the vertical plane of the chord: steps of a quarter of the remaining
:math:`w_a`, the last from :math:`w_a/256` to none, a failed step halved. The steps accept the
round-off floor :math:`8\,EA\,\varepsilon\,|\mathbf r|_{\max}/h_{\min}` of the axial forces when it
lies above the tolerances of the routes, and a floor above the static tolerance is reported as
for the routes. The result is audited and checked for stability like theirs. The continuation
runs on a planar line in still water over a level seabed, without attachments or
``tensile_safety True``, whose chord is not vertical (the auxiliary weight must have a
component across it). For a weightless line nothing in the deck chooses the plane or the side
of the bow: the limit of a vanishing weight puts it on the lower side in the vertical plane of
the chord, and a note says so. Its tangent there has one zero eigenvalue, the bow turning about
the chord: the planar solve holds that mode, and a dynamic run leaves it free and at rest. On a
pinned 120 m line
with its ends 113 m apart the end thrust and the mid-span bow match the inextensible elastica,
:math:`P = 4K(m)^2EI/L^2` and :math:`\delta = \sqrt{m}\,L/K(m)` with
:math:`\text{chord}/L = 2E(m)/K(m) - 1`, to :math:`3\times10^{-5}` and :math:`10^{-6}` relative.

A deck current loads the line at rest with its steady Morison drag (the relative velocity is
the current itself; the element fluid velocity is the mean of the current at its two nodes,
as in the dynamics). The drag follows the line and is not a potential force: it is carried
along the stiffness continuation frozen at the last accepted configuration, then converged
at full stiffness by a fixed-point iteration on the frozen drag and a final Newton solve with
the configuration-dependent drag and its Jacobian. A depth profile is sampled at the node
elevations and a current grid at the node positions, so the drag moves with the nodes through the
current too; the Jacobian carries it as the drag's derivative with respect to the fluid velocity,
:math:`-(\partial\mathbf{f}/\partial\dot{\mathbf{r}}_a + \partial\mathbf{f}/\partial
\dot{\mathbf{r}}_b)`, times the element velocity's gradient
:math:`\tfrac12\,\mathbf{R}^{\mathsf T}(\partial\mathbf{U}/\partial\mathbf{x})\,\mathbf{R}` at each
node (:math:`\mathbf{R}` the turn of the solve frame). If the frozen-drag continuation fails, the
still-water equilibrium is found first and the drag is brought in by load steps. A load step
that stalls hands over to a pseudo-arclength continuation in the drag fraction
:math:`\lambda`: each corrector solves the bordered system
:math:`[K,\,-D;\ t_q^T,\ t_\lambda]` (:math:`D` the drag at full current) by block elimination
with two banded solves, so the path can turn at a limit point in :math:`\lambda`. At a ``Rigid``
end the system is taken in the basis of the end direction, as in the static solve, with the
two transverse components of the end tangent held. A current
across the vertical plane of the line makes the static solve three-dimensional, as the
dynamics are.

Without seabed friction, a current that pushes the grounded run toward its anchored end
harder than the suspended span pulls it back puts that run into compression; a cable cannot
hold it, and the run would have to buckle or slide past its end. There is no tension-only
equilibrium that continues the still-water layout in its plane. With the current in the
vertical plane of the line the problem is symmetric and the planar branch ends in a
pitchfork: the equilibrium beyond it turns the grounded run sideways on the seabed, past its
anchor and back (a lazy wave in a 0.7 to 1.2 m/s current along its plane, for example).
Newton cannot leave the plane of a symmetric problem, so the line is then solved in 3D under
the current with a cross-flow of 1 % of its horizontal speed, and that state is polished at
the exact current and audited like any other. A planar equilibrium in such a current is also
checked with the line free to leave its plane; one that is a saddle there (the grounded run
held in the plane only by the symmetry) is replaced by this 3D solve; when the 3D solve finds
no equilibrium, the planar one is kept and a note says that it is held in the plane of the line
and unstable out of it. Where the planar path
ends depends on the element size (whether a load step or a polish crosses the limit), so the
branch is selected on the deck mesh coarsened by halving every section's ``NumSegs`` as long as
the elements stay within one bending length :math:`(EI/|w|)^{1/3}`: that coarse line goes
through every route above, and its equilibrium is carried to the deck mesh by cubic-Hermite
interpolation along the unstretched arc length and polished there at the exact current, free
to leave the plane, then audited and checked for stability. Decks whose meshes are halvings of
one another select the same coarse mesh, and so the same equilibrium; a residual floor above
the tight tolerance on a fine mesh is accepted at the coupled static tolerance and noted. The
result can be a folded (hairpin) layout:
a very strong current on a frictionless seabed carries the line past its anchor and it folds
back to it, either as a loop lying on the seabed with its two legs side by side or, for a
lazy wave, with the buoyant arch carried beyond the anchor and the line coming back down to it.
Such a layout is a genuine equilibrium: the drag on the legs is held by the tension of both,
the seabed carries the grounded part, and the tangent is positive definite. OrcaFlex statics
seeded with the CableDyn shape converge to the same layout, and a dynamic run from it stays at
rest and returns to it after a disturbance. The standalone driver prints a note when the
grounded run of the static layout lies past its anchor (``the static layout carries the
grounded run ... m past its anchor``), because the layout differs from the usual one and a
real seabed with friction, or a shorter line, would not reach it. The note names the same
cause and remedy as the ``EI = 0`` fold note above (one rule for both): the finite-EI static
solve also applies ``frictionMu`` against a deck current under ``staticsFriction none``, so
``frictionMu`` answers a current and ``staticsFriction asLaid`` a slope, and a shorter line
remains where that friction already acts or the route rejects it (the multibody march rejects
``asLaid``, and a deck with ``Connect``/``Free`` points or ``Point3`` buoys ``frictionMu``).
Under ``asLaid`` no note is made when the as-laid reference itself, the line laid from its
lower end along ``layAzimuth``, reaches past the anchor. When the 3D solve also
fails, the solve stops with
the diagnosis (the element-mean compression, where it sits, and its height above the seabed)
and suggests ``frictionMu``; neither the pseudo-arclength continuation of the planar path
nor the mesh-sequenced route, which reach the same planar limit, is then run. With friction the grounded run is held; a lazy wave whose buoyant arch the
current pushes toward the touchdown then goes into compression at the touchdown instead,
which friction cannot hold, and the solve names that. A line that is already compressed
without the current is named as such. A lazy wave whose seabed run points downstream reaches
these limits at a fraction of the current that the same layout holds when the current comes
from the other side.

The free surface uses the partial immersion of the circular section: over the band
:math:`|z| < D/2` the displaced area, and so the buoyancy lost above the water, follows the
circular-segment fraction of the section, which gives a line floating at the surface its
waterplane stiffness. The static and dynamic paths share this law.

The fallback and the dynamic Hermite path use

- **continuation in** ``EI``, and, for a net-buoyant line, **continuation in buoyancy**, which
  tracks the smooth branch of the buoyant arch from the seed;
- the **consistent Hermite self-weight**, :math:`wL_0/2` on each end :math:`r_z` and
  :math:`\pm wL_0^2/12` on the end :math:`m_z`. At a held line end resting on the seabed the
  floor carries the end element's weight with this end moment (its normal share
  :math:`\cos\theta\,\mathbf{n}` on a floor of slope :math:`\theta` and upward normal
  :math:`\mathbf{n}`), in the share :math:`3r^2 - 2r^3` (:math:`0 \le r \le 1`) in which the
  element lies on the floor, :math:`r` the elastic contact force of its inner node over half the
  element's weight: the nodal contact carries no moment, and the unbalanced end moment would
  otherwise turn the end tangent of a laid element into the floor, while an element rising
  from an anchor on the floor (:math:`r = 0`) keeps it;
- **mesh sequencing**: the equilibrium is selected on a coarse mesh that preserves section,
  load, and contact-diameter interfaces, prolonged through the Hermite interpolant, and polished
  on each finer level and finally on the exact user mesh with the same residual test. Deterministic
  fallback hierarchies are tried before a direct cold solve; every attempt uses the same
  physical inputs and tolerance;
- a **dimensionless per-DOF residual norm**, with tangent-DOF residuals divided by the nodal
  tributary length. The force scale is the largest of 1 N, the line's weight, the applied nodal
  loads, and, for a line held at both ends whose chord is at least its length, the tension the
  chord implies and the round-off floor of the axial forces over the tolerance,
  :math:`16\,\epsilon\,\max(EA/L_0)\max(\lvert x\rvert, L_0)/\text{tol}` with
  :math:`\lvert x\rvert` the largest coordinate (the floor of the ``EI = 0`` path). A neutral line
  of the length of its span, straight at zero strain, carries neither weight nor tension, and
  without the floor its residual could not meet the tolerance: its attachment polish stalled at
  7.6e-8 N against :math:`10^{-8}` N. A slack weightless line keeps its scale, so its round-off
  stall on the straight compressed strut fails over to the weight continuation above.

The static tolerance is :math:`\min(10^{-6},\ \text{tol}_\text{dyn})`, where
:math:`\text{tol}_\text{dyn}` is the dynamic Newton tolerance, so the dynamics start from an
equilibrium at least as tight as their own stopping criterion. Two checks keep a numerically
balanced but unresolved state out of the dynamics: an element whose sampled
:math:`\max(L_0\,\kappa) > 0.7` is an unresolved fold and is rejected, and, with
``adaptive_mesh``, exhausting the refinement cap while the curvature or contact topology remains
under-resolved is reported.

Coupled systems of lines, points, and bodies are initialised in sequence: non-line objects are
held while each line is solved, then released and the coupled system is solved.

Modal analysis
--------------

With ``nModes`` each line's natural frequencies and mode shapes about its static equilibrium
solve the generalised symmetric eigenproblem

.. math::

   \mathbf K\,\boldsymbol\phi = \omega^2\,\mathbf M\,\boldsymbol\phi

over the free degrees of freedom, the two ends held (a fixed anchor and a held or prescribed
fairlead). :math:`\mathbf K` is the static tangent stiffness: for an ``EI = 0`` element of rest
length :math:`l_0`, current length :math:`l` along :math:`\mathbf e`, and tension
:math:`T = EA(l/l_0 - 1)` (zero on a slack tension-only element),
:math:`\mathbf k = (EA/l_0)\,\mathbf e\mathbf e^{\mathsf T} + (T/l)(\mathbf I - \mathbf e\mathbf e^{\mathsf T})`
assembled as :math:`[[\mathbf k, -\mathbf k], [-\mathbf k, \mathbf k]]`; for a cubic-Hermite
element, the Hessian of its strain energy. The linearised seabed normal contact adds its
stiffness on the contacting nodes. :math:`\mathbf M` is the consistent structural mass plus the
Morison added mass at the static shape. Friction, damping, and drag are left out, as in any
undamped modal analysis. :math:`\mathbf K` and :math:`\mathbf M` are banded (the nodes are
numbered along the line), and only the ``nModes`` lowest modes are computed. Their eigenvalues
come from a block Lanczos iteration on the shift-inverted operator
:math:`\mathbf K^{-1}\mathbf M`, applied with the banded Cholesky factor of :math:`\mathbf K`,
in the :math:`\mathbf M` inner product with full reorthogonalisation. The block holds two
vectors, so both planes of a straight line, whose transverse frequencies coincide, are found.
A Ritz value is accepted when the residual of the shift-inverted eigenproblem is below
:math:`10^{-10}` of its eigenvalue. The count is then certified: the Cholesky factor shows that
no eigenvalue lies at or below zero, and the inertia of :math:`\mathbf K - \sigma\mathbf M`
(the negative pivots of its banded :math:`\mathbf L\mathbf D\mathbf L^{\mathsf T}`
factorisation, by Sylvester's law of inertia) at a shift :math:`\sigma` in a gap above the
wanted eigenvalues must equal the number of Ritz values below :math:`\sigma`, so no frequency
is missed or counted twice. The iteration's time grows linearly with the line length. Short
lines, many modes of a short line, an indefinite or singular :math:`\mathbf K` (a compressed
or slack line), and an iteration that does not converge or is not certified within its basis
bound take LAPACK ``dsbgvx`` instead (band reduction and bisection), whose time grows with the
square of the line length. Inverse iteration with the banded factors of
:math:`\mathbf K - \omega^2\mathbf M` then gives each shape (M-orthogonal to the shapes
before it, so a repeated frequency gets independent shapes), and the returned
:math:`\omega^2` is the Rayleigh quotient of the shape, summed in quadruple precision. That
quotient keeps the lowest frequencies of a long, axially stiff line accurate, where the band
reduction alone loses digits. A shape the Lanczos eigenvalues do not give is solved again on
the eigenvalues of the band reduction. Each shape is signed so that its largest component is
positive; where two components are equally large to round-off (the mirrored nodes of a
symmetric line), the first of them in the solver's node order is. Memory grows linearly with the line
length. The frequencies
:math:`f = \omega/2\pi` and the nodal translations of each mode (scaled to a unit largest
nodal displacement) are written to ``<root>.modes.out``; an eigenvalue :math:`\omega^2 < 0`, an
instability of the static state, is written as the negative frequency
:math:`-\sqrt{|\omega^2|}/2\pi` and noted. For a taut string of tension
:math:`T` the transverse frequencies are :math:`f_n = (n/2L)\sqrt{T/m}`; for a shallow sagging
cable the out-of-plane and antisymmetric in-plane modes follow the string with the horizontal
tension :math:`H`, and the symmetric in-plane modes satisfy
:math:`\tan(\beta/2) = \beta/2 - (4/\lambda^2)(\beta/2)^3`, :math:`\omega = (\beta/L)\sqrt{H/m}`,
with :math:`\lambda^2 = (wL/H)^2\,L/(H L_e/EA)` (:ref:`Irvine & Caughey, 1974 <ref-irvine1974>`);
the modal analysis reproduces both.

A finite-EI line's modes carry what its dynamics carries: an end connection's spring adds its
Hessian on the end tangent, a rigid end keeps only the magnitude of its tangent (the two
transverse components of its basis are held), and discrete attachments add their dry and added
masses. A line restrained in torsion carries the :ref:`nodal twist <theory-nodal-twist>` in its
dynamics, so its modes do too: the twist angle :math:`\varphi_k` of every node joins the
degrees of freedom, :math:`[\mathbf r, \mathbf m, \varphi]` per node (half-bandwidth 13), with
the lumped polar inertia :math:`I_k` as its mass and the second variation of the twist energy
:math:`E_t = \sum_e \tfrac12 (GJ_e/L_{0,e})\,\hat\tau_e^2` (and of the elastic end springs) as
its stiffness, at the static element torques :math:`M_e = (GJ_e/L_{0,e})\,\hat\tau_e`. With
element :math:`e` between nodes :math:`k` and :math:`k+1` and its full twist
:math:`\hat\tau_e = \varphi_{k+1} - \varphi_k + \rho_e(\mathbf q)`,
:math:`\rho_e = m_e + (K_e/GJ_e)(l_e - L_{0,e})`,

.. math::

   \frac{\partial^2 E_t}{\partial\mathbf q^2} = \sum_e \Big( M_e\,\frac{\partial^2 \rho_e}{\partial\mathbf q^2}
     + \frac{GJ_e}{L_{0,e}}\,\mathbf g_e\mathbf g_e^{\mathsf T} \Big), \qquad
   \frac{\partial^2 E_t}{\partial\varphi_{k+1}\,\partial\mathbf q}\Big|_e
     = -\frac{\partial^2 E_t}{\partial\varphi_k\,\partial\mathbf q}\Big|_e = \frac{GJ_e}{L_{0,e}}\,\mathbf g_e,
   \qquad \mathbf g_e = \frac{\partial\rho_e}{\partial\mathbf q} ,

the second term summed over the two elements that share a node; under torque–tension coupling
:math:`\partial^2\rho_e/\partial\mathbf q^2` holds :math:`(K_e/GJ_e)\,\partial^2 l_e/\partial\mathbf q^2`.

The torque term lowers the bending frequencies of a twisted line, as on Greenhill's twisted
shaft; :math:`\mathbf g_e` couples the twist to the bending of a curved line and, under
torque–tension coupling, to the stretch. Eliminating the angles (no polar inertia) leaves the
condensed tangent of the statics, :math:`-M_t\,\partial^2\Theta/\partial\mathbf q^2 +
\nabla\Theta\,\nabla\Theta^{\mathsf T}/C`: the Schur complement of the angle block is the
rank-one term the statics carry in a bordered solve, which a band cannot hold. Damping (also
:math:`B_t`) is left out. The test suite checks the torsional modes of a clamped straight line
against :math:`\omega_n = (n\pi/L)\sqrt{GJ/I_{rn}}` and its lumped chain, elastic torsional
ends, the coupled axial–torsional modes of :math:`K`, the lateral modes of a taut line under a
torque against the clamped Greenhill-cable determinant, and the Schur complement against the
condensed static tangent (see :doc:`validation`).

Time integration
----------------

Both paths advance

.. math::

   \mathbf{M}\ddot{\mathbf{q}} + \mathbf{f}_\text{int}(\mathbf{q}, \dot{\mathbf{q}})
   = \mathbf{f}_\text{ext}(\mathbf{q}, \dot{\mathbf{q}}, t)

with the generalised-α method (:ref:`Chung & Hulbert, 1993 <ref-chung1993>`). There are no
rotation variables, so :math:`\mathbf{q}` and :math:`\ddot{\mathbf{q}}` share one vector space and
no gyroscopic or rotation-chart terms arise. The parameters follow from the spectral radius
:math:`\rho_\infty` (``rhoInf``, :doc:`conventions`):

.. math::

   \alpha_m = \frac{2\rho_\infty - 1}{\rho_\infty + 1}, \qquad
   \alpha_f = \frac{\rho_\infty}{\rho_\infty + 1}, \qquad
   \beta = \tfrac{1}{4}(1 - \alpha_m + \alpha_f)^2, \qquad
   \gamma = \tfrac{1}{2} - \alpha_m + \alpha_f .

With :math:`\mathbf{q}_{n+1}` as the Newton unknown,

.. math::

   \mathbf{a}_{n+1} = \frac{\mathbf{q}_{n+1} - \mathbf{q}_n}{\beta\,\Delta t^2}
                    - \frac{\mathbf{v}_n}{\beta\,\Delta t}
                    - \left(\frac{1}{2\beta} - 1\right)\mathbf{a}_n, \qquad
   \mathbf{v}_{n+1} = \mathbf{v}_n + \Delta t\left[(1 - \gamma)\,\mathbf{a}_n + \gamma\,\mathbf{a}_{n+1}\right],

and the residual is evaluated at the intermediate states

.. math::

   \mathbf{G} = \mathbf{M}\left[(1 - \alpha_m)\,\mathbf{a}_{n+1} + \alpha_m\,\mathbf{a}_n\right]
              + \mathbf{f}_\text{int}(\mathbf{q}_\alpha, \mathbf{v}_\alpha)
              - \mathbf{f}_\text{ext}(\mathbf{q}_\alpha, \mathbf{v}_\alpha, t_\alpha),
   \qquad (\cdot)_\alpha = (1 - \alpha_f)(\cdot)_{n+1} + \alpha_f(\cdot)_n .

On the finite-EI path time-dependent loads (waves) are then evaluated at :math:`t_\alpha`; the
``EI = 0`` path holds the fluid fields over the step (below). By default both paths blend the
*forces* instead (``alpha_force_blend``, default ``True``; ``False`` selects the form above),

.. math::

   \mathbf{G} = \mathbf{M}\left[(1 - \alpha_m)\,\mathbf{a}_{n+1} + \alpha_m\,\mathbf{a}_n\right]
              + (1 - \alpha_f)\,\mathbf{r}(\mathbf{q}_{n+1}, \mathbf{v}_{n+1}, t_{n+1})
              + \alpha_f\,\mathbf{r}(\mathbf{q}_n, \mathbf{v}_n, t_n),
   \qquad \mathbf{r} = \mathbf{f}_\text{int} - \mathbf{f}_\text{ext},

with the same accuracy and tangent. On the Hermite path the position and tangent-vector DOFs
rotate with the line, and a blended configuration :math:`\mathbf{q}_\alpha` would shorten the
tangents of a rotating element, a spurious stretch of order
:math:`\alpha_f(1 - \alpha_f)(\omega\Delta t)^2 EA` that raises the mean tension at large time
steps. There :math:`\mathbf{r}_n` is the previous step's converged force, reused unless the state
or the load configuration changed in between. Since it enters every later step, the accepted
state is taken one Newton correction beyond the tolerance (the last factorisation reused), so a
loose Newton tolerance does not bias the response. Both forms converge to the same response; the
force blend removes the rotation-driven bias (see ``alpha_force_blend`` in :doc:`options`).

On the ``EI = 0`` path the force blend covers the axial force of the elements and every
dynamic load: axial damping, the viscoelastic and Syrope laws, seabed contact, damping and
friction, Morison drag, Froude–Krylov and buoyancy loads. Added mass stays at
:math:`(\mathbf{q}_\alpha, \mathbf{a}_{\alpha_m})`. :math:`\mathbf{r}_n` is evaluated afresh at
the committed state of every step, with the viscoelastic and Syrope elements at their committed
internal state (and, after a length change by active line control, at the lengths the committed
state was reached with; see Active line control), so the scheme carries no extra state and a
restart is exact; a re-solve of the
same step from the same state (the junction coupling) reuses it. The fluid fields of an
``EI = 0`` line (current, wave velocity and acceleration, and the waterline) are held over the
step: before the step the host (the standalone driver, or the coupling host) samples them for
the end of the step, :math:`t_{n+1}`, at the committed node positions, and every load
evaluation of the step uses them. Both shares of the force blend therefore see the fields of
:math:`t_{n+1}`, so :math:`\mathbf{r}_n` is :math:`\mathbf{r}(\mathbf{q}_n, \mathbf{v}_n)` with
those fields rather than with the fields of :math:`t_n`, and the configuration blend evaluates
the loads with them at :math:`(\mathbf{q}_\alpha, \mathbf{v}_\alpha)` rather than at
:math:`t_\alpha`, as it did before the force blend. The finite-EI path instead evaluates its
wave loads at :math:`t_{n+1}` for the end share and reuses its :math:`\mathbf{r}_n`, evaluated at
its own :math:`t_n` in the previous step. The configuration blend fails at slack–taut
transitions. A tension-only element is a
one-sided spring, and the residual sets its force at :math:`\mathbf{q}_\alpha`; the end state
:math:`\mathbf{q}_{n+1} = (\mathbf{q}_\alpha - \alpha_f\mathbf{q}_n)/(1 - \alpha_f)` extrapolates
past it. A segment slack at :math:`t_n` that carries a tension at :math:`t_\alpha` thus ends the
step stretched by :math:`\alpha_f/(1 - \alpha_f)` of its former slack on top: with
:math:`\rho_\infty = 0.4` a 2 m segment of a light, axially stiff cable (80 kg/m, EA 8e8 N) that
was 0.2 m slack reports about 30 MN. A mass dropped 1 m onto a tension-only spring
(:math:`\omega = 1000` rad/s) peaks at 6.9 MN at :math:`\Delta t` = 0.1 s with the configuration
blend, against the resolved 0.35 MN; the force blend gives 5.7 kN, the under-resolved impact
dissipated as at :math:`\rho_\infty = 0`.

**Release cap.** The force blend alone still creates energy when a taut element releases
within one step. An element with tension :math:`T_n`, stretch :math:`e_n = l_n - l_0 > 0` and
chord :math:`\mathbf{d}_n = l_n \mathbf{t}_n` at :math:`t_n` keeps :math:`\alpha_f T_n` along
:math:`\mathbf{t}_n` for the whole step, a constant force. Over the relative displacement
:math:`\mathbf{d}_{n+1} - \mathbf{d}_n` of its ends it returns the work :math:`\alpha_f T_n p` to
the motion, with the projected shortening :math:`p = l_n - \mathbf{t}_n \cdot \mathbf{d}_{n+1}`.
This is not the shortening :math:`e_n - e_{n+1}` of the element: since
:math:`p = (e_n - e_{n+1}) + l_{n+1}(1 - \mathbf{t}_n \cdot \mathbf{t}_{n+1})`, a segment that
turns as it releases moves much further against that force than it shortens. The end share
:math:`(1 - \alpha_f) T_{n+1} \mathbf{t}_{n+1}` returns :math:`-(1 - \alpha_f) T_{n+1} p_{n+1}`,
with :math:`p_{n+1} = l_{n+1} - \mathbf{t}_{n+1} \cdot \mathbf{d}_n`. The element released only
its strain energy :math:`W_n = \tfrac{1}{2} T_n e_n`. An element that ends slack
(:math:`T_{n+1} = 0`) therefore creates energy once :math:`p > e_n/(2\alpha_f)`: along a fixed
chord, a release deeper than :math:`e_n (1/(2\alpha_f) - 1)` (0.75 :math:`e_n` at
:math:`\rho_\infty = 0.4`); a nearly unstretched segment that turns by 90° returns about
:math:`\alpha_f T_n l_n`, hundreds of times :math:`W_n`. On a slack light cable this feeds a
sustained rattle of single-step tension spikes. The cap bounds the work of the element's blended
force by :math:`W_n`: along :math:`\mathbf{t}_n` the element carries the smaller of
:math:`\alpha_f T_n` and :math:`(W_n + (1 - \alpha_f) T_{n+1} p_{n+1})/p`, which is the discrete
energy gradient :math:`W_n/p` when it ends slack, and the residual and the tangent take the
difference (:math:`\partial p/\partial \mathbf{d}_{n+1} = -\mathbf{t}_n`). With
:math:`T_{n+1} = T_n e_{n+1}/e_n`, the tension of a linear element, the cap fades out as the end
state crosses the rest length, so the residual stays continuous in :math:`\mathbf{q}_{n+1}`. A
cap on the slack end states alone would jump there, by up to :math:`\alpha_f T_n` for a turned
element. The cap does not act on an element that ends above :math:`\alpha_f/(1 - \alpha_f)\,T_n`
(0.4 :math:`T_n`), nor on one that keeps its direction and ends taut, nor (but for the share of
its dashpot, below) on one slack at :math:`t_n`: those elements, every element going taut (where the force blend dissipates), and
every line that allows compression keep the force blend. In the slack-cable case above the
internal forces created 2.7e8 J over 20 s with the configuration blend, 6.7e7 J with the force
blend alone, 0.19 J with a cap on :math:`e_n - e_{n+1}` (the turn of the releasing segments) and
4e-4 J (round-off) with the projected cap. The fairlead peak is 0.10 MN at
:math:`\Delta t` = 2.5 ms, which is not a converged peak. The undamped ``EI = 0`` deck has no
converged snap peak: the peak rises as :math:`\Delta t` falls (0.32 to 0.46 MN at microsecond
steps, also with an explicit lumped-mass solver), as single segments rattle, and falls with
mesh refinement at a fixed step; its 20 ms averages converge to 0.083 MN at the fairlead and
0.047 MN at the anchor, the slack-to-taut event, and converged finite-EI runs give 0.093 MN at
the fairlead and 0.057 MN at the anchor (see :doc:`modeling`, snap loads on slack lines). For
a linear element the
force blend and the cap reduce to the configuration blend, so the linear spectral properties and
the second-order accuracy are unchanged.

The segments whose tension comes from a constitutive law, the viscoelastic and Syrope segments
(whose law enters the step as a dynamic load), are capped in the same way: :math:`T_n` is the
law's tension at the committed state, the force :math:`\mathbf{r}_n` carries, with the same
:math:`e_n` and :math:`W_n = \tfrac{1}{2} T_n e_n`. For the viscoelastic law at rest :math:`W_n`
is the energy of its two springs, which both carry :math:`T_n` and whose stretches add up to
:math:`e_n`; for the Syrope law, whose loading curve stiffens, it bounds the energy below the
curve from above. A law's tension is not proportional to the stretch: damping or the lagged
internal state can carry :math:`T_n` at a vanishing :math:`e_n`, where the secant
:math:`T_n/e_n` is unbounded and the cap would switch off within a band of width about
:math:`e_n`, nearly a jump for the Newton iteration. The cap therefore estimates the end
tension as :math:`\hat T_{n+1} = k\,e_{n+1}` with :math:`k = \min(T_n/e_n, k_n)`, :math:`k_n`
the law's axial stiffness at the committed state (:math:`EA_D/l_0` for the viscoelastic law,
:math:`K_1/l_0 = (\alpha + \beta T_\text{mean})/l_0` for Syrope). In general the blend of an
element returns at most :math:`W_n + (1 - \alpha_f)(\hat T_{n+1} - T_{n+1})\,p_{n+1}` over the
step, :math:`T_{n+1}` its actual end tension, and never more than without the cap. For an
elastic segment the two tensions coincide and the bound is :math:`W_n`. A law segment that ends
below :math:`l_0` with no law tension returns at most :math:`W_n` as well; one that ends above
:math:`l_0` with less law tension than the estimate (zero once the slow branch has taken up the
stretch, or below Syrope's minimum strain) can return up to
:math:`(1 - \alpha_f)\,k\,e_{n+1} p_{n+1}` more. With the light cable above made lightly damped
viscoelastic (EA 8e8 | 1.6e9 N, BA 1e8 | 1e6 N s) the anchor peaks at 0.085 MN at
:math:`\Delta t` = 0.1 s with the cap on its
segments (the snap is not resolved at that step, so the peak depends on round-off: other
compilers and platforms give other values) and at 0.145 MN without it, against 0.082 to
0.095 MN at :math:`\Delta t` from 0.5 to 2.5 ms. A taut Syrope line in 4 m
surge that goes slack peaks at 1.64 MN at 0.1 s, against 1.78 MN at 1 and 2.5 ms, with or
without the cap. These figures take every step as given (``off ei0_substeps``); with the
rotation- and snap-resolved sub-steps of the default (below) the two lines peak at 0.062 MN and
1.81 MN. A single peak of an unresolved snap says little: over seven runs whose heave amplitude
differs by up to :math:`3\times10^{-4}` the viscoelastic anchor peaks at 0.056 to 0.079 MN
(mean 0.063 MN) with the sub-steps and at 0.056 to 0.085 MN (mean 0.065 MN) without them.

An elastic segment with axial damping (``BA``) also keeps :math:`\alpha_f T_{d,n}` along
:math:`\mathbf{t}_n`, :math:`T_{d,n}` the tension of its dashpot at :math:`t_n`. A segment that
extends at :math:`t_n` and releases within the step carries that force against the shortening
as well: in the test chain (dashpot tension 1.6 to 62 times the elastic one) the blend of a
segment that turns and releases returned up to 2750 :math:`W_n` with only its elastic share
capped.
The dashpot pushes as well as pulls, so its end share
:math:`(1 - \alpha_f) T_{d,n+1}\mathbf{t}_{n+1}` acts at a slack end state too, and it stores no
energy, so the budget stays :math:`W_n`. The cap covers the dashpot with a weight :math:`\phi`
that is 1 while the end state is at or below :math:`l_0` and falls linearly to 0 at
:math:`l_0 + c\,e_n`, :math:`c = \alpha_f/(1 - \alpha_f)` (the end stretch below which the cap
can act on an elastic segment): the kept force :math:`\alpha_f (T_n + \phi T_{d,n})` is replaced
by :math:`N/p` when that is smaller, with
:math:`N = \max(W_n + (1 - \alpha_f)(\hat T_{n+1} + \phi T_{d,n+1})\,p_{n+1}, 0)` and
:math:`T_{d,n+1}` the dashpot tension the residual carries at
:math:`(\mathbf{q}_{n+1}, \mathbf{v}_{n+1})`; the tangent carries its dependence on
:math:`\mathbf{q}_{n+1}` through :math:`\mathbf{v}_{n+1}` (the factor
:math:`\gamma/(\beta\Delta t)`). Over a step in which it shortens along :math:`\mathbf{t}_n`
(:math:`p > 0`; the cap leaves the other steps alone) the blend of such a segment then returns
at most :math:`W_n + (1 - \phi) D`, :math:`D = \alpha_f T_{d,n} p - (1 - \alpha_f)
T_{d,n+1} p_{n+1}` the work of its uncapped blended dashpot, except when the end share alone
returns more than :math:`W_n` (:math:`N` would be negative; the capped kept force is then
zero). At
and below :math:`l_0` that is :math:`W_n`. Above :math:`l_0 + c\,e_n` the cap is the elastic one,
so the force-blended dashpot of a taut segment keeps the standard generalised-α treatment, under
which a linear dashpot is dissipative; :math:`\phi` is continuous, and so is the capped force.
The viscoelastic law keeps its total tension, dashpots included, as :math:`T_n` (above).

A damped segment slack at :math:`t_n` (:math:`T_n = 0`, :math:`e_n \le 0`) whose ends separate
there keeps :math:`\alpha_f T_{d,n}` along :math:`\mathbf{t}_n` with no strain energy behind it,
and returns :math:`\alpha_f T_{d,n} p` when the step turns or reverses its ends. It has no
:math:`W_n` (and an empty band, :math:`\phi = 1`); its budget is the dashpot's own one-step
dissipation :math:`W_d = T_{d,n}\,|\dot l_n|\,\Delta t`, :math:`\dot l_n` the dashpot's
elongation rate at :math:`t_n` (the axial rate, less :math:`l_n \dot l_0/l_0` while the line
pays out), so that :math:`T_{d,n} = (BA/l_0)\,\dot l_n` and :math:`W_d > 0` whenever
:math:`T_{d,n} \ne 0`. When :math:`p > 0` the kept force :math:`\alpha_f T_{d,n}` is replaced by
:math:`(W_d + N_d)/p` when that is smaller, with the end share's credit
:math:`N_d = \max((1 - \alpha_f) T_{d,n+1} p_{n+1}, 0)`, and the tangent takes the difference as
above (a compressive :math:`T_{d,n}` is capped alike when :math:`p < 0`). The kept dashpot share
of an element slack at the step start returns at most its own one-step dissipation
:math:`T_{d,n} |\dot l_n| \Delta t` plus the end share's credit. The capped force grows without
bound as :math:`p \to 0^+`, so it is continuous there; it acts only where
:math:`\alpha_f |p| > |\dot l_n| \Delta t`, a turn or reversal well beyond the step-start motion
whose end share does little work (a reversal along the chord feeds the end share's dashpot,
whose credit covers it). In the test chain the kept share returned up to 46 times
:math:`W_d + N_d` before the cap covered slack starts. Taut-start and undamped segments are
unchanged.

The one-sided seabed contact is not capped. A node that leaves the floor within a step keeps
:math:`\alpha_f` of its step-start contact force :math:`N_n` for the whole step: over a lift-off
distance :math:`d` it returns at most :math:`\alpha_f N_n d` to the motion, against the energy
:math:`\tfrac{1}{2} N_n g_n` of the penalty spring at the penetration :math:`g_n` (millimetres).
The excess is the step-start support acting for :math:`\alpha_f` of a step longer than it should,
an impulse of at most :math:`\alpha_f N_n \Delta t` per lift-off that vanishes with
:math:`\Delta t`; the contact law's sloped-floor normal and the friction anchors, which the step
does not see, leave no energy bound as simple as the segments'. Seabed damping and friction are
dissipative and keep the plain force blend as well. The effective tangent is

.. math::

   \frac{\partial\mathbf{G}}{\partial\mathbf{q}_{n+1}}
   = \frac{1 - \alpha_m}{\beta\,\Delta t^2}\,\mathbf{M}
   + (1 - \alpha_f)\,\mathbf{K}_q
   + (1 - \alpha_f)\,\frac{\gamma}{\beta\,\Delta t}\,\mathbf{K}_v ,

where :math:`\mathbf{K}_q = \partial(\mathbf{f}_\text{int} - \mathbf{f}_\text{ext})/\partial\mathbf{q}`
and :math:`\mathbf{K}_v = \partial(\mathbf{f}_\text{int} - \mathbf{f}_\text{ext})/\partial\mathbf{v}`
collect the structural, damping, drag, contact, and friction terms, and :math:`\mathbf{M}`
includes the added mass. On the ``EI = 0`` path the added-mass contribution also carries its
configuration derivative.

**Newton iteration.** An ``EI = 0`` step starts from the Newmark predictor
:math:`\mathbf{q}^{(0)}_{n+1} = \mathbf{q}_n + \Delta t\,\mathbf{v}_n + \Delta t^2(\tfrac{1}{2} - \beta)\,\mathbf{a}_n`
(the acceleration guess :math:`\mathbf{a}^{(0)}_{n+1} = \mathbf{0}`). A Hermite step with the
force blend (the default) starts from the constant-acceleration predictor
:math:`\mathbf{q}^{(0)}_{n+1} = \mathbf{q}_n + \Delta t\,\mathbf{v}_n + \tfrac{1}{2}\Delta t^2\,\mathbf{a}_n`
when the committed acceleration balances the committed force :math:`\mathbf{r}_n`,
:math:`\lVert\mathbf{M}\mathbf{a}_n + \mathbf{r}_n\rVert \le \tfrac{1}{2}\lVert\mathbf{M}\mathbf{a}_n\rVert`
over the translational free DOFs, and from the Newmark predictor otherwise (and always with
``False alpha_force_blend``): while an
under-resolved mode rings, a loosely converged step would keep the extrapolated acceleration,
whereas the zero guess damps it. A failed constant-acceleration attempt is re-solved from the
Newmark predictor. The test uses only the committed state, so a restart is exact.
The ``EI = 0`` path uses an Armijo line search on :math:`\tfrac{1}{2}\lVert\mathbf{G}\rVert^2`
and converges when :math:`\lVert\mathbf{G}\rVert_\infty` relative to the larger of the external
load and the initial residual falls below the relative tolerance, or below the absolute
tolerance. Two near-tolerance cases are also accepted. When the iteration budget is spent or
the line search stalls, a residual within twice the relative tolerance (never looser than
:math:`\sqrt{\epsilon}`) is converged. A residual that stops contracting is converged when it is
below :math:`10^{-4}` of the force scale and within the round-off floor
:math:`\epsilon\,\max\lvert q\rvert\,\lVert\mathbf{A}\rVert_\infty` of the effective operator
:math:`\mathbf{A}`, which no Newton step can reduce (a finely meshed stiff line at small time
steps sits there). The Hermite path uses a backtracking line search that halves the step until the
residual decreases; its convergence norm divides each translational residual by a force scale
frozen at the predictor and each tangent-DOF residual additionally by the nodal tributary
length. The force scale is the largest inertial or residual entry, bounded below by 1 N, by the
peak element weight, and by the round-off floor
:math:`16\,\epsilon\,\max\big((EA + BA\,\gamma/(\beta\,\Delta t))/L_0\big)\,x_\text{ref}/\text{tol}`
of the axial forces (:math:`x_\text{ref}` the largest coordinate magnitude or element length;
the axial damping takes the strain rate from the Newmark velocity, whose rounding is
:math:`\gamma/(\beta\,\Delta t)` times that of the coordinates). The
deck defaults are relative tolerance :math:`10^{-8}`, absolute tolerance :math:`10^{-14}`, 30
iterations, and 12 backtracks (option ``dynamic_solver``). Option ``modified_newton`` reuses the
factorised tangent within a step while each iterate reduces the residual to at most a quarter
of the previous one, and rebuilds it otherwise; it does not relax the tolerance.

A standalone Hermite step on the constant-acceleration branch (so only with the force blend)
also starts from the previous step's factorised tangent, under the same quarter-contraction
rule for at most three iterations, and must reach :math:`0.3` of the tolerance while on it (a
reused factor converges linearly, so this keeps the result as close to the converged solution
as a fresh tangent's last quadratic step). If a step on the reused factor still needs as many
factorisations as the last fresh step, the reuse saved nothing: the following steps then
factorise fresh, for 1 step after the first such step, 2 after the second in a row, and so on,
doubling up to 32 steps. A step that fails on the reused factor is re-solved on a fresh one.
Cables run through the coupling aggregate
(OpenFAST, FAST.Farm, and mixed mooring-and-cable decks) factorise every step, because the
reused factor is not part of the checkpoint state.

**Prescribed motion.** Prescribed DOFs (a moving fairlead or hang-off) are held at their
target position during the Newton solve; their prescribed velocity and acceleration enter the
free-DOF residual through the mass and stiffness coupling. At initialisation, and after a
non-stepping ``motionFile`` boundary commit, the initial acceleration solves
:math:`\mathbf{M}_{ff}\,\mathbf{a}_f = \mathbf{f}_f - \mathbf{M}_{fp}\,\mathbf{a}_p`, so an
accelerated fairlead loads the adjacent free DOFs through the off-diagonal consistent mass. The
core does not ramp prescribed motion; ramp it from rest over at least one wave period to avoid a
start-up transient.

**Adaptive step subdivision.** If a step fails to converge, or (Hermite path) converges but
changes the chord of any element (the relative position of its two nodes) by more than 20 % of
its length, turns any nodal tangent by more than 15°, or shrinks a nodal tangent magnitude
:math:`\lvert\mathbf{m}\rvert` below 0.01 (a singular parametrisation), the step-start state is restored and the
same interval is re-advanced as
:math:`n` substeps of :math:`\Delta t/n`, with :math:`n = 4, 16, 64, 256, 1024` (cap set by
``recovery_max_substeps``, 4 to 65536). Inside the interval, prescribed position, velocity, and
acceleration follow one quintic (:math:`C^2`) trajectory that lands exactly on the target
values at :math:`t + \Delta t`; host fluid fields and the start-of-interval added mass are held.
Every attempt starts from the complete committed state, including constitutive history. The
host time grid and output times are unchanged, and the run summary reports how many intervals
were subdivided and the largest subdivision used. If the finest subdivision fails, the
interval-start state is restored and the run stops with a named error. A rigid translation of
the line, however fast, changes no chord and no tangent, so it never triggers a subdivision.

``EI = 0`` lines stepped together as one line system (lines joined at ``Free``/``Connect``
points or objects, and the OpenFAST and C-API coupled routes) recover a step that stalls by
halving instead: the interval is re-advanced as two half steps, recursively down to
:math:`\Delta t/64`, with the prescribed motion at each midpoint interpolated linearly between
the interval-start and target position, velocity, and acceleration. If the halves do not
complete the interval, the interval-start state is restored and the full step is re-run, so no
partly subdivided state is ever committed.

**Rotation- and snap-resolved sub-steps** (``ei0_substeps auto``, the default). A converged
``EI = 0`` step is measured against its committed start: the largest chord turn
:math:`\theta` of a segment that ends the step above :math:`10^{-3}\,T_\text{max}`, the
largest step-start tension, and whether a segment slack at the start ends above
:math:`T_\text{max}/4` while the axial wave crosses it more than once in the step
(:math:`\Delta t\,c/l_0 > 1`, :math:`c` from the dynamic axial stiffness as in the run audit
below); a step that resolves the axial wave resolves the snap as given. The tensions are those
the run audit takes, the elastic tension of a plain segment and the law's tension of a
viscoelastic or Syrope one, with the step's unstretched lengths, and :math:`T_\text{max}` is at
least :math:`10^{-3}` of the line's initial tension, so a line slack all over at the step start
does not count barely taut segments. (A floor at the initial tension itself raised the snap
threshold in the slack phases of the Lozon semitaut line below, whose anchor peaks then came
out up to 29 % high.) A
segment slack at the step start counts for the turn: counting only segments taut at both ends
of the step left the Lozon semitaut anchor peaks (below) up to 5 % high on average and up to
25 % high in single runs. When :math:`\theta` exceeds ``ei0_substep_angle``
:math:`\theta_s` (default 1°), or such a snap occurred, the interval is solved again from the
same committed state, constitutive and friction states included, in
:math:`n = \max(4, \lceil\theta/\theta_s\rceil)` equal sub-steps, at most ``ei0_substep_max``
(default 16), with the prescribed motion on the quintic trajectory of the recovery above and
the last sub-step on the target state. The trial step under-turns a line whose rotation it does
not resolve, so the sub-stepped interval is measured again; when its turn needs more sub-steps
it is solved once more with them. If a sub-step does not converge, the plain step's own
result is kept. A step recovered after a stall (above) and the halves of a line-system step
halved after a failure take their sub-steps as given; when the halves fail too, the full step
is re-run as the nominal step, sub-steps included. The decision uses only the committed state,
the step inputs and the line's initial tension, so a restart repeats it, and the host time
grid, output and coupling times are unchanged. Every route that steps ``EI = 0`` lines uses it
(standalone lines and line systems, OpenFAST, FAST.Farm and the C API), except the lines
attached to the bodies, rods and points of the monolithic body and point coupling, whose
junction Newton needs the end reaction and condensed end tangent of the nominal step (a line of
such a deck whose ends are all fixed or anchored is sub-stepped); ``off`` takes every step as
given, and ``False alpha_force_blend`` turns it off unless the deck sets it. A step that
triggers costs the plain step and usually four sub-steps; at most it costs the plain step and
three passes of ``ei0_substep_max`` sub-steps, once for each object sub-step where bodies or
rods sub-cycle the lines.

At ``dtM`` 0.1 s a taut segment of the Lozon 80 m all-chain mooring turns by up to 6° per step
under 5 m / 7 s heave. Over seven runs whose heave amplitude differs by up to
:math:`3\times10^{-4}` (the snap peaks at that step vary by 15 to 20 points from one run to the
next), the fairlead and anchor maxima are then 15 % and 17 % below a 0.25 ms run with the force
blend and 10 % and 18 % below it with the configuration blend; the release cap acts in 0.3 % of
the element steps, never within 0.5 s of a peak, and removing it changes the cycle maxima by less
than 1 %. The peaks follow the algorithmic damping instead: 28 % and 31 % low at
:math:`\rho_\infty = 0`, 10 % and 40 % high at 0.6. With ``auto`` they are 4 % and 8 % low
(1 % high and 4 % low against the reference sampled on the same 0.1 s output grid), and the
anchor maxima of the 200 m semitaut mooring in 10 m / 14 s and 5 m / 7 s surge, 16 % and 26 %
high taken as given, are 4 % high and 2 % low (over thirteen runs 5 % high and 0.3 % low, single
runs from 4 % low to 21 % high).
Two or three sub-steps of a step that turned by 1 to 3° left those anchor peaks 8 % high on
average (up to 22 %); four bring them within 3 %, hence the minimum. Resolving the sub-steps
of a step recovered after a stall as well left them 9 % high, so the recovery takes its sub-steps
as given. Over the 20 motions of the Lozon mooring envelope at ``dtM`` 0.1 s the march takes
1.67 times as long as with plain steps, 1.6 to 2.5 times on the 5 m / 7 s and 10 m / 14 s
motions.

**Step size.** Being implicit, the scheme is not bound by the explicit axial-wave limit. In the
snap-load verification a slack line snapping to about 10 MN integrates stably at
:math:`\Delta t = 20\,\mathrm{ms}`, well above the explicit limit of 3.2 ms, with the peak
within 1.5% of a 0.5 ms reference (:doc:`validation`). The time step must still resolve the
response of interest and, for explicitly integrated points and bodies (below), their own
stability limit. The standalone driver audits every ``EI = 0`` line on the initial state and at
each output step, and reports at the end of the run:

- the steps ``ei0_substeps auto`` solved in sub-steps, with the largest count, those that needed
  more than ``ei0_substep_max``, and those that kept the plain step;
- the largest turn of the chord of a taut segment in one solver step (the sub-steps of a
  sub-stepped or recovered step count as steps). Above 1 deg it prints a note (with ``auto``
  above 1.1 times the larger of 1 deg and ``ei0_substep_angle``): against a 3.125 ms reference
  on chain catenaries under 5 m heave, 10 m surge and 15 m sway and on a light laid cable under
  10 m sway, the mean and standard deviation of the fairlead tension err by 0.9 % at 1.2 deg per
  step (sway, standard deviation), and by 0.6 % at 1.4 deg and 1.3 % at 2.9 deg (heave, mean),
  in proportion with the turn, and at about 6 deg per step snap-load peaks come out 10 to 20 %
  low (above);
- segments that go from slack to taut above the initial tension in one step while the axial
  wave crosses a segment more than once per solver step (:math:`\Delta t\,c/l_0 > 1`,
  :math:`c = \sqrt{EA/m}` with the dynamic stiffness of the segment, :math:`EA_D` of a viscoelastic
  segment and :math:`\alpha + \beta T` of a Syrope one): the snap peaks are then not resolved in
  time, and the note asks for a confirmation at a smaller ``dtM``;
- non-physical tension spikes. The tension of a segment at one step (its elastic tension, or the
  tension of its viscoelastic or Syrope law at the committed state) is a spike when it exceeds
  four times its own tension one step before and one step after, ten times the largest
  tension anywhere on the line one step before and one step after, and the largest tension of
  the initial state. A physical snap or tension wave persists over the axial transit time and is
  shared by the neighbouring segments, so no line carries such an isolated single-step peak.
  The first spike of a line is reported as a warning with its segment, tension and time, at most
  once per line, and the run summary gives the count. Over the 746 decks of a dynamics
  robustness campaign it warns in none of the 704 runs that complete. Applied to the same
  decks' configuration-blend results it flags 37 of the 49 runs whose segment tensions were 3
  to 370 times those of the force blend, and 1 of the 158 runs within 25 % of them. Spikes
  that persist over several steps (a rattle at :math:`\rho_\infty` near 1) are left to the
  ``maxStrain`` guard and the ``rhoInf`` note.

Attached objects and line ends
------------------------------

Deck ``POINTS``, ``BODIES``, and ``RODS`` records follow the MoorDyn object model
(:ref:`Hall, 2020 <ref-hall2020>`) and are translated into boundary objects of the line system.

- **Fixed, coupled, and vessel points** prescribe the position, velocity, and acceleration of
  line ends.
- **Free points** (``Point3`` buoys, clump weights, connectors) have three translational DOFs.
  Each carries its weight and buoyancy :math:`(\rho V - m)\,g\,\mathbf{e}_z`, point loads, its
  own seabed contact (with ``Mass`` or ``Vol``, see Seabed contact above), and,
  while below the surface, lumped Morison terms
  :math:`\tfrac{1}{2}\rho\,C_dA\,\lvert\mathbf{u}_r\rvert\mathbf{u}_r + \rho V(1 + C_a)\,\dot{\mathbf{u}}_f`
  with added mass :math:`\rho V C_a`. Points are advanced around the implicit line step with
  implicit-Euler kinematics, and the attached line ends' own blocks are linearly implicit: the
  structural mass diagonal, the Morison added-mass block, and the end-segment elastic tangent
  and axial damping, and so is the point's own seabed contact (its stiffness
  :math:`k_\text{Bot} A` and damping :math:`c_\text{Bot} A`). A light or massless connector is
  therefore stable at any :math:`\Delta t`, including under added mass that exceeds the
  structural mass, and neither the end segments nor the footprint impose a
  :math:`\sqrt{k/m_\text{point}}` limit, so the sub-step estimate of the explicit object march
  (below) leaves the points out. The coupling to the
  first interior node, drag, and seabed contact at the end node stay at the step-start
  state; the step fails with a named error if a point's motion becomes non-finite.
- **Rigid6 bodies** have six DOFs, a diagonal inertia about the centre of gravity, and the
  mass matrix about the reference point with the centre-of-gravity offset :math:`\mathbf{c}`
  (coupling blocks :math:`\pm m[\mathbf{c}]_\times` and :math:`-m[\mathbf{c}]_\times^2`, and the
  terms :math:`-m\,\boldsymbol{\omega}\times(\boldsymbol{\omega}\times\mathbf{c})` and
  :math:`m\,\boldsymbol{\omega}\times(\mathbf{c}\times(\mathbf{c}\times\boldsymbol{\omega}))`).
  The weight acts at the centre of gravity and the buoyancy :math:`\rho g \phi V` at the centre
  of buoyancy. The submerged fraction :math:`\phi` is that of an equivalent sphere of volume
  :math:`V` at the centre of buoyancy, :math:`r_e = (3V/4\pi)^{1/3}`, immersed to
  :math:`h = \min(2r_e, \max(0, \eta - z_b + r_e))`:
  :math:`\phi = h^2(3r_e - h)/(4r_e^3)`, zero when dry and continuous through the surface
  (``bodyWetting moordyn``: :math:`\phi = 1`, as in MoorDyn). A body with linear hydrostatic
  restoring :math:`C_{33}`, :math:`C_{44}`, :math:`C_{55}` (a surface-piercing hull) keeps
  :math:`\phi = 1`; its restoring moment is
  :math:`-C_{44}\tau_1\mathbf{h}_1 - C_{55}\tau_2\mathbf{h}_2`, with :math:`\boldsymbol{\tau}` the
  tilt rotation vector of the body axis that was vertical at the reference pose,
  :math:`\mathbf{h}_1` the horizontal direction of the body x axis and
  :math:`\mathbf{h}_2 = \mathbf{e}_z\times\mathbf{h}_1`, so it does not depend on the heading.
  Lumped Morison drag on the relative velocity (also in still water), fluid inertia (omitted with
  ``bodyHydro moordyn``), and isotropic translational added mass :math:`\rho\phi V C_a` act at
  the reference point, each scaled by :math:`\phi`, and seabed contact acts over a fixed 1 m²
  reference area. The line-end forces act at their attachment offsets with lever moments.
  Accelerations follow the Newton–Euler equations about the reference point; the orientation
  is advanced on SO(3).
- **Rods** are rigid cylinders with a six-DOF rigid state, advanced in the same way (or
  prescribed, for coupled and vessel rods). Their loads are integrated over the ``NumSegs``
  segments of the axis. A cross-section normal to the axis :math:`\mathbf{q}` at angle
  :math:`\varphi` to the vertical is wet below the local free surface over the circular segment
  :math:`A_w(h_w) = r^2\arccos(-h_w/r) + h_w\sqrt{r^2 - h_w^2}`,
  :math:`h_w = (\eta - z)/\sin\varphi`, whose centroid lies
  :math:`-\tfrac{2}{3}(r^2 - h_w^2)^{3/2}/A_w` from the section centre along
  the in-section up-slope direction. With :math:`\eta` linear between the segment end stations,
  each segment splits into fully wet, partially wet, and dry parts at known positions; the wet
  part is integrated with two Gauss points and the partially wet part with ten Gauss points in
  :math:`\theta`, :math:`h_w = r\sin\theta`. The buoyancy :math:`\rho g A_w` per unit length acts
  vertically at the wet centroid, so the hydrostatic force and moment are those of the displaced
  volume of the cylinder, end caps included, at any tilt: a surface-piercing rod carries the exact
  waterplane restoring (second moment :math:`\pi d^4/64`), and the loads are continuous in the
  submergence. Each station also carries, with its wet fraction :math:`f = A_w/A`, the drag
  :math:`\tfrac{1}{2}\rho d f [C_d\lvert\mathbf{u}_n\rvert\mathbf{u}_n + \pi C_{d,ax}
  \lvert\mathbf{u}_t\rvert\mathbf{u}_t]`, the fluid inertia, and the directional added mass
  :math:`\rho A f [C_a(\mathbf{I} - \mathbf{q}\mathbf{q}^T) + C_{a,ax}\mathbf{q}\mathbf{q}^T]`,
  assembled at its offset into a 6×6 added-mass matrix about the rod centre (rotational block
  :math:`C_a \rho A \int s^2\,\mathrm{d}s` about the transverse axes). Each wet end carries the
  MoorDyn end terms: added mass :math:`\rho C_{a,end} V_\text{end}\mathbf{q}\mathbf{q}^T`
  (:math:`V_\text{end} = \tfrac{2}{3}\pi r^3`), axial drag
  :math:`\tfrac{1}{2}\rho C_{d,end} A\lvert u_q\rvert u_q\mathbf{q}`, axial fluid inertia, and,
  in deck waves, the linear dynamic pressure :math:`-(p_\text{dyn} - \rho g\eta^*)A\mathbf{n}_e`
  on the end cap (:math:`\eta^*` the waterline elevation of a surface-piercing rod, zero for a
  submerged one), which carries the axial Froude–Krylov force. Seabed contact is distributed over
  :math:`\max(20, \text{NumSegs}) + 1` stations with :math:`k_\text{Bot}\,d\,\Delta l`.
- **Rods fixed to a body** move with it: with :math:`\mathbf{r}` from the body reference point to
  the rod centre and :math:`\mathbf{T} = [[\mathbf{I}, -[\mathbf{r}]_\times], [\mathbf{0}, \mathbf{I}]]`,
  the rod's structural and added mass enter the body mass matrix as
  :math:`\mathbf{T}^T\mathbf{M}_c\mathbf{T}`, its loads as :math:`(\mathbf{F},
  \mathbf{M} + \mathbf{r}\times\mathbf{F})`, with the velocity terms
  :math:`-\mathbf{M}_c[\boldsymbol{\omega}\times(\boldsymbol{\omega}\times\mathbf{r}); \mathbf{0}]`
  and the rod's gyroscopic moment. A **pinned rod** turns about its fixed End A: with the arm
  :math:`\mathbf{r}` from the pin to the centre its acceleration is
  :math:`\mathbf{a} = \boldsymbol{\alpha}\times\mathbf{r} + \boldsymbol{\omega}\times(\boldsymbol{\omega}\times\mathbf{r})`,
  and the 6×6 equations are reduced to the three rotational unknowns.
- A **rod pinned to a body** keeps its End A on the body's pin point :math:`\mathbf{p}` (body
  frame) and turns with its own rotation. In reduced coordinates the unknowns are the body twist
  acceleration :math:`\mathbf{x}_b` and the rod's angular acceleration :math:`\mathbf{y}`; the rod's
  centre twist acceleration is
  :math:`\mathbf{X} = \mathbf{G}_b\mathbf{x}_b + \mathbf{G}_c\mathbf{y} + \mathbf{c}` with
  :math:`\mathbf{G}_b = [[\mathbf{I}, -[\mathbf{R}\mathbf{p}]_\times], [\mathbf{0}, \mathbf{0}]]`,
  :math:`\mathbf{G}_c = [[-[\mathbf{l}]_\times], [\mathbf{I}]]` (:math:`\mathbf{l}` from the pin to
  the rod centre) and
  :math:`\mathbf{c} = [\boldsymbol{\omega}_b\times(\boldsymbol{\omega}_b\times\mathbf{R}\mathbf{p})
  + \boldsymbol{\omega}\times(\boldsymbol{\omega}\times\mathbf{l}); \mathbf{0}]`. The equations are
  the virtual work of body and rods,
  :math:`\mathbf{M}_b\mathbf{x}_b - \mathbf{F}_b + \sum_k\mathbf{G}_{b,k}^T(\mathbf{M}_k\mathbf{X}_k - \mathbf{F}_k) = \mathbf{0}`
  and :math:`\mathbf{G}_{c,k}^T(\mathbf{M}_k\mathbf{X}_k - \mathbf{F}_k) = \mathbf{0}` for each pinned rod
  :math:`k`: the pin passes the rod's force to the body and no moment, and the rod's rotation
  feels the pin acceleration. (MoorDyn adds every body-attached rod, pinned or not, to the body's
  equations with its full force, moment and mass; its pinned-rod rotation includes the pin
  acceleration, taken from the body acceleration the rod's kinematics were last set with, so the
  two formulations can differ by that lag for a pinned rod on an accelerating body.)
- A **zero-length rod** (``NumSegs`` 0) is a point-like connector: it has no mass, volume or side
  loads, and its end terms act along an axis it does not have, so it reduces to a massless point
  at End A (``Free``, ``Fixed``, ``Coupled`` or on a body).

**Rigid-body initial condition.** Free Rigid6 bodies, free rods and pinned rods start at their
static equilibrium, solved jointly with the ``Free``/``Connect`` points. The unknowns are each
body's position and a rotation-vector increment on SO(3) (for a free rod only the two rotations
normal to its axis), each pinned rod's two rotations about its pin, and each point's position.
A pinned rod's residual rows are its moment about the pin; its net force acts on its parent body
at the pin (a rod pinned to a fixed point has none, and a ``CoupledPinned`` rod in OpenFAST is
balanced about its pin at the platform's initial pose). A ``CoupledPinned`` body in OpenFAST
keeps its position unknowns held at its node (their force rows carry the host's reaction, not a
residual) and balances the moment about the node with its three rotations. Its lines and its
centre of gravity may lie on one axis through the node, about which it then turns neutrally: the
Jacobian has that spin as a null vector, to which the residual is orthogonal, and the Newton
step of a deck with such a body is the minimum-norm Gauss-Newton step
:math:`(\mathbf{J}^T\mathbf{J} + 10^{-10}\mathbf{D})\,\delta\mathbf{x} = -\mathbf{J}^T\mathbf{r}`
(:math:`\mathbf{D}` the floored diagonal of :math:`\mathbf{J}^T\mathbf{J}`), which does not spin it.
A free or pinned rod that no line
attaches to (nor, for a rod pinned to a body, any line of its body) is not an unknown: it keeps
its deck pose and starts at rest there. A deck with pinned rods takes the
central-difference Jacobian of the full residual. A finite-EI line enters with its axial
stiffness and weight only. The residual is the net force and moment of the loads the
dynamic step applies at rest: weight, buoyancy and hydrostatic restoring, steady-current drag,
and seabed contact, plus the end force of every attached line, re-solved to its static
equilibrium for the moved ends. Moments are divided by the object's length scale (its largest
attachment arm or its half length) and rotations multiplied by it, so forces and moments carry
comparable weight. A trust-region Newton iteration drives the residual below :math:`10^{-9}` of
the largest weight or line force; the first trust radius is the first Newton step. Its Jacobian
takes the objects' own loads by central differences and each line's contribution analytically,
from the line's static tangent condensed onto its two end nodes,
:math:`\mathbf{K}_c = \mathbf{K}_{ee} - \mathbf{K}_{ei}\mathbf{K}_{ii}^{-1}\mathbf{K}_{ie}`
(axial and geometric stiffness of the tension-only law plus the seabed penalty). Only the lines
attached to a moving object are re-solved. Each re-solve starts from the line's previous shape
rotated and stretched onto the new chord, and falls back to the cold static solve if that start
does not converge. At a slack line whose condensed stiffness vanishes, the iteration switches to
a central-difference Jacobian of the full residual.

A step is accepted when it lowers the residual, or when the Newton step from the trial point is
at most half the current one and half the shortest Newton step of the solve so far (a Newton step
that grows again near a slack/taut kink of a line must not reset that measure, or the steps can
cycle). The second test lets an object swing along a curved valley: a
buoy on a stiff taut line moves on a sphere about the anchor, and every straight step
overstretches the line by its sagitta, so the force residual alone would reject any step
longer than a few centimetres. After each accepted step the rotation unknowns are folded into
the object's orientation and reset to zero, so the analytic Jacobian stays exact however far
the object has turned. A single step turns an object by at most 0.25 rad. A converged
equilibrium must be stable: the symmetric part of the stiffness
:math:`-\partial\mathbf{R}/\partial\mathbf{x}` must be positive semi-definite. If the solve fails or ends on an unstable
equilibrium (for example a body upside down or yawed against its lines), it restarts from the
deck pose with the rotations held until the objects balance in force, then releases them. The
solve stops with an error naming the object if the residual stays above :math:`10^{-6}` of that
force or the equilibrium it reaches is unstable. The
hydrostatic restoring keeps the deck pose as its reference. ``deck bodyIC`` starts from the deck
pose instead, and bodies prescribed by a ``motionFile`` keep their prescribed pose.

**Rigid-body time integration.** Free Rigid6 bodies, Point3 buoys, free and pinned rods and
``Free``/``Connect`` points are stepped monolithically with their ``EI = 0`` lines
(``bodyScheme monolithic``, the default; a deck without lines only when it names it): one implicit
generalised-alpha step in which the objects take every load, the line reactions among them, at
the lines' force level :math:`t_{n+1-\alpha_f}`, :math:`\alpha_f = \rho_\infty/(1 + \rho_\infty)`.
The unknowns are the end-of-step accelerations :math:`\mathbf{x}` of every such junction (a
body's :math:`(\mathbf{a}, \boldsymbol{\alpha})`, a pinned rod's angular acceleration about its
pin, a point's :math:`\mathbf{a}`, a Point3 buoy being the point it is attached at). The bodies'
and rods' inertia sits at the same level (:math:`\alpha_m = \alpha_f`), so their positions and
velocities follow Newmark with :math:`\beta = 1/4`, :math:`\gamma = 1/2`: they have the principal
roots of the trapezoidal rule, second order and free of numerical dissipation (an undamped
linear body conserves its energy exactly), while the lines keep the dissipation of their
:math:`\rho_\infty`; the lines' own :math:`\alpha_m` would add a period error of order
:math:`(1 - \rho_\infty)(\omega\Delta t)^2` to the body modes. The line-end nodes a body or rod
drives follow its Newmark and inertia level inside the line step as well, so their inertia
enters the junction equation consistently. ``Free``/``Connect`` points and Point3 buoys, whose
inertia is largely that of the line ends and whose stiff modes are not sub-stepped, keep the
lines' own generalised-alpha parameters and dissipation. Rotations are on SO(3):
:math:`\Delta\boldsymbol{\theta} = \Delta t\,\boldsymbol{\omega}_n + \Delta t^2[(\tfrac{1}{2} - \beta)\boldsymbol{\alpha}_n + \beta\boldsymbol{\alpha}_{n+1}]`,
:math:`\mathbf{R}_{n+1} = \exp([\Delta\boldsymbol{\theta}]_\times)\mathbf{R}_n`. Each junction's
equation of motion is evaluated at the generalised-alpha level: positions, velocities and
accelerations at :math:`t_{n+1-\alpha_f}` (the orientation on the geodesic between
:math:`\mathbf{R}_n` and :math:`\mathbf{R}_{n+1}`), with the object's mass and
added mass, gyroscopic terms, hydrostatics, drag and seabed contact, and the line loads.

The iteration is a multilevel Newton. For a trial :math:`\mathbf{x}` every attached line is
stepped from its committed state with the resulting end motion prescribed, and returns its
reaction at the alpha level, :math:`\mathbf{f}_e = -\mathbf{R}_E` (the end rows of its own
residual :math:`\mathbf{M}\mathbf{a}_{\alpha_m} + (1 - \alpha_f)\,\mathbf{r}_{n+1} + \alpha_f\,\mathbf{r}_n`),
so the end-node inertia, drag and added mass enter exactly, and its condensed dynamic end
stiffness :math:`\mathbf{K}_e = \mathbf{S}_{EE} - \mathbf{S}_{EF}\mathbf{S}_{FF}^{-1}\mathbf{S}_{FE}`
of the step's effective tangent :math:`\mathbf{S}`, the exact implicit-function derivative of
the reaction with the interior re-solved. The junction Jacobian is the objects' own part
(finite differences of each object's residual, which carry the mass, gyroscopic, hydrodynamic
and contact terms and the turning lever arms) plus
:math:`\beta\Delta t^2\,\boldsymbol{\Gamma}^T\mathbf{K}\boldsymbol{\Gamma}` from the lines, with
:math:`\boldsymbol{\Gamma}` the map from the junction accelerations to the attachment positions. A
Newton step turns an object by at most 0.25 rad. The line re-solves of later iterations start
from the previous solve shifted by the linear map :math:`\mathbf{S}_{FF}^{-1}\mathbf{S}_{FE}` and
reuse its factorisation; the first solve of a step starts from the generalised-alpha predictor
corrected the same way. The condensed stiffness is refreshed every twenty steps, after a step that
needed more than two iterations, and from the third iteration on. The step converges when every
junction residual is within :math:`10^{-6}` of its object's force scale (moments times its size);
the predictor itself is accepted only within :math:`10^{-9}`, so a body at rest does not drift.
Typical steps take two iterations. A step that does not converge in twelve is retried as two
half steps, to a depth of six, and then stops naming the object with the largest residual.

The scheme is implicit in every term, so it needs no sub-stepping for stability: a moored buoy
and a rod spar released out of balance run at :math:`\Delta t` = 0.1 s and 0.5 s. Accuracy is set by
:math:`\Delta t` against the modes of interest: the object period error is the trapezoidal
:math:`(\omega\Delta t)^2/12`, the smallest error constant of any unconditionally stable
second-order method (Dahlquist's second barrier), and twice the :math:`(\omega\Delta t)^2/24` of the
explicit central difference of the staggered scheme. By default (``accuracy bodySubstep``) each
coupling step is therefore divided into equal sub-steps with
:math:`\omega\,\Delta t_\text{sub} \le 0.28 \approx 0.4/\sqrt{2}` for the stiffest body-mooring
frequency estimate below (bodies and rods), which matches the phase accuracy of the staggered
scheme's own sub-steps (:math:`\omega\,\Delta t_\text{sub} \le 0.4`); ``none bodySubstep`` takes the
coupling step as given. The verification tests (CTest ``monolithic_gates``) check: energy of an undamped
linear spring-mass body conserved to :math:`5\times10^{-10}` at :math:`\Delta t` = 0.1 s for any
:math:`\rho_\infty`; observed order 2 in positions and fairlead tensions on the moored buoy and in
surge, heave and pitch on the V-SP spar; gyroscopic precession of a torque-free symmetric top
at second order; and an error no larger than the staggered scheme's at :math:`\Delta t` = 0.1 s and
0.05 s on the moored buoy and rod spar. A finite-EI cable with an end on a moving object, pinned
or clamped, is re-stepped at every outer iteration (*Cables clamped to bodies and rods*, below;
a pinned end returns no moment). Coupling a pinned cable at the predictor instead (stepped once
with the predicted end motion, its end force held through the iterations) is explicit: with
:math:`K_e` the cable's condensed dynamic end stiffness and :math:`m_e` the object's effective mass
along it at the attachment, the error grows from step to step once :math:`K_e\Delta t^2/m_e`
exceeds about 0.85, so a light rod or buoy on a stiff cable diverges from a balanced start.
Standalone decks with a ``motionFile``, a
``FAILURE`` section, or Coupled/Vessel rods, and the OpenFAST and C-API coupled routes, use the
staggered scheme.

``bodyScheme staggered`` selects the staggered central-difference predictor-corrector
(Newmark :math:`\gamma = 1/2`, :math:`\beta = 0`). The body is first moved to
:math:`\mathbf{r}_{n+1} = \mathbf{r}_n + \Delta t\,\mathbf{v}_n + \tfrac{1}{2}\Delta t^2\mathbf{a}_n`
(the rotation likewise on SO(3)). The lines are then stepped to :math:`t_{n+1}` with that end
motion. The end-of-step acceleration :math:`\mathbf{a}_{n+1}` solves the 6-DOF equation of
motion with the resulting line loads and every body load at :math:`t_{n+1}`, and the velocity
is the trapezoidal average :math:`\mathbf{v}_n + \tfrac{1}{2}\Delta t(\mathbf{a}_n + \mathbf{a}_{n+1})`.
Two terms of that solve are implicit, both exact:

- the inertia of the attached line-end nodes, which keeps a body lighter than the line
  inertia it carries free of the partitioned added-mass instability;
- the velocity derivative of the body drag and seabed damping.

The line loads therefore include the lines' own response over the step (waves and drag on the
lines) without a one-step lag. The scheme is second order and adds no numerical damping, so a
moored body's response converges with :math:`\Delta t`. The line position and velocity
derivatives at the attachment are not used: they describe the end segment with its neighbouring
node held fixed, and so overstate the stiffness and damping the body actually feels. The position
update is explicit. Each coupled step is therefore divided into equal sub-steps with
:math:`\omega\,\Delta t_\text{sub} \le 0.4`, where :math:`\omega` estimates the stiffest
body-mooring frequency. Each attached line acts as the directional spring
:math:`k_a\mathbf{t}\mathbf{t}^T + (T/L)(\mathbf{I} - \mathbf{t}\mathbf{t}^T)` (:math:`\mathbf{t}`
the chord direction, :math:`L` the chord length, :math:`k_a = 1/\sum l_0/EA`, :math:`T` the end
tension), carried to the reference point and added to the hydrostatic restoring and to the
seabed contact; the inertia is the structural plus added mass. The contact springs are the
penalty springs of the seabed model (:math:`k_\text{Bot}\,d\,\mathrm{d}l` at each contact station
of a rod, :math:`k_\text{Bot}` over 1 m² at a body's reference point) that can act within the
coming step. A station at arm :math:`\mathbf{s}` from the rod centre moves with
:math:`\mathbf{v} + \boldsymbol{\omega}\times\mathbf{s}`, and its acceleration is bounded by
:math:`a_s = |\mathbf{a}| + |\boldsymbol{\alpha}\times\mathbf{s}| + |\boldsymbol{\omega}|^2|\mathbf{s}| + g`
(:math:`\mathbf{a}`, :math:`\boldsymbol{\alpha}` the committed accelerations, the free fall added
so that a first step without them counts); its reach
:math:`\rho = \Delta t\,|\mathbf{v} + \boldsymbol{\omega}\times\mathbf{s}| + \tfrac{1}{2}\Delta t^2 a_s`
bounds its travel in every direction, vertical and horizontal. The station counts when its height
above the highest floor within the horizontal distance :math:`\rho` (the depth on a flat seabed;
on a bathymetry grid the highest node of the cells the surrounding box overlaps, raised by
:math:`0.05` of their range for the crease rounding) is at most :math:`\rho` plus the rod radius.
An object about to land, sliding towards a shallower bed or turning a station onto it is thus
resolved as well as one at rest on the bed. A spring :math:`k` at arm :math:`\mathbf{a}`
adds :math:`k` in heave and :math:`k a_y^2`, :math:`k a_x^2` in roll and pitch. A rod near the
free surface adds its waterplane stiffness in the same way: :math:`\rho_w g\,d\,\mathrm{d}l` at each
station whose cross-section can cross the (held or wave) surface within the step, and
:math:`\rho_w g\,\pi d^2/4` between each pair of stations whose axis can cross it, which together
bound the elliptical waterplane of any crossing; its inertia is then the structural one, since
the added mass changes as it crosses. A finite-EI cable on a body or rod of the staggered march,
whose end force the march returns explicitly, adds the directional spring above with
:math:`k_a = 1/\sum l_0/EA` and its current end tension. The normal seabed damping and the
regularised friction (a damper :math:`\mu N/\sqrt{v^2 + v_\text{reg}^2}`, :math:`\mu N/v_\text{reg}`
at rest) are applied implicitly, the friction as that secant coefficient, so they set no limit,
nor does the seabed contact of a ``Free``/``Connect`` point or a Point3 buoy, which its point
step treats as linearly implicit (see Free points above), so the estimate leaves it out;
the monolithic scheme carries the contact and the hydrostatics in its Jacobian, and its accuracy
sub-steps (above) leave them out. A step that would need more than 256 sub-steps is warned about
once per run. The estimate omits the line-end inertia and the coupling between
the diagonal terms, so it can understate the coupled frequency by about a factor 1.6; stability
alone (the central-difference bound :math:`\omega\,\Delta t < 2`) would allow a limit near 1.
The limit of 0.4 is set by accuracy: a rod released out of balance at :math:`\Delta t = 0.1` s
follows the fairlead-tension transient of a :math:`\Delta t = 0.005` s run within 1.5 %.
The objects' own terms (hydrostatic restoring, a rod's waterplane, seabed contact, and the
swing of a pinned rod below, about its pin on every route, with its parent body's pin
acceleration and the reduced mass :math:`m m_b/(m + m_b)` for a rod pinned to a body) enter
whether or not a line is attached: a deck without lines, which marches its
objects by the same explicit scheme, and a staggered deck whose only lines are finite-EI cables
are sub-stepped for them as well.
Both schemes start from the instantaneous acceleration of the initial state.

On the coupled route a ``Pinned`` or ``CoupledPinned`` rod advances only its rotation in this
way; its centre then follows the pin at :math:`t_{n+1}` (fixed, or placed by the host), so End A
drives its lines with the pin motion exactly. The end-of-step angular acceleration solves the
reduced pinned-rod equation with
:math:`\mathbf{a} = \mathbf{a}_p + \boldsymbol{\alpha}\times\mathbf{r} + \boldsymbol{\omega}\times(\boldsymbol{\omega}\times\mathbf{r})`,
so the pin acceleration :math:`\mathbf{a}_p` loads the rotation through the rod's inertia, and
the implicit drag acts on the velocity change
:math:`\tfrac{1}{2}\Delta t(\boldsymbol{\alpha}_{n+1} - \boldsymbol{\alpha}_n)\times\mathbf{r}` of the
pinned centre. The sub-step estimate takes the line springs through their arms from the pin
against the rotational inertia about the pin, and adds the rod's own swing about the pin, so a
pinned rod that carries no line is still sub-stepped as the compound pendulum it is. Its weight
and buoyancy act vertically at points :math:`\mathbf{p}_i` from the pin; the first moment
:math:`\mathbf{P} = \sum_i f_i\,\mathbf{p}_i` of these loads turns with the rod, and its length
:math:`|\mathbf{P}| = |W d_g - B d_b|` (weight :math:`W` and buoyancy :math:`B` on the axis at
:math:`d_g` and :math:`d_b` from the pin) is the swing stiffness at the bottom of the swing,
whatever the current pose. The pin acceleration adds :math:`|\mathbf{a}_p|\,|\mathbf{G}|`, with
:math:`|\mathbf{G}|` the first moment of the rod's translational inertia (structural and added)
about the pin, :math:`m d_g` for a dry rod; for the hanging dry rod this is the effective gravity
bound :math:`g + |\mathbf{a}_p| \ge |\mathbf{g} - \mathbf{a}_p|`, taken with the larger of the
step-start and end-of-step pin accelerations. The swing stiffness over the smaller rotational
inertia about the pin across the rod axis, about :math:`3g/(2L)` for a dry uniform rod of length
:math:`L`, adds to the line estimate of :math:`\omega^2`. The buoyancy is that of the wet
length at the evaluated pose; the change of a surface-piercing rod's waterline with its tilt
(an articulated column) enters through the rod's waterplane stiffness about the pin (above).
The host places a ``CoupledPinned`` pin at :math:`t_{n+1}` before the estimate, so
the swing is evaluated with the rod at both its step-start and its end-of-step pin, taking the
larger stiffness and the smaller inertia. The sub-steps move the pin along a straight line; at
the rod's orientation and with the surface held over the step, every slice's clearance to the
surface then changes monotonically and in the same sense, so the wetting, the moment
:math:`W d_g - B d_b` and the added mass are bounded by their values at the two ends, and a step
whose pin crosses the free surface (a light rod lifted out of the water, or a heavy one lowered
into it) is sub-stepped for the stiffer of its wet states. The seabed contact adds its angular
stiffness about the pin, :math:`\sum k\,|\mathbf{a}\times\mathbf{e}_z|^2` over the contact
stations within reach (at both pin poses for a ``CoupledPinned`` rod), so a rod whose far end
rests on the bed is sub-stepped for its contact mode. In a sub-cycled step the host pin's
position,
velocity and acceleration are each interpolated linearly between their step-start values (the End
A motion of the committed rod) and the end-of-step host input, as the host fairleads of the lines
and the ``Coupled`` rods are, so points on one platform keep their relative positions under a
translation within the step. This is second order: between exact end values the interpolated
position departs from the host path by at most :math:`\Delta t^2 \max|\mathbf{a}_p|/8`, the
interpolated velocity is not the derivative of the interpolated position (they differ by
:math:`O(\Delta t\,|\mathbf{a}_p|)`), and a pin moving at constant velocity is reproduced exactly.
A first step without a committed angular acceleration (the aggregate and the C API) takes its
starting one with the pin at its step-start pose; under OpenFAST the rod state mirror reloaded
at the initial output call carries the committed accelerations of the initial condition, zero
for the static start, so a start out of equilibrium (``bodyIC deck``) begins its first step
from rest acceleration, an error of order :math:`\Delta t` in that step's velocity, as for a
free rod.

The host receives the rod's net load less its inertia at the pin, and no moment. It is the
direct feedthrough of the pin acceleration at the rod's current state: the pin position,
velocity and acceleration are those the host last set (re-derived from the rod's End A motion,
so that a checkpoint restart reproduces the force between steps bit for bit), the rotation, the
angular velocity and the held fluid are the committed ones, and the angular acceleration is
solved again for the pin's current acceleration. A CalcOutput at an off-step pin acceleration
therefore returns the rod's effective inertia about the pin. The attached lines keep their
committed interior state, accelerations included, as in every output evaluation, and their end
loads are taken at the end accelerations of the re-solved rotation: the solve moves the end-node
inertia from the end accelerations the system holds with the lines' coupled mass block
:math:`\mathbf{M}_{cc}` (structural and added mass; the step's corrector instead lets the line
interior follow, :math:`\mathbf{M}_{cc} - \mathbf{M}_{cf}\mathbf{M}_{ff}^{-1}\mathbf{M}_{fc}`). At a
held interior the end loads are linear in the end accelerations, so the force does not depend on
the end accelerations the line loads were evaluated with. MoorDyn-F's coupled pinned rod keeps
the same pin acceleration term in its rotation equation and returns the same force: its output
call evaluates the rod's state derivative at the current input first (its lumped line mass has
no interior coupling).

A ``CoupledPinned`` body is pinned the same way at its reference point, which is its node: its
translation is the host's, :math:`\mathbf{a} = \mathbf{a}_p`, and its rotation solves the moment
equation about the node,
:math:`\mathbf{M}_{rr}\boldsymbol{\alpha} = \mathbf{M} - \mathbf{M}_{rt}\mathbf{a}_p - \boldsymbol{\omega}\times(\mathbf{I}_p\boldsymbol{\omega})`,
with :math:`\mathbf{I}_p = \mathbf{R}\mathbf{J}\mathbf{R}^T - m[\mathbf{c}]_\times^2` the inertia
about the node for the centre of gravity at :math:`\mathbf{c}`,
:math:`\mathbf{M}_{rr} = \mathbf{I}_p` plus the attached lines' end-node inertia through their
arms, and :math:`\mathbf{M}_{rt} = m[\mathbf{c}]_\times` (MoorDyn-F's
:math:`\mathbf{M}_{(4:6,4:6)}\mathbf{a}_{(4:6)} = \mathbf{F}_{(4:6)} - \mathbf{M}_{(4:6,1:3)}\mathbf{a}_{(1:3)}`).
The node receives
:math:`\mathbf{F} - (m + m_a)\mathbf{a}_p - m(\boldsymbol{\alpha}\times\mathbf{c} + \boldsymbol{\omega}\times(\boldsymbol{\omega}\times\mathbf{c}))`
and no moment, :math:`m_a` the body's translational added mass, with the angular acceleration
solved again for the current node acceleration as for the rod. This is MoorDyn-F's coupled pinned
body with ``inertialF 1`` (its default ``inertialF 0`` leaves the inertia out of the coupled
force; CableDyn always includes it) but for three modelling differences, where CableDyn keeps the
consistent form: MoorDyn-F's centripetal force :math:`-\mathbf{M}_{(1:3,1:3)}\,\boldsymbol{\omega}\times(\boldsymbol{\omega}\times\mathbf{c})`
takes its translational mass block, with the added mass :math:`\rho V C_a` and the attached
points' masses, at the centre of gravity, where CableDyn takes the structural mass there and the
added mass and line ends at their own points; MoorDyn-F applies the full buoyancy
:math:`\rho g V` at any elevation, CableDyn the wetted one (``bodyWetting moordyn`` restores
MoorDyn's); and the attached ``EI = 0`` lines carry their consistent end-node inertia
(:math:`m l/3` of the end element, less with the interior following in a step) against
MoorDyn-F's lumped :math:`m l/2`. The aggregate solves the start accelerations of its bodies and
rods at initialisation and, before the first step, at a committed transfer of the step-start
kinematics and at new host fluid fields (with the line interior accelerations in those fields), so
the first step starts from the accelerations in the host's field and the state mirror the OpenFAST
shell restores after its first output call (its ``t = 0`` field is set at initialisation) already
carries them. The sub-step estimate
takes the diagonal of :math:`\mathbf{I}_p` against the line springs through their arms from the
node, the waterplane restoring, and the swing stiffness of the weight and buoyancy turning with
the body, :math:`|\mathbf{K}_{kk}|` of :math:`\mathbf{K} = -\sum_i[\mathbf{f}_i]_\times[\mathbf{p}_i]_\times`
at the step-start and end-of-step node poses, plus :math:`|\mathbf{a}_p|\,m|\mathbf{c}|`; the
node moves linearly within the sub-steps from the committed reference-point motion, and that
motion, which the body state mirror carries, starts the next step.

**Mixed topologies.** One step marches every object of a deck together: bodies with their fixed
and pinned rods, free and pinned rods, the ``EI = 0`` lines with their ``Free``/``Connect``
points, and the finite-EI cables. In the monolithic scheme the points are junctions of the
Newton iteration above. In the staggered scheme they are integrated on their summed end loads
within the line step. A cable's End A is driven with its attachment's predicted motion and its
End B held; its end force enters the object's equation as a point load at the attachment
(pinned: force only). The cable end-node inertia is not implicit, unlike the ``EI = 0`` line
ends.

**Cables clamped to bodies and rods.** A ``Rigid`` or spring end connection at a cable's End A
on a body point or a rod end fixes the connection direction in the object,
:math:`\mathbf{d} = \mathbf{R}_j\mathbf{d}_0`, so the end tangent follows the object's
rotation; only the direction of :math:`\mathbf{m}` is prescribed and its magnitude (the axial
stretch) stays free. The cable returns to the object its end force at the attachment and the
connection moment :math:`\mathbf{M}_e = \mathbf{m}\times\mathbf{g}_m`, with
:math:`\mathbf{g}_m` the constraint (or spring) force on the tangent coordinates. In the
monolithic step the cable is re-stepped from the step entry at every outer iteration with the
iterate's end-of-step motion, orientation, angular velocity and angular acceleration (a pinned
end, which the monolithic step couples the same way, takes the motion only), and its
end force and moment load the object at the force level
:math:`(1-\alpha_f)\,\mathbf{f}_{n+1} + \alpha_f\,\mathbf{f}_n`. Its condensed dynamic end
stiffness with respect to the object's translation and rotation enters the Newton matrix by
differences of the cable step. On a rod end the direction must lie along the rod axis, so the
bending moment has no component about the axis, which carries no degree of freedom on a free
or pinned rod (an axisymmetric rod has no roll angle; a line restrained in torsion is refused
there). A ``Fixed`` rod holds its end frame, and the torque of a line restrained in torsion
returns to it about the line axis; the ends of a rod fixed to a body are points of the body,
whose frame rolls with it. The static solve
carries the cable first without bending; passes then add the difference between the cubic-Hermite
cable's end force and that surrogate, and the Hermite connection moment, at the previous
pass's pose, until these loads change by less than :math:`10^{-7}` of the force scale. At the
fixed point the object balances the Hermite cable exactly. A bending-pinned end carries no
moment, but the surrogate gives its end force without the share of the bending, which on a soft
object is not small (a free spar rod with a pinned 55 m cable of :math:`EI = 2\times10^4` N m\ :sup:`2`
started 5.7 cm off its equilibrium), and with the line's ``ATTACHMENTS`` only smeared: on a
Rigid6 body or a rod end such a line takes the passes too, Anderson-mixed. The surrogate carries
the attachments' net weight smeared over the elements beside their nodes, as the smeared start of
the Hermite statics, so the passes correct only the lumped, side-of-the-surface, drag and bending
differences; a surrogate without them left the passes a heavy clump's whole load, whose change
with the object's pose its end stiffness did not see, and the passes converged or stopped by
round-off. Should the passes fail on that surrogate, they are repeated once on the surrogate
without the attachments. The mixing drops history columns that add less than :math:`10^{-6}` of
a new direction, which keeps its least-squares fit well conditioned when the residuals span fewer
directions than the history.

**End connections (Hermite lines).** A line end may carry an isotropic rotational spring with
potential :math:`U = \tfrac{1}{2}k\,\theta^2`, where :math:`\theta` is the angle between the end
tangent :math:`\mathbf{m}` and the reference direction :math:`\mathbf{d}_0`. The spring restrains
only the direction of :math:`\mathbf{m}`; its magnitude, which carries the axial stretch, is
free. :math:`k = 0` is a pinned end. A ``Rigid`` end is an exact two-coordinate constraint
that keeps :math:`\mathbf{m}` on the ray of :math:`\mathbf{d}_0`, not a large stiffness. At a coupled
end, :math:`\mathbf{d}_0` rotates with the supporting body and the connection moment is returned
to it. The connection moment equals the bending moment of the line at its end node.

**Prescribed vessel motion.** In the standalone driver a rigid vessel can carry the coupled
points. With reference point :math:`\mathbf{r}(t)` (``vesselRef`` at the reference pose) and
rotation :math:`\mathbf{R}(t)` from vessel to global axes, a point at the vessel-frame offset
:math:`\mathbf{p}` has

.. math::

   \mathbf{x} = \mathbf{r} + \mathbf{R}\mathbf{p}, \qquad
   \dot{\mathbf{x}} = \dot{\mathbf{r}} + \boldsymbol{\omega}\times\mathbf{R}\mathbf{p}, \qquad
   \ddot{\mathbf{x}} = \ddot{\mathbf{r}} + \boldsymbol{\alpha}\times\mathbf{R}\mathbf{p}
     + \boldsymbol{\omega}\times(\boldsymbol{\omega}\times\mathbf{R}\mathbf{p}),

with :math:`\boldsymbol{\omega}` and :math:`\boldsymbol{\alpha}` the angular velocity and
acceleration in global axes. These are the prescribed position, velocity and acceleration of the
line ends at the point. An end connection at such a point uses
:math:`\mathbf{d}_0(t) = \mathbf{R}(t)\,\mathbf{d}_0` and, for a ``Rigid`` end, the exact rates
:math:`\dot{\mathbf{d}}_0 = \boldsymbol{\omega}\times\mathbf{d}_0` and
:math:`\ddot{\mathbf{d}}_0 = \boldsymbol{\alpha}\times\mathbf{d}_0 + \boldsymbol{\omega}\times\dot{\mathbf{d}}_0`
in the prescribed tangent direction; the tangent magnitude stays a free axial degree of freedom.
Euler angles follow the OrcaFlex vessel convention
:math:`\mathbf{R} = \mathbf{R}_z(\psi)\mathbf{R}_y(\theta)\mathbf{R}_x(\phi)` (roll
:math:`\phi`, pitch :math:`\theta`, yaw :math:`\psi`), for which

.. math::

   \boldsymbol{\omega} = \dot\psi\,\mathbf{e}_z + \dot\theta\,\mathbf{e}_{y'} + \dot\phi\,\mathbf{e}_{x''},
   \qquad \mathbf{e}_{y'} = \mathbf{R}_z\mathbf{e}_y, \quad
   \mathbf{e}_{x''} = \mathbf{R}_z\mathbf{R}_y\mathbf{e}_x,

and :math:`\boldsymbol{\alpha}` is its exact time derivative.

With a displacement RAO table the vessel motion is the linear response to the deck sea. A wave
component of amplitude :math:`a_i` and frequency :math:`\omega_i` has the elevation
:math:`a_i\cos(\omega_i t - \varepsilon_i)` at the reference point, where
:math:`\varepsilon_i = k_i(x_r\cos\beta + y_r\sin\beta) + \varphi_i` carries the component's
phase :math:`\varphi_i` and the reference-point position. Degree of freedom :math:`j` then moves as

.. math::

   \xi_j(t) = r(t)\sum_i a_i A_j(\omega_i, \beta)\cos\big(\omega_i t - \varepsilon_i - P_j(\omega_i, \beta)\big),

with RAO amplitude :math:`A_j` and phase lag :math:`P_j` relative to the wave crest at the
reference point, the relative heading :math:`\beta` equal to the component's own direction of
travel (so each component of a spread or multi-train sea takes the RAO at its heading), and the
``rampTime`` factor :math:`r(t)`. The complex RAO :math:`A_j e^{-iP_j}` is interpolated linearly
in period and heading inside the table; headings are taken modulo 360°, but a heading beyond the
last tabulated one (between 345° and 360° in a 0–345° table, for example) is rejected rather than
interpolated across the wrap to the first. The velocities and accelerations are the exact time
derivatives of
:math:`\xi_j`, and for an irregular sea the motion spectrum is
:math:`S_{\xi_j}(\omega) = A_j^2(\omega)\,S_\eta(\omega)` component by component.

**Discrete attachments (Hermite lines).** A buoyancy module or clump of mass :math:`m`,
displaced volume :math:`V`, normal and axial drag areas :math:`C_dA` and :math:`C_dA_x`, and
added-mass coefficient :math:`C_a` is
lumped at a node :math:`j` of the cable. It adds the constant mass :math:`m + C_a\rho V` to the
three translational DOFs of the node and the nodal load

.. math::

   \mathbf{f}_j = -(m - \rho V)\,g\,\mathbf{e}_z
     + \rho V (1 + C_a)\,\dot{\mathbf{u}}
     + \tfrac{1}{2}\rho\,\big(C_dA\,\lvert\mathbf{w}_n\rvert\mathbf{w}_n
       + C_dA_x\,\lvert\mathbf{w}_t\rvert\mathbf{w}_t\big),

with the fluid velocity :math:`\mathbf{u}` and acceleration :math:`\dot{\mathbf{u}}` at the node and
the relative velocity :math:`\mathbf{w} = \mathbf{u} - \dot{\mathbf{r}}_j` split normal and along
the nodal tangent :math:`\mathbf{m}_j/\lvert\mathbf{m}_j\rvert` (the line's Morison law with
:math:`C_dA = C_{d,n} d` and :math:`C_dA_x = \pi C_{d,t} d`). The drag enters the velocity tangent
and, through :math:`\mathbf{m}_j`, the position tangent exactly. Above the free surface an
attachment carries its weight :math:`-m g\,\mathbf{e}_z` alone. The statics start from the
equilibrium with the net weight smeared over the node's two elements, in a deck current across
the vertical plane of the chord with the drag areas smeared over them too (per-metre drag
coefficients :math:`C_dA/(d\,L)` and :math:`C_dA_x/(\pi d\,L)` added to an element of length
:math:`L` for each share), and continue to the lumped loads in warm-started Newton solves, the
smeared weight and drag moving to the node together; in a deck current the drag at rest is
lumped at the node, each solve takes
every attachment's load on the side of the still-water level its node is on, and the final
solve is repeated with the loads of its own solution until the nodes stop moving and no
attachment changes side (an attachment that its weight in air takes below the surface and its
weight in water above it has no static position, and the solve fails closed, naming the
attachment that crossed the surface). Before, an attachment above the surface
kept its buoyancy in the statics: a 500 kg, 0.2 m\ :sup:`3` module 3 m above it moved the
fairlead load by up to 6.1 % in the first second of the march. The load moves
in eighths; a solve that stalls on a residual floor above the tight static tolerance is
repeated from the same state at the coupled static tolerance :math:`10^{-6}`, as the line's own
static solve accepts such a floor, and the run notes the residual of the discrete equilibrium
when it lies above the tight tolerance. A step whose damped Newton solve does not converge is
repeated from the last converged state with pseudo-transient continuation and then with a
residual-merit line search,
and is halved (down to 1/1024) when neither converges. A halved step doubles again (up to 1/8)
after two consecutive converged steps of its size; each time a doubled step fails, the number
of converged steps a doubling waits for doubles, so a homotopy that converges steadily at one
size and fails at twice it keeps advancing and tries the larger size about ten times at most.
At most 64 load steps may fail in all. A discrete state reached this way passes the kink,
tensile, physical-branch and stability checks of the smeared state before it is accepted, the
kink limit :math:`L_0\kappa \le 0.7` applied away from the attachment nodes: a lumped load
turns the line by a slope jump :math:`\theta` at its node, which the :math:`C^1` elements
beside the node carry as :math:`L_0\kappa \approx 2\theta` at any mesh size. On a frictional
seabed, whose regularised friction force turns from its sticking stiffness to its sliding
capacity over a short slip, a smeared state without the attachment drag left the polish to apply
the whole module drag, and its damped Newton updates diverged from the first step as the
grounded run slid metres sideways (a lazy wave with 25 modules in a 0.3 m/s cross current on 2 m
elements); with the drag smeared, each load step moves the line by millimetres and converges in
a few iterations. A current along the plane does not move the line out of it, and the polish
carries the attachment drag from the smeared state without it, as the smeared start of a coarse
deck mesh could otherwise stop at the grounded-run compression check (a lazy wave restrained in
torsion in 0.5 m/s along its plane).
As the pitch :math:`p` of identical modules shrinks, the discrete equilibrium
converges to the smeared section at :math:`O(p^2)`.

**Line failure.** A ``FAILURE`` row detaches a line end from its point at a prescribed time or
when the end tension reaches a threshold, whichever occurs first. The end is transferred onto a
pre-allocated reserve free point that then moves with the attached line ends. On a Rigid6 deck
the bodies keep their staggered step with the remaining lines, and the reserve point is
integrated on its line-end loads within the same line step.

**Active line control.** A ``CONTROL`` row assigns a control channel to a line. The command
acts on the segment at the line's fairlead-side end, the end on a host-driven point (coupled,
vessel, turbine or body point, or an end of a coupled or vessel rod); when both or neither ends
are host-driven, it acts on the segment at the ``NodeB`` written in the deck (MoorDyn-F's
segment :math:`N` at ``AttachB``). On an ``EI = 0`` line the commanded :math:`\Delta L` and
:math:`\Delta\dot L` change the unstretched length and its rate of that end element,
:math:`L_0 = L_{0,\text{base}} + \Delta L`; the structural mass and the point mass shares are
updated consistently, while ``BA`` keeps its initial resolution. Commands outside MoorDyn-F's
bounds, :math:`-\bar L/2 \le \Delta L \le \bar L` with :math:`\bar L` the line's unstretched
length over its number of segments (``UnstrLen``/N, the base length of the controlled segment
on a line of one section), are rejected with the same comparisons MoorDyn-F makes, on both line
kinds; so is a command that would make the controlled segment non-positive, which only a line
of several sections allows.

On an ``EI = 0`` line the length is applied before a step and held over it, and the
committed state keeps the lengths and rates it was reached with, :math:`L_{0,c}` and
:math:`\dot L_{0,c}`, together with its acceleration. Each share of the generalised-:math:`\alpha`
residual takes the lengths of its own time level, and the step commits the new lengths with the
new state. With the force blend (the default) the step-start force
:math:`\mathbf{r}(\mathbf{q}_n, \mathbf{v}_n)` is the committed state's: its internal force, axial
damping, viscoelastic and Syrope laws, seabed contact, damping and friction, Morison drag,
Froude–Krylov and buoyancy loads are evaluated with :math:`L_{0,c}` and :math:`\dot L_{0,c}`, with
the distributed external load and the nodal seabed coefficients those lengths give, and so is
every step-start quantity of the release cap: the stretch :math:`e_n = l_n - L_{0,c}`, the
tension :math:`T_n` (the elastic one, or that of the viscoelastic or Syrope law at the committed
state), :math:`W_n`, the secant :math:`T_n/e_n`, the law stiffness :math:`k_n` (:math:`EA_D/L_{0,c}`,
:math:`K_1/L_{0,c}`) and the dashpot tension :math:`T_{d,n}` (with :math:`\dot L_{0,c}`).
:math:`\mathbf{r}(\mathbf{q}_{n+1}, \mathbf{v}_{n+1})` and the cap's end-state quantities take the new
lengths and rates: the stretch :math:`e_{n+1} = l_{n+1} - L_0`, the estimate
:math:`\hat T_{n+1} = \min(T_n/e_n, k_n)\,e_{n+1}` and :math:`T_{d,n+1}`; the projections :math:`p` and
:math:`p_{n+1}` are geometric. The dashpot weight :math:`\phi` measures the end stretch against the new
length, so its band runs from :math:`L_0` to :math:`L_0 + c\,e_n`, the width set by the step-start
stretch as without a change. For an elastic element the secant estimate then differs from its end
tension :math:`EA\,e_{n+1}/L_0` by the factor :math:`L_0/L_{0,c}`, that is by the relative length change
of the step. A haul-in can make :math:`p_{n+1}` more negative than without a change; the
capped force is then bounded below by zero, and the cap's quick inactivity test uses the bound
:math:`N \ge W_n - (1-\alpha_f)\,T_n (l_n - L_0)^2/(4 e_n)`. The external load of the step,
constant over it, is :math:`(1-\alpha_f)\,\mathbf{f}_\text{ext}(L_0) + \alpha_f\,\mathbf{f}_\text{ext}(L_{0,c})`.
The inertia, which the force blend keeps at the :math:`\alpha` level (the structural mass applied
to :math:`\mathbf{a}_{n+1-\alpha_m}` and the added mass at :math:`\mathbf{q}_\alpha`), takes the
blended lengths :math:`(1-\alpha_f) L_0 + \alpha_f L_{0,c}` of the changed elements, as
:math:`\mathbf{q}_\alpha` blends the configuration. With the configuration blend
(``False alpha_force_blend``) the residual evaluates the internal force, the damping and the
hydrodynamic loads at the blended configuration :math:`\mathbf{q}_{n+1-\alpha_f}`; for an element
whose length changed it also blends the lengths, :math:`(1-\alpha_f) L_0 + \alpha_f L_{0,c}` (and
the rates likewise, the structural and added mass included), so that the configuration and the
lengths are blended consistently and the new length belongs to :math:`t_{n+1}`; the external load
and the seabed coefficients are then the new lengths'. Evaluating the committed side with the
new lengths (the step-start force, or a configuration blended without its lengths), or
re-deriving the committed acceleration under the new length, would add the force of the length
change to the committed side of the blend, weighted by :math:`\alpha_m` and :math:`\alpha_f`; on a
pay-out or haul-in ramp the tension would then lag the quasi-static value by a fixed fraction of
its change per step, at any :math:`\rho_\infty` (on a taut line paid out at a tension change of
1 N per step, 2.6 N with the step-start force at the new lengths, against 1.8 mN, the start-up
transient that :math:`\rho_\infty = 0` shows as well). An acceleration re-derived between the
command and the step (a host state update or a boundary commit) belongs to the committed state,
so it is solved with :math:`L_{0,c}` and :math:`\dot L_{0,c}`, which stay the committed lengths and
rates, and evaluated as the step evaluates its committed side: with the force blend at the
external load and seabed coefficients of :math:`L_{0,c}` as well, with the configuration blend at
the present ones.

A step that the rotation- and snap-resolved sub-steps (``ei0_substeps auto``, above) solve
again spreads a pending length change over its sub-steps. The committed lengths and rates are
part of the state each pass starts from; sub-step :math:`k` of :math:`n` ends at the lengths and
rates interpolated linearly in time between :math:`L_{0,c}` and :math:`L_0` at :math:`k/n`, with
the external load and seabed coefficients rebuilt at them, and the last on the new ones bit for
bit. Each sub-step treats its start and end lengths as the step above treats :math:`L_{0,c}` and
:math:`L_0`, so the first starts at :math:`L_{0,c}`, and the trigger takes the step-start
tensions at :math:`L_{0,c}`. A constant command rate makes the interpolated lengths those the
rate integrates to: on a line turning by 2.3° per step whose end segment is paid out at
0.05 m/s, every step solved in four sub-steps, the march equals one taken as given at a quarter
of the step to 3e-8 N, where applying the whole change in the first sub-step departs from it by
22 N (2.2 times the tension change per step). A step recovered after a stall and the halves of a
line-system step halved after a failure, which take their sub-steps as given, apply the whole
change in their first part.

A Syrope segment keeps its states over a length change as MoorDyn-F and MoorDyn-C keep them.
Their state is the segment's slow stretch :math:`\Delta l_1 = \varepsilon_\text{slow} L_0`, which a
change of :math:`L_0` leaves as it is, and the mean tension reads the slow strain
:math:`\Delta l_1/L_0` at the new length. CableDyn stores the slow strain of the committed state,
a strain of :math:`L_{0,c}`, and reads it at the present length,

.. math::

   \varepsilon_\text{slow}(L_0) = \varepsilon_\text{slow}\,\frac{L_{0,c}}{L_0},

so the step's backward-Euler update
:math:`\varepsilon_\text{slow}^{n+1} = \varepsilon_\text{slow}^{n} L_{0,c}/L_0 + \Delta t\,\dot\varepsilon_\text{slow}`
is that of MoorDyn's :math:`\mathrm{d}\Delta l_1/\mathrm{d}t = L_0\,\dot\varepsilon_\text{slow}`; the
committed force of the force blend reads the state at :math:`L_{0,c}` as it is. The running
maximum, a tension, is kept, and the slow-strain rate takes the chord rate
:math:`\dot\varepsilon = \mathbf{t}\cdot\Delta\mathbf{v}/L_0` without the paid-out term, as
MoorDyn's Syrope rate does. A slow pay-out therefore unloads the segment along the working curve
of its load history, and a haul-in beyond :math:`T_\text{max}` follows the OWC and raises it. On a
taut 100 m polyester line whose fairlead segment is paid out by 0.5 m, hauled in to −1 m and paid
back over 80 s, every element's tension follows the rest curve of its history at the line strain
to 2.5e-4 of the initial tension along the ramps and to 6e-7 at rest; after a length step it is
MoorDyn's at the carried stretch to round-off, where carrying the strain instead would be off by
0.4 to 2.4 %.

A viscoelastic segment keeps its slow-branch stretch :math:`\Delta l_1` over a length change, as
MoorDyn-F (``MD_CalcContStateDeriv`` sets the controlled segment's ``l`` and ``ld``,
``Line_GetStateDeriv`` reads ``dl_1`` against ``l``) and MoorDyn-C
(``Line::setUnstretchedLength``, ``Line::getStateDeriv``) keep it: :math:`\Delta l_1` is a
stretch, so no rescaling arises, and the law reads it at the present length,
:math:`T = EA_1\,\Delta l_1/L_0 + BA\,\dot{\Delta l}_1/L_0` with
:math:`\dot{\Delta l}_1 = (EA_D (l - L_0) - (EA_D + EA_1)\Delta l_1 + BA_D\,\dot l)/(BA_D + BA)`
and, for the load-dependent stiffness, :math:`EA_D(\Delta l_1, L_0)`; the committed force of the
force blend reads the same :math:`\Delta l_1` at :math:`L_{0,c}`. The rate :math:`\dot l` is the
chord rate, without the paid-out term, as in MoorDyn. On the taut 100 m line above with
:math:`E_s = 10^8` N, the same pay-out and haul-in cycle follows the static law
:math:`E_s(D/L - 1)` to 1.7e-4 of the initial tension along the ramps (4.6e-4 with the
load-dependent stiffness) and to 4e-9 at rest; after a length step the tension is MoorDyn's at
the carried stretch to round-off, where carrying the strain instead would be off by 0.4 to 4.6 %.

On a finite-EI cable, whose fairlead is End A, the command acts on the cable elements that make
up the End-A segment of the deck mesh, of initial length :math:`S`. Each element scales by
:math:`\lambda = (S + \Delta L)/S`, :math:`L_{0,e} = \lambda L_{0,e,\text{base}}`, with rate
:math:`\dot L_{0,e} = \Delta\dot L\, L_{0,e,\text{base}}/S`. The length is applied before a
step and held over it. The
consistent mass, the attachment masses, the tributary lengths and the nodal seabed coefficients
are rebuilt from the new lengths in the order initialisation used, so the model is the one a
build with those lengths would give; the mass of the new lengths acts over the step and its rate
term :math:`\dot{\mathbf{M}}\mathbf{v}` is not modelled (as in MoorDyn), and the committed
acceleration is kept as the history of the preceding step. The committed state keeps the lengths
and rates it was reached with: in the force-blended residual the committed force
:math:`\mathbf{F}_n = \mathbf{R}(\mathbf{q}_n, \mathbf{v}_n, t_n)` is the force at those
lengths, and only :math:`\mathbf{R}(\mathbf{q}_{n+1}, \mathbf{v}_{n+1}, t_{n+1})` takes the new
ones; an acceleration re-derived between the command and the step (a boundary commit) is solved
at those lengths too, since it belongs to the committed state. The configuration-blended form
(``False alpha_force_blend``) has no such treatment and is refused for a controlled cable. Evaluating :math:`\mathbf{F}_n` at the new lengths would add the force of the length change
to the committed state, which the blend weighs by :math:`\alpha_f`; on a pay-out ramp the
tension would then lag the quasi-static value by a fixed fraction of its change per step. A step
that follows a change starts its Newton iteration from the Newmark predictor, not from the
constant-acceleration one, since the change is a step in the load. The axial damping acts on
the rate of the strain :math:`\varepsilon = |\mathbf{r}_{,\xi}|/L_0 - 1` along the motion and
the length change. The tangent terms of :math:`\mathbf{r}_{,\xi}` carry the
factor :math:`L_0` and cancel, so with :math:`\mathbf{p} = H'_1 \mathbf{r}_1 + H'_3 \mathbf{r}_2`
the end-position part,

.. math::

   \dot\varepsilon = \frac{\mathbf{t}\cdot\left(\mathbf{v}_{,\xi}
   - (\dot L_0/L_0)\,\mathbf{p}\right)}{L_0},

and a segment paid out at constant strain carries no damping force. The position Jacobian of the
damping force gains :math:`-BA\, H'_a H'_b\, (\dot L_0/L_0^2)\, \mathbf{t}\mathbf{t}^\mathsf{T}` on
the end-position columns. On a cable restrained in torsion the torsion follows the lengths in the
same way (:ref:`theory-torsion`, Active line control).

Tension and coupled loads
-------------------------

An interior node tension is the segment tension, the average of the two adjacent element
tensions, on an ``EI = 0`` line, and the effective tension recovered from nodal equilibrium
(:ref:`theory-output-recovery`) on a Hermite line, including axial damping and
constitutive-state contributions.
``FairTen``, ``AnchTen`` and the end-node tension channels report the line-end force instead
(:doc:`conventions`, :doc:`outputs`). By the convention in :doc:`conventions` the reported
tension is the effective tension. The
load returned to a coupled object is the reaction of the cable at the coupled node,
:math:`-(\mathbf{M}\mathbf{a} + \mathbf{f}_\text{int} - \mathbf{f}_\text{ext})` at the prescribed
DOFs, so it includes the line's inertia and hydrodynamic reaction there. Its derivatives with
respect to coupled position, velocity, and acceleration are analytic, with the free DOFs
statically condensed; the acceleration derivative is
:math:`-(\mathbf{M}_{cc} - \mathbf{M}_{cf}\mathbf{M}_{ff}^{-1}\mathbf{M}_{fc})` including added mass
(:doc:`coupling_boundary`).

Linear algebra
--------------

All global operators are stored and factorised in LAPACK band form (``DGBTRF``/``DGBSV``), with
Dirichlet conditions applied in-band and workspaces allocated once, so a dynamic step performs
no heap allocation. The Hermite static energy minimisation also uses the banded Cholesky
factorisation ``DPBTRF``/``DPBTRS``, whose success is the positive-definiteness test of its
shifted tangent. The Hermite operator has half-bandwidth :math:`k_l = k_u = 11` (6 DOFs per
node, 12 per element). The ``EI = 0`` bandwidth is computed from the element connectivity after
removing prescribed DOFs; for a line numbered node by node it is 5. A dense-assembly reference
path packs the assembled matrix into band storage and solves it with ``DGBSV``.
