.. SPDX-License-Identifier: Apache-2.0

Key concepts
============

This page is the mental model behind every CableDyn deck, driver run, and coupled
simulation. Read it once and the rest of the guide — the :doc:`deck format <driver_format>`,
the :doc:`tutorials`, the :doc:`output channels <outputs>` — falls into place. Nothing here is
specific to a solver path or a caller; it is how CableDyn *thinks* about a mooring or cable
system.

For an at-a-glance statement of which caller supports which feature, use :doc:`capabilities`.
For the engineering sequence from source data to a converged and validated model, use
:doc:`modeling`.

The model is a graph of line objects and boundary attachments
--------------------------------------------------------------

A CableDyn model is a small graph, but its native objects are finite-element lines and their
boundary attachments:

- **Lines** are the native FEM objects — each line spans **End A → End B** and owns its
  section-wise mesh.
- **Boundary attachments** are anchors, fairleads, connectors, clumps, floats, vessels, or
  bodies. They prescribe motion or contribute force balance at a line end.
- ``POINTS``, ``BODIES``, and ``RODS`` are MoorDyn-compatible deck records. The driver translates
  them into boundary or rigid-body objects; they are not part of the line discretisation.

.. code-block:: text

   (End A)                                   (End B)
  Coupled point  ──────── Line 1 ────────►  Fixed point
  fairlead / top                            anchor / lower

That is the whole native topology. A three-line spread mooring is three lines sharing a platform;
a shared farm mooring is a line between two turbines' fairleads; a lazy-wave power cable is
one line whose middle section is buoyant.

.. admonition:: End A is the top, End B is the bottom
   :class: important

   CableDyn follows the OrcaFlex convention: **End A is the fairlead / upper end** and
   **End B is the anchor / lower end**. A ``LINES`` row reads ``ID NodeA NodeB`` with NodeA = End A.
   A held line whose End A sits below End B is rejected when the deck is read.

A line is one object built from sections
----------------------------------------

This is the main structural difference from a MoorDyn deck, and the thing to get right when
porting one.

A **line is one object** spanning its two end points, and its geometry is an **ordered list of
sections** (the line-and-section arrangement OrcaFlex also uses). Each section carries its own
line type and its own mesh density:

.. code-block:: text

   --- SECTIONS ---
   LineID  LineType   Length  NumSegs
   1       bare        40.0   13      <- End A (fairlead) side
   1       buoy        50.0   16
   1       bare        55.0   18      <- End B (anchor) side

A bare cable + a buoyancy stretch + more bare cable is **three sections of one line**, not
three lines; a bend stiffener over its end is a ``STIFFENERS`` row on that line. A single-material chain is **one section**. The unstretched length is the sum of
the section lengths; the mesh is refined per section.

.. admonition:: Porting from MoorDyn
   :class: note

   A stock MoorDyn deck runs almost unchanged: its 7-column ``LINES`` row is read as a line of
   one section, and anchor-first rows are swapped so that End A is the fairlead. In MoorDyn a
   line carries a single type, and a composite is several lines joined at a point; in CableDyn
   that composite is best written as **one line with several sections**. See :doc:`migrating`.

Line types are material + hydrodynamics
---------------------------------------

A ``LINE TYPES`` row is the reusable material a section refers to by name: diameter, mass per
metre, axial stiffness ``EA``, axial damping ``BA``, bending stiffness ``EI``, and the four Morison
coefficients (``Cd_n``, ``Cd_t``, ``Ca_n``, ``Ca_t``). ``EI`` is the switch between the two solver paths
(next section). Axial response can be linear ``EA`` or a stateful constitutive model
(viscoelastic, Syrope) — see :doc:`theory`. An ``EI = 0`` row may end with MoorDyn's cross-flow
VIV columns ``Cl`` or ``Cl dF cF`` (lift coefficient and synchronisation band; see
:ref:`theory-viv`).

Two solver paths, selected by ``EI``
------------------------------------

