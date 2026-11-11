.. SPDX-License-Identifier: Apache-2.0

Migrating from MoorDyn or OrcaFlex
==================================

CableDyn reads MoorDyn v2 vocabulary and uses the line-and-section arrangement and output
conventions that users of OrcaFlex (by Orcina) know, so both kinds of model can be ported. This
page maps the concepts, shows what changes, and ends with a checklist.

.. contents::
   :local:
   :depth: 2

From MoorDyn
------------

A stock MoorDyn deck runs almost unchanged
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CableDyn accepts the MoorDyn v2 file layout: the ``--- MoorDyn Input File ---`` banner and
title, ``LINE TYPES`` with the stock ``Cd Ca CdAx CaAx`` column order (recognised from the header
row), ``POINTS`` with ``Fixed``/``Vessel``/``Coupled``/``Free``/``Connect`` attachments, the
stock **7-column** ``LINES`` row, ``SOLVER OPTIONS``, and ``OUTPUTS`` closed by ``END``.

A stock ``LINES`` row

.. code-block:: text

   ID     LineType   AttachA   AttachB   UnstrLen   NumSegs   Outputs
   1        chain       1         4        850.0       50         -

is read as a line from point 1 to point 4 made of **one section** of ``chain``, 850 m long, 50
elements — exactly equivalent to a CableDyn ``LINES`` row ``1 4 1 -`` plus one ``SECTIONS`` row
``1 chain 850.0 50``. MoorDyn writes lines anchor-first; when ``AttachA`` is a ``Fixed`` anchor
and ``AttachB`` a ``Vessel``/``Coupled``/``Body`` fairlead, CableDyn swaps the ends so that
**End A is the fairlead**, as everywhere in CableDyn. Endpoint channels therefore keep their
physical meaning: ``FairTen`` is at the fairlead, ``AnchTen`` at the anchor. A line with no
``Fixed`` end (a shared line between two turbines or through a clump) keeps the order written:
CableDyn's ``FairTen`` is at ``AttachA`` and ``AnchTen`` at ``AttachB``, while MoorDyn writes
``FairTen`` at ``AttachB`` (its last node) and ``AnchTen`` at ``AttachA``. Compare such lines
by end, not by channel name.

``examples/openfast/MoorDyn_UMaine.dat`` is such a stock deck. For a standalone run it needs
only what OpenFAST (maintained by NLR, the National Laboratory of the Rockies, formerly NREL)
would otherwise provide — a water depth — and either no ``dtM`` or both
``dtM`` and ``TMax``, and it must not ask for the host SeaState field:

.. code-block:: text

   200.0    WtrDpth   - water depth (m)          <- add (OpenFAST supplies it when coupled)
   0.0002   dtM       - ...                      <- delete for a static run, or add TMax
   SeaState WaterKin  - ...                      <- delete (coupled runs only)

With those three edits ``CableDyn_driver.exe`` reproduces the same 2.437 MN fairlead tension as the
native deck of :doc:`tutorial_spread`. In OpenFAST the stock deck works unchanged as a
``MooringFile`` for ``CompMooring = 5``; its ``dtM = 0.0002`` is below the glue step, so
CableDyn says so on the console and uses ``dtM = DT`` (0.025 s) instead. Keywords that only
steer MoorDyn's dynamic-relaxation start (``dtIC``, ``TmaxIC``, ``CdScaleIC``, ``threshIC``) are
accepted and have no effect: CableDyn's initial condition is a Newton static equilibrium.

When to use SECTIONS instead
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The 7-column row can describe only a single-type line. A composite (chain–polyester–chain, or a
power cable with bare and buoyancy zones) is, in MoorDyn, several lines joined at ``Connect``
points; in CableDyn it is **one line with several ordered sections**:

.. code-block:: text

   --------------------- LINES --------------------------------------------
   ID    NodeA   NodeB   Outputs
   1     2       1       -
   --------------------- SECTIONS -----------------------------------------
   LineID   LineType    Length   NumSegs
   1        chain       100.0    20
   1        polyester   600.0    60
   1        chain       250.0    25

One line object keeps one continuous arc length, one static profile, and exact continuity at the
joints, with no artificial connection mass. A line is defined either by one 7-column row or by a
3/4-column ``LINES`` row plus its ``SECTIONS`` — not both.

