.. SPDX-License-Identifier: Apache-2.0

Solver paths
============

CableDyn has two production finite-element paths, both formulated in positions (and, for
bending, material tangents) without rotation degrees of freedom. The governing equations are
in :doc:`theory`; this page describes how each path is organised, how its static and dynamic
solutions proceed, and the secondary Cosserat path. A line section is routed by its line-type
bending stiffness: ``EI = 0`` to the cable path, ``EI > 0`` to the bending path. A deck may
mix both.

Avoiding rotation variables removes three limitations that some rotation-DOF finite-bending
formulations face: the rotation-vector chart :math:`|\boldsymbol\theta| < \pi` that a large turn
through a buoyant arch approaches, the conditioning split between bending and axial blocks when
``EI`` is tiny relative to ``EA``, and the accuracy ceiling of linear interpolation for curvature.

The ``EI = 0`` cable path
-------------------------

For chains, wire, and synthetic moorings, where bending stiffness is negligible.

- **Element** — the two-node tension element (:doc:`theory`), with consistent mass
  (``CableDyn_CableElem``, ``CableDyn_Assemble``).
- **Loads** — submerged weight, wetted-fraction Morison drag, added mass and fluid inertia,
  buoyancy recovery at the free surface, axial damping, seabed contact and friction
  (``CableDyn_Loads``, ``CableDyn_Hydro``, ``CableDyn_Damping``).
- **Constitutive models** — linear, viscoelastic, and Syrope
  (``CableDyn_Viscoelastic``, ``CableDyn_Syrope``).
- **Static solve** — analytical catenary seed, then compression-capable and tension-only Newton
  with an Armijo line search, and load continuation as the fallback, on a banded system
  (``CableDyn_Catenary``, ``CableDyn_Static``).
- **Dynamics** — generalised-α with an Armijo line search and adaptive step subdivision
  (``CableDyn_Dynamic``, ``CableDyn_Model``).

The static seed is built from geometry, properties, and loads only; no other solver's
converged state enters the solve. Composite lines — several sections of different type,
length, and mesh density between End A and End B — are one mesh with per-node seabed stiffness.
The global tangent is banded; its bandwidth is computed from the element connectivity after
removing prescribed DOFs (5 for a line numbered node by node).

The cubic-Hermite bending path
------------------------------

For dynamic power cables, where bending stiffness shapes the hang-off curvature, the sag and
hog bends of a lazy-wave arch, and the touchdown region.

Each node carries a position and a material tangent, :math:`[\mathbf{r},\ \mathbf{m}]` with
:math:`\mathbf{m} = \partial\mathbf{r}/\partial s`, so each element has 12 DOFs and the global
tangent has half-bandwidth 11. The element energy, strain measures, quadrature, and curvature
recovery are in :doc:`theory`. The internal force and tangent are formed in closed form
(``CableDyn_HermiteCable``); automatic differentiation of the same energy
(``CableDyn_AD``) is used only in the test suite as an independent check.

.. admonition:: Formulation lineage
   :class: note

   The cubic-Hermite Kirchhoff-rod element is established
   (:ref:`Boyer et al., 2011 <ref-boyer2011>`;
   :ref:`Meier, Popp & Wall, 2015 <ref-meier2015>`). CableDyn applies it to offshore line
   systems with an automatic static solution, implicit dynamics, banded assembly, and the
   coupling interfaces.

Static solve
~~~~~~~~~~~~

The static solve (``CableDyn_HermiteCableStatic``) works on a banded system with penalty
seabed contact. Its tolerance is :math:`\min(10^{-6},\ \text{tol}_\text{dyn})` (:doc:`theory`).

**Default route** (``continuation cable_statics``). The exact ``EI = 0`` multi-segment catenary
through the endpoints is the seed. A continuation in ``EI`` then brings in the bending stiffness
at full load, each stage an energy-descent Newton iteration on a Cholesky-shifted tangent. The
state is polished on the deck mesh (refined if that mesh is too coarse for the bending length)
and audited for self-contact, folding, stability, and axial compression. A line too long for
its span to hang as a catenary is reached by walking the anchor into place. The details are in
:doc:`theory` (Static equilibrium, Hermite path).

**Mesh sequencing** is the fallback of the default route, or runs first with ``sequenced
cable_statics``. It uses ``EI`` and buoyancy continuation, the consistent Hermite self-weight, and a
dimensionless per-DOF convergence norm. The equilibrium of a buoyant arch is selected on a coarse
mesh, where the smooth branch is cheap to follow, then prolonged through the Hermite interpolant and
polished on each finer level and finally on the exact user mesh. The hierarchy accepts odd and prime
element counts, uses the true material coordinates of non-uniform rest lengths, and keeps every
``EA``/``EI``/weight/contact-diameter interface on its primary coarse meshes. Consecutive levels
grow by at most about 3:2; nested levels subdivide their parent elements; the first level apportions
elements across all homogeneous sections globally. For net-buoyant decks with at least 64 elements,
a suspended primary hierarchy keeps its longest actual coarse element within 3.2 local bending
lengths :math:`\lambda = (EI/|w|)^{1/3}` and at least 24 elements. A flat-bed line whose anchor is
already supported continues its grounded tail by a scalar branch homotopy. If the primary path
fails, CableDyn tries one additional coarse level, then an independent binary hierarchy, then an
element-averaged coarse homotopy that conserves length, series compliance, and distributed load
before restoring all interfaces; a single direct cold solve on the exact mesh is the last attempt.
Every attempt uses the same physical inputs, tolerance, and acceptance checks. Nodes inserted on a
contact hierarchy are projected to the declared floor before polishing; this changes only the
prolonged seed, never the contact law or the final equations.