CableDyn carries two position-based finite-element line formulations, with **no rotation degrees
of freedom** in the line elements (rigid bodies and rods do rotate). Which one a section uses
is decided by its line type's bending stiffness:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Path
     - Description
   * - ``EI = 0`` — chains & moorings
     - The line is a catenary; bending is negligible. A positions-only two-node element, a banded
       Newton/Armijo static solve seeded from an analytical catenary, and generalised-α dynamics with
       Morison and seabed loads. This is the production mooring path.
   * - ``EI > 0`` — lazy-wave power cables
     - Bending shapes the sag bend, the hang-off curvature, and the buoyant arch. A cubic-Hermite
       element carries position **and** the material tangent, so the centreline is :math:`C^1`
       with exact pointwise curvature. A Newton static solve seeded from the exact ``EI = 0``
       catenary, with continuation in ``EI``, reaches the buoyant lazy-wave equilibrium;
       generalised-α dynamics carry the full Morison set.

The two paths share the same deck, the same loads, the same integrator, and the same coupling
boundary. A mixed deck — chain moorings *and* a finite-EI cable — is normal. See
:doc:`solver_paths` for the formulations and :doc:`theory` for the shared math.

Every run is static, then (optionally) dynamic
----------------------------------------------

CableDyn always begins from a **statically-solved initial condition** — a Newton
equilibrium, not a dynamic relaxation:

1. **Parse** the deck into an in-memory model, failing closed on any unimplemented feature.
2. **Mesh** each line and seed it from the analytical catenary (for a finite-EI cable, the
   exact ``EI = 0`` multi-segment catenary, buoyant sections included).
3. **Static IC** — a per-line Newton solve on a banded system, with continuation (in the load,
   or in ``EI`` for a finite-EI cable) as the route or the fallback. It converges to the
   equilibrium from a simple seed, without a settling phase.
4. **Dynamic march** — *only if* the deck sets ``dtM`` and ``TMax``. Implicit generalised-α steps
   from the static IC, driven by held or prescribed endpoint motion, with the full load set.

A static-only run writes one row at :math:`t = 0` (plus the along-arc static-configuration file). A
dynamic run writes one row per output time.

.. admonition:: Newton statics, not dynamic relaxation
   :class: tip

   The initial condition is always a Newton static equilibrium — no
   artificial damping, no settling time, and no option to choose — so a stiff lazy-wave cable or a
   taut mooring can start from a simple seed. CableDyn does not use dynamic relaxation, the
   approach MoorDyn uses to initialise.

One core, many callers
----------------------

The solver core knows nothing about who is calling it. Kinematics come **in** across a single
coupling boundary and structural loads go **out** — the line's hydrodynamic response is
computed identically no matter the caller. Three callers sit on that one boundary:

.. list-table::
   :header-rows: 1
   :widths: 24 76

   * - Caller
     - How it drives CableDyn
   * - **Standalone driver** (``CableDyn_driver.exe``; ``cabledyn`` from a source build)
     - reads a ``.dat`` deck, solves, writes ``.out`` tables. The :doc:`tutorials` use this.
   * - **OpenFAST** (``CompMooring = 5``)
     - a mooring module of OpenFAST v5 (maintained by NLR, the National Laboratory of the
       Rockies, formerly NREL); the platform drives the fairleads each glue step. See
       :doc:`coupling`.
   * - **C binding** (``CableDyn_CAPI``)
     - a MoorDyn-C-style C ABI for CFD coupling (STAR-CCM+, OpenFOAM) and the
       :doc:`Python package <python>`.

Because they share one boundary, moving a validated deck from the standalone driver into
OpenFAST does not change the physics — only who prescribes the fairlead motion.

Fail closed, never silent
-------------------------

Every section, column, and keyword the :doc:`deck format <driver_format>` names has a defined
behaviour. A feature that is not supported on the chosen route is **rejected at parse or init
with a clear fatal error naming the feature** — never silently solved as something else, never a
quiet wrong answer. When you hit one, :doc:`troubleshooting`
maps the message to the reason and the supported alternative.

Units, frames, and signs are frozen
-----------------------------------

SI units throughout the deck, with angles in degrees. The global frame, sign rules, angle
definitions, and the effective-tension convention follow OrcaFlex and are fixed in
:doc:`conventions`.

Where to go next
----------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Page
     - What it covers
   * - :doc:`tutorials`
     - A guided path from a single chain to a coupled turbine.
   * - :doc:`driver_format`
     - The complete input reference.
   * - :doc:`outputs`
     - Every channel and file.
   * - :doc:`capabilities`
     - Supported combinations and route ownership.
   * - :doc:`modeling`
     - Property, mesh, forcing, convergence, and validation workflow.