Keyword map
~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 36 64

   * - MoorDyn
     - CableDyn
   * - ``LINE TYPES`` ``Name Diam MassDen EA BA/-zeta EI Cd Ca CdAx CaAx``
     - same row; the native order is ``Cd_n Cd_t Ca_n Ca_t`` and the header decides which is
       meant. ``EI > 0`` switches the line to the bending element.
   * - ``LINE TYPES`` VIV columns ``Cl`` or ``Cl dF cF``
     - same columns and the same synchronisation model, standalone and coupled, on ``EI = 0``
       types and as a distributed lift on finite-EI types (:ref:`theory-viv`); the running-RMS
       window is ``VIVrmsWindow`` seconds, by default
       500 steps of ``dtM`` as MoorDyn's
   * - ``LINES`` ``Outputs`` flags ``p``, ``t``, ``V``
     - the same quantities, one file per flag where MoorDyn writes one file per line:
       ``<root>.Line<L>.p.out``, ``.t.out`` and ``.V.out`` (the VIV lift at the nodes), on the
       standalone routes (:doc:`outputs`); MoorDyn's other line flags (``v``, ``U``, ``D``,
       ``c``, ``s``, ``d``, ...) are not written and are a parse error
   * - ``ElasticMod 2/3`` viscoelastic ``EA``/``BA``
     - ``Es|Ed`` / ``Es|alphaMBL|vbeta`` in ``EA`` and ``BA_s|BA_d`` in ``BA``
   * - Syrope line type and ``SYROPE IC``
     - ``"SYROPE:<settings>|alpha|beta"`` and the same ``SYROPE IC`` section
   * - ``POINTS`` ``Fixed`` / ``Vessel`` / ``Coupled``
     - same; fairleads are ``Coupled`` (``Vessel`` is an alias)
   * - ``POINTS`` ``Free`` / ``Connect`` with ``M V CdA CA``
     - same, on dynamic decks
   * - ``BODIES``, ``RODS``, ``ROD TYPES``
     - supported subset: ``Point3``/``Rigid6`` bodies and rigid rods, lines attached through
       ``Body<N>`` points and at rod ends (``R<N>A``/``R<N>B`` in ``LINES``, or
       ``Rod<N>A``/``Rod<N>B`` points) (:doc:`tutorial_bodies`); ``ROD TYPES``
       ``Cd Ca CdEnd CaEnd`` as in MoorDyn, with optional axial side ``CdAx CaAx`` columns.
       ``CoupledPinned``/``VesselPinned`` rods and bodies run in OpenFAST as in MoorDyn-F (End A
       or the body reference point follows the platform position, the object turns about it, a
       force is returned without moment)
   * - ``dtM``, ``TMax`` (standalone), ``WtrDpth``, ``rhoW``/``WtrDnsty``, ``g``
     - same
   * - ``kBot``, ``cBot``, seabed friction coefficient
     - ``kBot``, ``cBot``, ``frictionMu`` (alias ``mu``)
   * - ``WaterKin`` file (``CurrentMod 1``, ``WaveKinMod 1``)
     - same file; ``WaveKinMod 2`` and ``SEASTATE`` only when coupled to OpenFAST. An
       elevation record keeps its components up to ``WvHiCOff`` (default 0.5 Hz); give
       ``none WvHiCOff`` to keep all of them, as MoorDyn-F does
   * - ``FAILURE``, ``CONTROL`` sections
     - ``FAILURE`` on ``EI = 0`` decks, standalone and in OpenFAST (a deck with a finite-EI
       cable rejects it); ``CONTROL`` on ``EI = 0`` lines and finite-EI cables in OpenFAST, not
       in FAST.Farm (the standalone driver rejects it). The command changes the segment at the
       line's host-driven end, or at the ``NodeB`` written in the deck when both or neither ends
       are host-driven; a stock-order deck is controlled where MoorDyn-F controls it. A
       command outside MoorDyn-F's bounds (−S/2 ≤ ``DeltaL`` ≤ S with S = ``UnstrLen``/N, the
       same comparison) stops the run, as it stops MoorDyn-F
   * - ``FairTen``, ``AnchTen``, point/node channels
     - same names; tensions in N (:doc:`outputs`). On a line with no ``Fixed`` end the two
       end channels name the opposite ends from MoorDyn's (see above)

What differs on purpose
~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Topic
     - CableDyn
   * - Initial condition
     - always a Newton static equilibrium from an analytical seed; no dynamic relaxation, no
       ``CdScaleIC`` tuning, and no dependence on the time step. Delete any ``ICmode`` row: it
       is not a MoorDyn option and CableDyn rejects it
   * - Element
     - finite elements with an implicit generalised-α integrator, not a lumped-mass explicit
       scheme; ``EI > 0`` lines use a geometrically exact bending element
   * - Time step
     - chosen for accuracy, not stability: an implicit ``dtM`` of 0.025–0.1 s is usual, while an
       explicit lumped-mass scheme needs a far smaller step on stiff chain (the MoorDyn twin deck in
       ``examples/openfast/`` uses 2e-4 s)
   * - Unsupported input
     - rejected at parse time with a message naming the feature, never silently ignored
   * - Node identity
     - line nodes are numbered from 1 at End A, MoorDyn's from 0 at its End A, so a MoorDyn
       deck's ``L<L>N<J>`` names another node here: MoorDyn's ``N<J>`` is CableDyn's ``N<J+1>``
       on a line kept in the order written, and ``N<NumSegs+1-J>`` on a line written
       anchor-first, which CableDyn runs from its fairlead (see above and
       :ref:`node numbering <outputs-moordyn-node-numbers>`). A run reporting line nodes notes
       the difference. Rod nodes keep MoorDyn's numbering (node 0 = End A); rod-node histories
       are not reproduced