**Weight continuation** (a light slack line). A line longer than its span with too little net
weight for its bending stiffness (:math:`|w| < 100\,EI/L^3`) has no catenary to start from, and
both routes can end on the compressed straight strut or stall at the round-off of its axial
forces. When both fail, the line is solved heavier, with :math:`100\,EI/L^3` of the sign of its
net weight added (downward for a weightless line), and that equilibrium is carried back to its
own weight in the vertical plane of its chord, accepting the round-off floor of the axial
forces. It applies to a planar line in still water over a level seabed, without attachments or
``tensile_safety True``, whose chord is not vertical. A weightless line bows as the Euler
elastica; nothing in the deck chooses the plane or the side of the bow, and a note says how it
was solved (:doc:`theory`).

**Acceptance checks.** A residual-converged state is rejected when the sampled
:math:`\max(L_0\,\kappa)` of any element exceeds 0.7 (an unresolved fold). With
``adaptive_mesh = True``, exhausting the refinement cap while curvature resolution or
mesh-scale contact chatter remains fragile is an error; several separate grounded runs are a
valid physical topology, and only an isolated interior contact or suspended node is treated as
chatter.

A constant structured bathymetry follows the same grounded seed and flat-plane initialisation
as the equivalent ``WtrDpth`` plane and keeps its grid for dynamic contact. Non-flat structured
bathymetry uses its contact-aware route, and its resolution diagnosis uses the same local floor
as the contact residual.

Dynamics
~~~~~~~~

Generalised-α with the constant consistent Hermite mass, prescribed support motion, and a
backtracking Newton iteration from the constant-acceleration or Newmark predictor, reusing the
previous step's factorised tangent on smooth standalone motion (``CableDyn_HermiteCableDynamic``).
The Morison set is integrated over the deformed element with the implicit drag velocity Jacobian,
consistent added mass held over each step, and regular (Airy or stream-function), spectral (single
or multi-train, optionally spread), component-table, or host-sampled wave fields driving both the
drag velocity and the Froude–Krylov plus fluid-inertia load. The step is protected by the
geometric increment check and adaptive subdivision described in :doc:`theory`.

Performance
-----------

Both paths assemble directly into LAPACK band storage, apply Dirichlet conditions in-band, and
allocate their Newton workspace once, so a dynamic step performs no heap allocation. The
remaining cost is dominated by element and hydrodynamic evaluation rather than linear algebra.
OpenMP applies only to source builds configured with it (the release executables are serial).
On such builds, bending-path meshes of at least 32 elements evaluate element tangents in
parallel into per-element buffers and scatter them serially in element order, so results do
not depend on the thread count; the ``EI = 0`` path parallelises its element loop only on
very long meshes (8192 elements or more).

Secondary path: Cosserat rod
----------------------------

A finite-bending Cosserat rod with rotation DOFs (``CableDyn_Cosserat*``) is retained as a
secondary, non-production path. It is not part of the validated product; its integration
regressions carry the ``cosserat`` CTest label (``ctest -L cosserat``). No deck route uses it:
a finite-``EI`` line whose two ends move runs on the cubic-Hermite route like every other
finite-``EI`` line.

The element uses the geometrically exact rod strains of :ref:`Simo (1985) <ref-simo1985>`:
the material strain
:math:`\boldsymbol{\Gamma} = \Lambda^{\mathsf T}\mathbf{r}' - \Lambda_0^{\mathsf T}\mathbf{r}_0'`
and the material curvature vector :math:`\mathbf{K}`, with the orientation
:math:`\Lambda \in SO(3)` parametrised by the rotation vector on :math:`|\boldsymbol\theta| < \pi`.
States at or beyond the chart boundary are rejected. Two-node linear interpolation is used,
with reduced integration of the shear strains.

.. admonition:: Energy-conserving integrator (opt-in, Cosserat path only)
   :class: note

   An energy-conserving integrator of the discrete energy-momentum class
   (:ref:`Simo & Tarnow, 1992 <ref-simo1992>`; ``CableDyn_CosseratEMC``) is available through
   the Fortran library configuration for Cosserat dynamics. It combines an implicit midpoint
   rule for the nodal angular momentum with a discrete-gradient elastic force, and conserves the
   scheme's total mechanical energy to round-off at any step size, where generalised-α shows a
   small, step-size-convergent drift. It is not selectable from a deck, does not apply to the
   production paths, and generalised-α remains the integrator of every production route.