Inside OpenFAST
~~~~~~~~~~~~~~~

Set ``CompMooring = 5`` instead of ``3`` and point ``MooringFile`` at the CableDyn (or stock
MoorDyn) deck. Both modules are in the same ``openfast.exe``, so an A/B comparison is one integer
(:doc:`tutorial_openfast`). The supported coupled surface and its limits are in
:doc:`capabilities`.

From OrcaFlex
-------------

CableDyn uses the same line arrangement and conventions as OrcaFlex: a line runs from End A to
End B through sections of different line types and mesh densities; tension is effective
tension; declination, azimuth, and the global frame follow OrcaFlex (:doc:`conventions`).

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - OrcaFlex
     - CableDyn
   * - line type (outer diameter, mass per length, EA, EI, Cd, Ca)
     - ``LINE TYPES`` row; ``Diam`` is the hydrodynamic and displacement diameter
   * - line with sections of different line types and target segment lengths
     - one ``LINES`` row + ordered ``SECTIONS`` rows with explicit ``NumSegs``
   * - End A / End B
     - identical: End A is the fairlead or hang-off, End B the anchor or termination
   * - end connection stiffness (bend stiffness at a line end)
     - ``END CONNECTIONS`` row: numeric rotational stiffness, ``Pinned``, or ``Rigid``
   * - vessel / fixed / anchored connections
     - ``Coupled`` / ``Fixed`` points (``Coupled`` is driven by a ``motionFile``, a
       ``vesselMotion`` record, a ``vesselRAO`` table, or OpenFAST)
   * - 6D buoy, 3D buoy, clump
     - ``Rigid6`` / ``Point3`` bodies, ``Free`` points with mass and volume
   * - lazy wave with distributed buoyancy modules
     - a net-buoyant middle section (equivalent diameter and mass), or an
       ``EQUIVALENT BUOYANCY`` table (:doc:`driver_format`)
   * - seabed stiffness and friction
     - ``kBot``, ``cBot``, ``frictionMu``; flat ``WtrDpth`` or a ``bathymetryFile``
   * - statics
     - automatic: no catenary pre-shape, no user starting shape
   * - range graph (tension, curvature, bend moment vs arc length)
     - ``<root>.static.out`` for the static state; ``<root>.Line<L>.range.out`` (``LINES``
       ``Outputs`` flag ``r``) for the minimum, maximum and mean over a dynamic run
       (:doc:`outputs`)
   * - time-history results
     - ``OUTPUTS`` channels in ``<root>.out``; ``p``/``t`` per-line files
   * - wave and current environment
     - ``waves`` rows (for example ``airy``, ``jonswap``, ``stream``, ``pm``, ``torsethaugen``,
       ``ochihubble``), ``wavetrain`` rows and ``current`` (``uniform``/``profile``) options, or a
       WaterKin file (:doc:`options`); OpenFAST SeaState when coupled

Practical differences: the model is a plain-text SI deck rather than a ``.dat``/``.yml`` model
file; section meshes are given as element counts; and each option is a single keyword row. The
lazy-wave reference cables of :doc:`tutorial_lazywave` were compared with OrcaFlex 11.6d; the
results are in :doc:`validation`.

Porting checklist
-----------------

#. Decide per line: a single-type line may keep the stock 7-column row; a composite becomes one
   ``LINES`` row plus ordered ``SECTIONS`` from End A (fairlead) to End B (anchor).
#. Give cables and bending-dominated lines ``EI > 0``; keep chain and rope at ``EI = 0``.
#. Standalone: add ``WtrDpth`` (and ``g``/``rhoW`` if not default); set either no ``dtM`` (static)
   or both ``dtM`` and ``TMax``. Coupled: OpenFAST supplies depth, density, gravity, and time.
#. Translate the environment: ``waves``, ``current``, ``kBot``/``cBot``/``frictionMu``,
   ``bathymetryFile``.
#. List one channel per ``OUTPUTS`` row; set ``p``/``t`` on lines whose full profile you need.
#. Run the static case first and compare fairlead tension, touchdown, and — for cables — the
   curvature profile with the source model before running dynamics.
#. If the parser rejects something, the message names the feature and the line;
   :doc:`troubleshooting` lists every message and its fix.
