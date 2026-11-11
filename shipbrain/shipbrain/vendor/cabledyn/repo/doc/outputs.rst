.. SPDX-License-Identifier: Apache-2.0

Output files and channels
=========================

This page is the reference for every result file CableDyn writes, the exact layout of each, and
the complete vocabulary of the deck ``OUTPUTS`` section. It covers the standalone driver
(``CableDyn_driver <deck.dat> <out_root>``, see :doc:`cli`) and the coupled module of OpenFAST,
maintained by NLR (National Laboratory of the Rockies, formerly NREL) (``CompMooring = 5``, see
:doc:`openfast`). Deck syntax is in :doc:`driver_format`; the input
files a deck can reference are in :doc:`file_formats`.

Every file is **replaced** on each run (``STATUS='REPLACE'``); CableDyn never appends to a
previous result. All physical quantities are SI: metres, seconds, newtons, radians only where
stated (angles in the output files are always degrees).

.. contents:: On this page
   :local:
   :depth: 2

Standalone driver files
-----------------------

The driver names every file from the ``<out_root>`` argument. Which files appear depends on the
*route* the deck selects, which is decided by the deck content:

.. list-table::
   :header-rows: 1
   :widths: 30 14 14 14 14 14

   * - Deck
     - ``.out``
     - ``.static.out``
     - ``.elements.out``
     - ``.Line<L>.{p,t}.out``
     - ``.Rod<R>.p.out``
   * - Static only (no ``dtM``/``TMax``), all lines ``EI = 0``
     - one row, ``t = 0``
     - yes
     - --
     - static tables
     - --
   * - Dynamic, all lines ``EI = 0``: single lines, and Connect/Free points, Rigid6 bodies
       and rods when they are not on the multibody march (``staggered bodyScheme``, a
       ``motionFile``, a ``FAILURE`` section, ``Coupled``/``Vessel`` rods)
     - time series
     - **no**
     - --
     - time series
     - rod decks only
   * - Dynamic multibody march (bodies, rods or ``Connect``/``Free`` points with their lines,
       ``EI = 0`` or finite-EI; the *Multibody march* of :doc:`driver_format`)
     - time series
     - no
     - --
     - time series
     - yes
   * - Dynamic bodies and rods without lines
     - time series
     - no
     - --
     - --
     - --
   * - Dynamic, all lines finite-EI, every End B on a ``Fixed``, ``Coupled`` or ``Vessel`` point
       (cubic-Hermite route; a ``Coupled``/``Vessel`` End B is a second driven end)
     - time series
     - yes (the converged initial state)
     - yes
     - time series
     - --
   * - Mixed ``EI = 0`` and finite-EI lines (static or dynamic)
     - ``t = 0`` row, plus time series when ``TMax > 0``
     - yes
     - --
     - rejected (fail-closed)
     - --

The ``EI = 0`` dynamic routes never write ``<out_root>.static.out``: use a separate static-only
run of the same deck (remove ``dtM`` and ``TMax``) when the static range table is needed. A
line or rod file is written only when the corresponding ``Outputs`` flag is set. The range graph
``<out_root>.Line<L>.range.out`` of the ``Outputs`` flag ``r`` is written on every route of the
table that has lines, the mixed route included.

Common layout
~~~~~~~~~~~~~

All standalone files are plain ASCII tables:

* fields are separated by a single **TAB** character; numeric fields are also right-justified
  inside a fixed width, so the files align in a terminal and parse with any whitespace splitter;
* the **time** column is Fortran ``ES25.16E3`` (25 characters, 17 significant digits, a
  three-digit exponent, e.g. ``  1.2500000000000000E+001``) so that time stamps survive long
  runs with small ``dtM`` without rounding;
* every other real value is Fortran ``ES15.7E3`` (15 characters, 8 significant digits, e.g.
  `` 5.0988032E+005``, three-digit exponent, so round-off noise below 1e-99 in a component that
  is zero still prints as a number);
* integer key columns (``LineID``, ``Node``, ``Element``, ``Segment``) are written without
  padding (``I0``);
* a non-finite channel value is never written: a dynamic row that would contain ``NaN`` or
  ``Inf`` stops the run with a named error and exit code 2.

``<out_root>.out`` — the main table
-----------------------------------

Written by every route. Layout:

.. list-table::
   :header-rows: 1
   :widths: 14 86

   * - Line
     - Content
   * - 1
     - title line beginning with ``#`` (see below)
   * - 2
     - header row: ``Time(s)`` followed by each ``OUTPUTS`` channel token **exactly as written
       in the deck** (original spelling and case)
   * - 3 …
     - one data row per output time

There is **no units row**: units are fixed by the channel vocabulary below (the Python reader
:func:`cabledyn.read_output` attaches them automatically). A deck without an ``OUTPUTS``
section produces a valid file containing only the ``Time(s)`` column.

The title line identifies the route that produced the file:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Route
     - Title line
   * - static
     - ``# CableDyn driver output (static IC; converged=T)`` (``converged=F`` when a line did
       not converge — the file is then written for inspection and the driver exits with 2)
   * - ``EI = 0`` single-line dynamics
     - ``# CableDyn driver output (dynamic; convergence quality is reported by status message)``
   * - Connect/Free-point dynamics
     - ``# CableDyn driver output (dynamic points; convergence quality is reported by status
       message)``
   * - Rigid6 bodies
     - ``# CableDyn driver output (Rigid6 dynamic; convergence quality is reported by status
       message)``
   * - rods
     - ``# CableDyn driver output (rod dynamic; convergence quality is reported by status
       message)``
   * - finite-EI (cubic-Hermite, one or two moving ends)
     - ``# CableDyn driver output (finite-EI dynamic; production cubic-Hermite route)``
   * - mixed ``EI = 0`` + finite-EI
     - ``# CableDyn driver output (mixed aggregate dynamic; convergence quality is reported by
       status message)``
   * - multibody march
     - ``# CableDyn driver output (multibody dynamic; convergence quality is reported by status
       message)``
   * - bodies and rods without lines
     - ``# CableDyn driver output (bodies and rods without lines, dynamic)``

Rows: a static run writes one row at ``t = 0``. A dynamic run writes the initial state at
``t = 0`` and then one row after every committed step, at ``t = k·dtM`` for
``k = 1 … NINT(TMax/dtM)``. The deck keyword ``dtOut`` is accepted for MoorDyn compatibility
but has no effect: the output cadence is always ``dtM``.

If a dynamic step does not converge, the march stops, the file keeps only the rows of committed
steps, and the driver exits with code 2. Such a file is a diagnostic record, not an accepted
response history.

Example (static route)::

   # CableDyn driver output (static IC; converged=T)
   Time(s)	FairTen1	AnchTen1	FairIncl1	AnchIncl1
     0.0000000000000000E+000	 5.0988032E+005	 1.9241379E+005	 6.7242193E+001	-6.8947041E-001

``<out_root>.static.out`` — static range table
----------------------------------------------

The along-arc static configuration, one row per node of every line (a *range graph* of the static
state): every node of the line's final mesh, so a finite-EI line whose mesh the static solve
refined has more rows than deck nodes (see :ref:`outputs-refined-nodes`). It is independent of
the ``OUTPUTS`` selection. On a dynamic cubic-Hermite or mixed
run it records the converged initial state that the march starts from.

Layout: title line, header row, **units row**, then data. The title reads
``CableDyn static configuration profile (deformed arc; public node order EndA -> EndB)``
(static route), ``CableDyn standalone static configuration (deformed arc; public node order
End A -> End B)`` (cubic-Hermite route) or ``CableDyn coupled static configuration (deformed
arc; public node order End A -> End B)`` (mixed route and OpenFAST). The columns are identical
on every route; the ``DeckNode`` column follows only when the static solve refined the mesh of a
finite-EI line of the run:

.. list-table::
   :header-rows: 1
   :widths: 18 10 72

   * - Column
     - Unit
     - Meaning
   * - ``LineID``
     - ``(-)``
     - deck ``LINES`` id (keys the rows when several lines are present)
   * - ``Node``
     - ``(-)``
     - node number, 1 = End A … N = End B
   * - ``ArcLength``
     - ``(m)``
     - cumulative **deformed** chord length from End A
   * - ``X`` ``Y`` ``Z``
     - ``(m)``
     - node position in the global frame (Z up, ``Z = 0`` at the still-water line)
   * - ``Tension``
     - ``(N)``
     - nodal effective tension (same definition as ``Ten<L>N<J>``)
   * - ``Curvature``
     - ``(1/m)``
     - nodal curvature (same definition as ``Curv<L>N<J>``)
   * - ``BendMoment``
     - ``(N.m)``
     - bend moment (same definition as ``BendMom<L>N<J>``: the cable's own share under a bend
       stiffener); written as 0 by the ``EI = 0`` static route
   * - ``Declination``
     - ``(deg)``
     - axial-tangent angle from +Z (0 = up, 90 = horizontal, 180 = down); the
       :ref:`node tangent <outputs-node-tangent>`
   * - ``Inclination``
     - ``(deg)``
     - signed inclination below horizontal, ``Declination − 90``
   * - ``Azimuth``
     - ``(deg)``
     - axial-tangent azimuth from +X toward +Y, in the line's range (:ref:`outputs-azimuth-range`)
   * - ``DeckNode``
     - ``(-)``
     - the deck node of the row, the ``<J>`` of the node channels (1 = End A … 1 + the total
       ``NumSegs`` of the line's sections = End B); 0 for a node the refinement added. An
       ``EI = 0`` line, never refined, numbers its rows as the deck. Written only when a line's
       mesh was refined

Plot ``Curvature`` or ``Tension`` against ``ArcLength`` for a fatigue or strength check.

.. note::

   On a finite-EI line the ``Tension``, ``Curvature`` and ``BendMoment`` columns and the
   ``Ten``/``Curv``/``BendMom`` channels are recovered from nodal equilibrium
   (:ref:`theory-output-recovery`): the effective tension :math:`\mathbf F\cdot\mathbf t`
   is the axial component of the section force that balances the loads, and the bend moment
   is the moment the elements on either side of the node carry. ``.elements.out`` holds the
   pointwise element fields instead: the ``MinimumAxialResultant`` and
   ``MaximumAxialResultant`` columns are extrema of the material axial force
   :math:`EA\,(|\mathbf r'| - 1)`, which exceeds the effective tension by
   :math:`EI\kappa^2` and, with a stiff ``EA``, oscillates about the element mean wherever an
   element cannot follow the line -- at a nodal seabed-contact kink near touchdown and at a
   section junction -- and can dip below zero there while the line is tensile. ``OPTIONS``
   ``OutputRecovery element`` reports the element definitions in the node columns and channels
   (:doc:`options`).

``<out_root>.elements.out`` — Hermite element extrema
-----------------------------------------------------

Written by the cubic-Hermite route together with ``.static.out``. For every element of every
finite-EI line it records the extrema of the **continuous** element fields at the converged
initial state — located by searching the whole cubic field, not only nodes or quadrature points
— so peak curvature between nodes is not missed. Element 1 is at End A; the local coordinate
``xi`` runs from 0 at the End-A side of the element to 1 at its End-B side.

Layout: title line ``CableDyn continuous Hermite-element extrema (public order End A -> End
B)``, header row, units row, data (12 columns):

.. list-table::
   :header-rows: 1
   :widths: 26 10 64

   * - Column
     - Unit
     - Meaning
   * - ``LineID``
     - ``(-)``
     - deck ``LINES`` id
   * - ``Element``
     - ``(-)``
     - element number, 1 = End A
   * - ``ReferenceArcStart``
     - ``(m)``
     - unstretched arc length from End A to the element's End-A side
   * - ``ReferenceArcEnd``
     - ``(m)``
     - unstretched arc length from End A to the element's End-B side
   * - ``PeakXi``
     - ``(-)``
     - local coordinate of the curvature maximum
   * - ``PeakReferenceArc``
     - ``(m)``
     - unstretched arc length of the curvature maximum
   * - ``PeakCurvature``
     - ``(1/m)``
     - maximum curvature over the element; under a bend stiffener the curvature of the section,
       the moment over the stiffness ``EI(s)`` along the element, not of the interpolation
       (:ref:`theory-bend-stiffeners`)
   * - ``BendMomentAtPeak``
     - ``(N.m)``
     - ``EI × PeakCurvature``, with the line type's ``EI`` (the cable's share under a bend
       stiffener)
   * - ``MinimumAxialResultant``
     - ``(N)``
     - minimum axial force resultant over the element (negative = compression)
   * - ``MinimumXi``
     - ``(-)``
     - local coordinate of that minimum
   * - ``MaximumAxialResultant``
     - ``(N)``
     - maximum axial force resultant over the element
   * - ``MaximumXi``
     - ``(-)``
     - local coordinate of that maximum

Per-line files (``LINES`` ``Outputs`` flag)
-------------------------------------------

Set the ``Outputs`` column of a ``LINES`` row to any combination of the letters below (e.g.
``ptr``); ``-`` or an empty field requests nothing. ``p``, ``t`` and ``r`` are case-insensitive;
``V`` is upper case, as in MoorDyn, whose lower-case ``v`` (node velocities) CableDyn does not
write. Any other letter is a parse error. Mixed ``EI = 0`` + finite-EI decks reject the ``p``,
``t`` and ``V`` flags (use main-file channels instead) and accept ``r``.

.. list-table::
   :header-rows: 1
   :widths: 10 40 50

   * - Flag
     - File
     - Contents
   * - ``p``
     - ``<out_root>.Line<L>.p.out``
     - node positions, End A → End B
   * - ``t``
     - ``<out_root>.Line<L>.t.out``
     - segment (element) tensions, End A → End B; on a finite-EI line the mean of the axial
       components of the element's own two equilibrium end forces (``OutputRecovery element``:
       the axial resultant at the element midpoint)
   * - ``V``
     - ``<out_root>.Line<L>.V.out``
     - cross-flow VIV lift force at the nodes, End A → End B, on dynamic runs (MoorDyn's line
       flag ``V``; a static run carries no lift and writes no file). On an ``EI = 0`` line the
       end nodes carry none, as in MoorDyn; on a finite-EI line each element's lift is lumped to
       its two nodes (the translational part of its consistent load), so the end nodes carry
       the lift of their half-elements. Zero on a line without VIV (``Cl = 0``)
   * - ``r``
     - ``<out_root>.Line<L>.range.out``
     - range graph: minimum, maximum and mean over the run of the node tension, curvature, bend
       moment, declination and seabed clearance (and torque and twist on a line with torsion),
       one row per node (see below)

``<L>`` is the deck line id. The files list every node and segment of the line's final mesh,
also on a finite-EI line whose mesh the static solve refined (:ref:`outputs-refined-nodes`).
Each file starts with a ``#`` comment line (e.g.
``# CableDyn static line node positions; public node order EndA -> EndB``) and a header row;
there is no units row — units are in the column names. On a refined line the ``.p.out`` file
has a second comment line, ``# DeckNode`` followed by one tab-separated integer per node: the
deck node of that node, 0 for a node the refinement added.

.. list-table::
   :header-rows: 1
   :widths: 20 40 40

   * - File
     - Static run (one row per node / segment)
     - Dynamic run (one row per output time)
   * - ``.p.out``
     - ``Node  X(m)  Y(m)  Z(m)``
     - ``Time(s)  Node1X(m)  Node1Y(m)  Node1Z(m)  Node2X(m) …  Node<N>Z(m)``
   * - ``.t.out``
     - ``Segment  Tension(N)``
     - ``Time(s)  Segment1Tension(N)  Segment2Tension(N) …  Segment<N−1>Tension(N)``
   * - ``.V.out``
     - (none)
     - ``Time(s)  Node1LiftX(N)  Node1LiftY(N)  Node1LiftZ(N)  Node2LiftX(N) …  Node<N>LiftZ(N)``

Dynamic per-line rows are written at the same times as ``.out``.

``<out_root>.Line<L>.range.out`` — range graphs
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The OrcaFlex range graph of line ``L``, accumulated by the solver during the run: at every node,
the minimum, maximum and mean over the output times of the range window. The window holds every
``.out`` row with ``t ≥ RangeStart`` (OPTION ``RangeStart``, default 0, see :doc:`options`), so a
start-up transient can be excluded; a static run has one sample, ``t = 0``. The values are the
node channels of the same run, ``Ten<L>N<J>``, ``Curv<L>N<J>``, ``BendMom<L>N<J>`` and
``L<L>N<J>Dec`` (and ``Torq<L>N<J>`` and ``Twist<L>N<J>`` on a line with torsion), evaluated at
every node: the minimum and maximum equal those of the channel time
histories exactly, and the mean is their arithmetic mean. The file is written when the run
completes; a run that stops early leaves none.

A single-turbine OpenFAST run writes the same file as ``<RootName>.CD.Line<L>.range.out``. Its
samples are the rows of ``<RootName>.CD.out``: the state at ``t = 0`` and every committed ``dtM``
step, once each whatever ``DT``, ``DT_Out`` and the correction iterations are; a step OpenFAST
corrects counts once, with its corrected state. The accumulators are double precision on every
OpenFAST build and travel in the checkpoint, so a restart continues them. The file is written at
the end of a run that completes, whenever the host ends it: at ``TMax``, at a steady state found
by ``CalcSteady``, or at FAST.Farm's last whole ``DT_Low``, and holds the samples up to there.
The run removes a file left by an earlier run as soon as its deck is parsed, and a run that stops on
an error after that, in any module, leaves none. A deck that does not parse, or a module that stops
before CableDyn starts, leaves every output of the earlier run as it was. A turbine's own CableDyn
instance in FAST.Farm (``CompMooring = 5`` in its ``.fst``) writes
``<RootName>.T<n>.CD.Line<L>.range.out``. A FAST.Farm shared mooring and the C API write no range
file and reject the flag by name.

Layout: title line, header row, **units row**, then one row per node, End A first. The title reads
``CableDyn range graph (line <L>; <n> samples from t = <t0> s to t = <t1> s; public node order
End A -> End B)``.

.. list-table::
   :header-rows: 1
   :widths: 30 10 60

   * - Column
     - Unit
     - Meaning
   * - ``Node``
     - ``(-)``
     - node number of the line's final mesh, 1 = End A … N = End B (the ``Node`` of
       ``.static.out``)
   * - ``ArcLength``
     - ``(m)``
     - cumulative deformed chord length from End A at the first sample (``t = 0``, the static
       initial state; the ``ArcLength`` of ``.static.out``)
   * - ``TensionMin`` ``TensionMax`` ``TensionMean``
     - ``(N)``
     - effective tension, as ``Ten<L>N<J>`` (end nodes: the ``FairTen``/``AnchTen`` end force)
   * - ``CurvatureMin`` ``CurvatureMax`` ``CurvatureMean``
     - ``(1/m)``
     - curvature, as ``Curv<L>N<J>``
   * - ``BendMomentMin`` ``BendMomentMax`` ``BendMomentMean``
     - ``(N.m)``
     - bend moment, as ``BendMom<L>N<J>`` (0 on ``EI = 0`` lines)
   * - ``DeclinationMin`` ``DeclinationMax`` ``DeclinationMean``
     - ``(deg)``
     - declination of the axial tangent, as ``L<L>N<J>Dec``
   * - ``ClearanceMin`` ``ClearanceMax`` ``ClearanceMean``
     - ``(m)``
     - seabed clearance: node ``z`` minus the seabed elevation below the node (flat ``WtrDpth``
       or the ``bathymetryFile`` surface); negative where the node penetrates the penalty seabed.
       Present only when the deck defines a seabed
   * - ``TorqueMin`` ``TorqueMax`` ``TorqueMean``
     - ``(N.m)``
     - torque, as ``Torq<L>N<J>``. Present only on a line solved in torsion (restrained at both
       ends, or at one end with the other free)
   * - ``TwistMin`` ``TwistMax`` ``TwistMean``
     - ``(deg)``
     - twist of the cable from End A to the node, as ``Twist<L>N<J>``. Present only on a line
       solved in torsion

The accumulation keeps three numbers per node and quantity and makes no heap allocation per step.
Sampling a line evaluates its node channels once per output row; on the 1024-element cubic-Hermite
lazy-wave example this adds about 3 % to the step time. A coupled OpenFAST run does not write range
files and rejects the ``r`` flag; use the ``TDP<L>`` and node channels there.

``<out_root>.modes.out`` — natural frequencies and mode shapes
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Written when the deck sets ``nModes`` (see :doc:`options`), before any dynamic march. The file
holds two tab-separated tables, each introduced by a ``#`` comment line, a header row and a units
row:

* ``# Natural frequencies``: ``LineID  Mode  Frequency  Period  Omega`` (Hz, s, rad/s), the
  ``nModes`` lowest modes of every line in ascending order of :math:`\omega^2`. A mode with
  :math:`\omega^2 < 0`, an instability of the static state (a planar equilibrium that is
  unstable out of its plane, a compressed strut), is written with the signed values
  ``Omega`` :math:`= -\sqrt{|\omega^2|}` and ``Frequency`` :math:`= -\sqrt{|\omega^2|}/2\pi` and
  ``Period`` 0, and the run prints a note naming the line and the number of such modes;
* ``# Mode shapes``: ``LineID  Mode  Node  X  Y  Z  dX  dY  dZ``, one row per mode and node.
  ``X Y Z`` is the static node position and ``dX dY dZ`` the nodal translation of the mode,
  scaled so that the largest nodal displacement of the mode is 1. Nodes are numbered End A first,
  as in the other line files; the held end nodes have zero displacement. The sign of a mode
  makes the largest component of its mode vector positive; where two components are equally
  large (the mirrored nodes of a symmetric line), the first of them in the solver's node order.

When a line is restrained in torsion (both ends, see :doc:`driver_format`), its modes carry the
twist angle of every node (:ref:`nodal twist <theory-nodal-twist>`) and both tables gain a
column, for every line of the file (``0`` on a line without torsion):

* ``PolarShare`` (frequency table): the polar share of the mode's kinetic energy,
  :math:`\sum_k I_k \varphi_k^2` of the mass-normalised mode with :math:`I_k` the lumped polar
  inertia, 1 for a pure torsional mode and 0 for one without twist;
* ``dTwist`` (shape table): the rotation of the node's section about the line tangent,
  positive right-handed about the direction from End A to End B, End A being the reader's
  (the fairlead on a deck written anchor-first, as in the other line files). Like ``dX dY dZ``
  it is a normalised shape value, marked ``(-)``: the mode is scaled so that its largest nodal
  displacement is 1, and ``dTwist`` is then in rad per metre of that displacement; a torsional
  mode (``PolarShare`` above 0.5) is scaled to a unit largest ``dTwist`` instead, and its
  translations are then in metres per radian of that twist.

:func:`cabledyn.read_output` reads both tables into a :class:`cabledyn.NaturalModes`.

Per-rod files (``RODS`` ``Outputs`` flag)
-----------------------------------------

For a dynamic rod deck, set a rod's ``Outputs`` field to ``p`` to write
``<out_root>.Rod<R>.p.out`` (``<R>`` = deck rod id). ``p`` is the only rod flag; any other
letter is a parse error. Layout: ``#`` comment line, header row
``Time(s)  EndAX(m)  EndAY(m)  EndAZ(m)  EndBX(m)  EndBY(m)  EndBZ(m)``, then one row per
output time.

``OUTPUTS`` channel vocabulary
------------------------------

Channel names are listed in the deck ``OUTPUTS`` section. Each row may hold one or several
names separated by whitespace, commas or tabs, optionally quoted with ``"`` or ``'`` (the
OpenFAST ``OutList`` style). Maintained decks use one double-quoted name per row::

   ---------------------- OUTPUTS -----------------------------------------
   "FairTen1"
   "AnchTen1"
   "Ten1N10"
   "L1N10pz"
   -------------------------------------------------------------------------

Matching is **case-insensitive** (``fairten1`` = ``FairTen1``), but the header row repeats the
token as written. A name may be at most 64 characters. Each channel may be requested **once**:
the deck is rejected (exit code ``1``, naming the channel, the earlier spelling and the deck
line) when two names select the same quantity -- the same name in any case or across rows, a
numeric id written with leading zeros (``Ten1N02`` = ``Ten1N2``), or an alias spelling
(``Con<P>p{x,y,z}`` = ``Point<P>p{x,y,z}``, ``FairAngle<L>`` = ``FairDecl<L>``,
``AnchAngle<L>`` = ``AnchDecl<L>``). ``<L>`` and ``<P>`` are deck
``LINES`` and ``POINTS`` ids (not array positions); ``<J>`` is a node number on line ``<L>``,
1 = End A to ``N`` = End B, where ``N`` = 1 + the total ``NumSegs`` of the line's sections.

.. _outputs-moordyn-node-numbers:

This is **not MoorDyn's numbering**. MoorDyn numbers a line's nodes from 0 at its End A
(``AttachA``) to ``NumSegs``, so on a line kept in the order written ``L<L>N<J>`` here is MoorDyn's
``L<L>N<J-1>``. A line written anchor-first (``AttachA`` a ``Fixed`` anchor, ``AttachB`` the
fairlead) runs from its fairlead here (:doc:`migrating`), so its ``N<J>`` is MoorDyn's
``N<NumSegs+1-J>``. The per-line files (``Node<J>…`` columns) number the same way. A run whose
outputs name line nodes says so in a note, and ``N0`` is rejected rather than read as another node.

.. _outputs-azimuth-range:

Azimuth range
~~~~~~~~~~~~~

The azimuth of a line's tangent (``L<L>N<J>Azi``, the ``Azimuth`` column of the static profile
and the azimuth of the initialisation summary) is reported in **(−180, 180]** on a line whose
chord from End A to End B, at the deck positions, heads within 45° of +X, and in **[0, 360)** on
every other line. The cut of a line's range then lies at least 45° from its heading: a line
swaying about its heading reads continuously, where a line along +X would otherwise jump
between 0 and 360 as it moves a fraction of a degree to either side. The range is fixed for
the run, so the motion of the line cannot switch it, and the same on every route: the standalone
driver, the C API and Python, and OpenFAST. A round-off component across the cut
reads on its included side (0, or 180 in the signed range), and one across +X reads exactly 0.
A line a host builds through the C interface without a deck reports [0, 360).

.. _outputs-refined-nodes:

Node channels on a refined line
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``<J>`` is always a node of the **deck** mesh. The static solve of a finite-EI line can refine
its mesh (``OPTIONS adaptive_mesh``, or the automatic refinement after a failed stability test
or an unresolved curvature, which a note of the initialization report names). A refinement splits
deck elements (along the whole line or only where the state needs it), so each deck node is a
node of the refined mesh at the same unstretched arc length from End A, and ``Ten<L>N<J>``,
``Curv<L>N<J>``, ``BendMom<L>N<J>``, ``L<L>N<J>…``, ``Torq<L>N<J>`` and ``Twist<L>N<J>`` report deck node ``J`` there, on every route (standalone,
mixed, multibody, OpenFAST and the C API ``CableDyn_EvalChannel``). ``.static.out``, the range
graphs, the per-line files and the C API ``CableDyn_GetLineValues`` list every node of the
refined mesh instead, and ``.elements.out`` every element. To find deck node ``J`` among them,
take the ``.static.out`` row whose ``DeckNode`` is ``J``: its ``Node`` is the node number in the
range graph and the per-line files (and the array row + 1 of ``CableDyn_GetLineValues``), its
``ArcLength`` the node's deformed arc length. The ``# DeckNode`` line of ``.Line<L>.p.out`` gives
the same numbering on routes that write no ``.static.out`` (the multibody march), and the C API
quantity ``CD_C_LINE_DECK_NODE`` (Python ``Line.deck_nodes``) in process. The deck node also lies
where the ``ReferenceArcStart`` of ``.elements.out`` equals its unstretched arc length from End A
(``ReferenceArcEnd`` of the last element for End B). ``EI = 0`` lines are never refined.

Line-end channels
~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 24 56 20

   * - Channel
     - Meaning
     - Unit
   * - ``FairTen<L>``
     - line-end tension at End A (fairlead) of line ``L``: on an EI = 0 line, the magnitude of
       the force the line actually exerts on its End-A point -- the end element's tension
       including axial damping, plus the end node's lumped loads (its share of the submerged
       weight, seabed contact and drag at the actual relative velocity), as MoorDyn and
       OrcaFlex report it. It equals the coupled load on that point less the end node's
       inertia, and at rest it is the static end reaction, so the static, ``TMax = 0`` and
       dynamic routes agree at the initial condition. A finite-EI line reports the same
       quantity: the end element's internal end force (axial and bending shear, axial
       damping) plus the end node's share of the submerged weight, buoyancy lost above the
       surface, seabed contact with its damping, and ambient-fluid drag at the actual
       velocity; an end resting on the seabed leaves the end node's weight to the floor. With
       bending it is the end-force magnitude, not the axial effective tension:
       where the end shear is significant it exceeds OrcaFlex's end ``Effective tension`` and
       matches the magnitude of its end ``GX``/``GZ`` force. Seabed friction at a grounded end
       node is part of the ``EI = 0`` end force but not of the finite-EI (cubic-Hermite) end
       force, which leaves the end node's friction, like its inertia, in the coupled load; the
       two agree whenever the end node is off the seabed or friction is off
     - N
   * - ``AnchTen<L>``
     - line-end tension at End B (anchor) of line ``L``, defined as for ``FairTen``. On a
       grounded run it is close to the horizontal tension. A ``Fixed`` anchor at the seabed
       depth sits slightly above the grounded chain, which sinks into the penalty seabed, so the
       anchor also carries its end node's weight (for example 192.4 kN against a horizontal
       tension of 191.5 kN in :doc:`tutorial_catenary`; see `Anchor uplift`_)
     - N
   * - ``AnchFz<L>``
     - vertical component of the ``AnchTen<L>`` end force, the force line ``L`` exerts on its
       End-B point: positive upward (the line lifts the anchor), negative downward. On every
       route that reports ``AnchTen``, a moving End B included; for an anchor that holds one line
       it equals ``Point<P>Fz``
     - N
   * - ``AnchFH<L>``
     - horizontal magnitude of the same end force, :math:`\sqrt{F_x^2 + F_y^2}`, with the same
       availability; for an anchor that holds one line it equals ``Point<P>FH``
     - N
   * - ``FairIncl<L>`` / ``AnchIncl<L>``
     - signed inclination of the End-A / End-B tangent (:ref:`node tangent <outputs-node-tangent>`)
       below horizontal
       (``Decl − 90``: 0 = horizontal, +90 = pointing down, −90 = pointing up)
     - deg
   * - ``FairDecl<L>`` / ``AnchDecl<L>``
     - declination of the End-A / End-B tangent from +Z (0 = up, 90 = horizontal, 180 = down)
     - deg
   * - ``FairAngle<L>`` / ``AnchAngle<L>``
     - aliases of ``FairDecl<L>`` / ``AnchDecl<L>``
     - deg
   * - ``FairDefl<L>`` / ``AnchDefl<L>``
     - deflection of the End-A / End-B end force (``FairTen`` / ``AnchTen``) from the direction
       a ``Rigid`` or rotational-spring ``END CONNECTIONS`` row holds at that end, turning with
       the body or vessel it is on: 0 when the line leaves the connection along that direction.
       With the end force, the load case of a bend stiffener or hang-off design. Only at an end
       with such a row
     - deg

A grounded anchor segment reads ``AnchIncl ≈ 0``; the small non-zero value reports the actual
orientation of the last element, which CableDyn does not force to horizontal.

Anchor uplift
~~~~~~~~~~~~~

A drag-embedment anchor is designed for a horizontal pull and loses holding capacity under a
vertical one, so design practice for catenary moorings (DNV-OS-E301, API RP 2SK) requires no
vertical uplift at the anchor in the intact condition: some chain stays laid on the seabed. The
primary check for line ``L`` is the grounded length:

* the minimum of ``TDP<L>Grd`` (`Touchdown channels`_) over the run is greater than a small
  tolerance (0.01 m is a centimetre, far below an element). ``TDP<L>Grd`` is continuous with
  the touchdown point, so an anchor node held on the seabed beside a node a few millimetres
  clear of it reads micrometres to millimetres, not exactly 0. ``AnchIncl<L>`` departing from 0
  (the anchor segment rising from the seabed) shows the same onset.

``AnchFz<L>`` is the anchor reaction itself (equal to ``Point<P>Fz`` of a one-line anchor), the
quantity to compare with the anchor's vertical capacity. It is not an exact uplift indicator on
an ``EI = 0`` line: the reaction includes the anchor node's lumped weight (below), so it stays
negative for a while after the anchor segment starts to lift and turns positive only once the
line's pull exceeds that weight. When a surge pulls the chain off its anchor the sign change
lags the grounded length reaching 0 (by under a second in the regression suite's surge case),
so ``max AnchFz <= 0`` alone can pass a run in which the anchor segment already lifts by an
angle of order :math:`w\,\Delta L/(2H)`. Use ``TDP<L>Grd`` (or ``AnchIncl<L>``) for the
no-uplift criterion and ``AnchFz<L>`` for the vertical load.

On a laid ``EI = 0`` line ``AnchFz`` is a small negative value, not 0. The anchor node of a
``Fixed`` point at the seabed depth is held at the seabed elevation, while the penalty seabed
lets the grounded line sink by :math:`\delta = w/(k_\text{Bot}\,d)` (:math:`w` the submerged
weight per unit length, :math:`d` the line diameter, see :doc:`conventions`). The anchor
therefore carries the end node's lumped submerged weight, :math:`w\,\Delta L/2` for an anchor
segment of unstretched length :math:`\Delta L`, and the downward pull of the anchor segment
toward the sunk line, about :math:`H\delta/\Delta L` for a horizontal tension :math:`H`:

.. math::

   \mathtt{AnchFz} \approx -\left(\frac{w\,\Delta L}{2} + \frac{H\,\delta}{\Delta L}\right).

In :doc:`tutorial_catenary` (:math:`w` = 3.18 kN/m, :math:`\Delta L` = 10 m,
:math:`\delta` = 0.13 m) this estimate is −18.4 kN, and the run reports ``AnchFz1`` = −18.2 kN
beside ``AnchFH1`` = 191.5 kN (the horizontal tension) and ``AnchTen1`` = 192.4 kN. The share
belongs to the lumped anchor node: it scales with the anchor segment length, vanishes as the mesh
is refined, and is not uplift. A finite-EI (cubic-Hermite) end resting on the seabed leaves the
part of its end force pressing into the floor (along the floor normal) to the floor: on a flat
seabed that is the end node's weight, and ``AnchFz`` reads 0 there. On a sloped seabed
(``bathymetryFile``) the anchor keeps the line's along-floor pull, so a line laid down the slope
from its anchor reads a negative ``AnchFz``, the down-slope component of its tension; on a
frictional seabed (``frictionMu``) the floor also holds the along-floor part of the end node's
own weight, up to the friction coefficient times that normal load. Read the vertical anchor load
from ``AnchFz``, not from the difference between ``AnchTen`` and ``AnchFH``.

Line-node channels
~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 24 56 20

   * - Channel
     - Meaning
     - Unit
   * - ``Ten<L>N<J>``
     - effective tension at node ``J``. ``EI = 0`` lines: an interior node takes the mean of
       its two neighbouring element (segment) tensions. Finite-EI lines: the axial component
       :math:`\mathbf F\cdot\mathbf t` of the section force recovered from nodal equilibrium,
       the mean of the end forces of the two neighbouring elements, each with its own
       distributed loads and inertia (:ref:`theory-output-recovery`); ``OutputRecovery
       element``: the length-weighted mean of the element-mean axial forces
       :math:`EA(|\mathbf r'| - 1)`. An end node reports the line-end force of ``FairTen`` /
       ``AnchTen``, the end reaction on the support or platform, which excludes inertia, added
       mass and seabed friction (the interior values are the recovered section force, whose
       element end forces include inertia and added mass)
     - N
   * - ``Curv<L>N<J>``
     - curvature at node ``J``. ``EI = 0`` lines: discrete curvature of the circle through
       the node and its two neighbours (end nodes take the adjacent interior value).
       Cubic-Hermite lines: the geometric curvature of the stretched line, the reciprocal of the
       bend radius, ``(1 + ε) BendMom<L>N<J>`` / ``EI`` with ``ε`` the axial strain at the node,
       the larger of the two sides at a section junction (under a bend stiffener ``(1 + ε)``
       times the section moment over the stiffness ``EI(s)`` at the node,
       :ref:`theory-bend-stiffeners`), and the exact geometric curvature where
       ``EI`` is below ``max(|w| L0^2)/12`` times 1 m (:ref:`theory-output-recovery`) (``OutputRecovery
       element``: exact curvature of the continuous
       centreline, the larger of the two one-sided element values at an interior node; the
       recovered moment over ``EI(s)`` on an element with a bend stiffener sleeve). The
       library routines ``CD_HermiteCable_Dyn_Curvature`` and ``CD_HFMF_Curvature`` return the
       same value; ``CD_HermiteCable_Dyn_Curvature_Exact`` and ``CD_HFMF_Curvature_Exact`` the
       exact geometric traces
     - 1/m
   * - ``CurvX<L>N<J>``, ``CurvY<L>N<J>``
     - the curvature vector at node ``J`` on the cross-section axes x and y of a finite-EI line
       (:ref:`theory-section-curvature`): the vector points to the centre of curvature, its
       length is ``Curv<L>N<J>`` (``CurvX² + CurvY² = Curv²``), and a section point at (x, y)
       has the bending strain ``−(CurvX x + CurvY y)``. The axes start at End A from the end
       connection, follow the hang-off when End A is clamped, and are carried along the line,
       turned by the twist when the line is restrained in torsion. ``EI = 0`` lines refuse the
       channels. ``CD_HFMF_Section_Curvature``
       returns them for every node
     - 1/m
   * - ``BendMom<L>N<J>``
     - bend moment ``EI × κ / (1 + ε)``, the moment that balances the forces on the section (it
       is ``EI × κ`` to within the axial strain ``ε``), measured relative to the stress-free
       reference shape (the cubic-Hermite reference is straight). Finite-EI lines: the moment
       recovered from nodal equilibrium, the mean of the two neighbouring elements
       (one-sided at a line end, where it is the end connection moment);
       ``OutputRecovery element``: ``EI`` times the larger one-sided exact curvature. 0 on
       ``EI = 0`` lines. Under a bend stiffener (``STIFFENERS``) it is the cable's own share,
       the section moment times the line type's ``EI`` over the stiffness ``EI(s)`` at the node;
       the stiffener's share is ``StfMom<L>N<J>`` and the two add up to the section moment
     - N·m
   * - ``StfMom<L>N<J>``
     - the share of the section moment a bend stiffener carries at node ``J``, the section
       moment less ``BendMom<L>N<J>``; 0 where no stiffener covers the node. Only on a line with
       ``STIFFENERS``
     - N·m
   * - ``L<L>N<J>px`` / ``py`` / ``pz``
     - node position component
     - m
   * - ``L<L>N<J>vx`` / ``vy`` / ``vz``
     - node velocity component (0 on a static run)
     - m/s
   * - ``L<L>N<J>ax`` / ``ay`` / ``az``
     - node acceleration component (0 on a static run)
     - m/s²
   * - ``L<L>N<J>Dec``
     - declination of the node's axial tangent from +Z (0 = up, 90 = horizontal, 180 = down);
       the :ref:`node tangent <outputs-node-tangent>`
     - deg
   * - ``L<L>N<J>Azi``
     - azimuth of the node's axial tangent from +X toward +Y, in the line's range
       (:ref:`outputs-azimuth-range`)
     - deg
   * - ``Torq<L>N<J>``
     - torque (twisting moment) at node ``J`` of a line restrained in torsion at both ends, or at
       one end with the other free to twist (``END CONNECTIONS`` ``TorsStiffness``, see
       :doc:`driver_format`; zero in the statics of a line free at one end). In the statics it is
       uniform along the line, :math:`M = (\Phi - \Theta_{\text{eff}})/C`
       (:math:`\Theta_{\text{eff}} = \Theta` without torque–tension coupling); in the dynamics it
       is the nodal twist's torque at the node, the mean of its two elements' (an end node's
       element; :ref:`nodal twist <theory-nodal-twist>`). Positive for a right-handed twist of End B relative
       to End A about the End A → End B tangent, as OrcaFlex's ``Torque``
     - N·m
   * - ``Twist<L>N<J>``
     - material twist of the cable itself from End A to node ``J``, the sum of the element
       twists :math:`M L_e/GJ_e` (less :math:`(K/GJ)(l_e - L_e)` under torque–tension coupling;
       in the dynamics the nodal twist's element twists) over the elements between them: 0 at
       End A, and at End B the
       twist of the line without the windup of its torsional end springs. OrcaFlex reports the
       twist rate (``Twist``, deg/m) instead; here it is integrated from End A
     - deg
   * - ``Twist<L>``
     - total twist of the line, :math:`\Phi - \Theta = M C`, including the windup of
       torsional end springs: the imposed twist :math:`\Phi` less the geometric twist
       :math:`\Theta` the line takes up by writhing out of its plane (in the dynamics the
       element twists plus the end springs' windup). On a line free in torsion at one end, the
       twist of its elements (no windup at the free end), still the turn of End B relative to
       End A: a free End B turns by ``+Twist<L>`` and a free End A by ``−Twist<L>`` against
       the restrained end's frame carried along the line; statically
       :math:`-\sum (K/GJ)(l_e - L_e)` under torque–tension coupling
     - deg

Touchdown channels
~~~~~~~~~~~~~~~~~~

For a line that rests on the seabed at one end, the touchdown point (TDP) at every output time.
A node is grounded when its centreline is at most 1e-6 m (the height at which the seabed contact
law engages) above the seabed; the grounded end is the end grounded in the initial state. Walking
from that end, the TDP lies between the last grounded node and the next one, where the parabola
through the last grounded node and the next two nodes (clearance against chord arc) crosses that
height; the TDP sits on that height. The parabola's curvature is limited so that it rises
monotonically over the element, so it crosses once: where the line rises sharply beyond the
element, an unlimited parabola would dip below the onset height and put the crossing near the
suspended node. With fewer than two suspended nodes, or no crossing inside the element, the
clearance is interpolated linearly. The crossing reaches a node exactly when the node reaches
the onset height, from either side, so the TDP moves continuously as nodes ground and lift off,
and between nodes it follows the lift-off of the line instead of resting on the last grounded
node until the next one grounds. The definitions are those of :func:`cabledyn.touchdown_history`
with ``tolerance = 1e-6``.

.. list-table::
   :header-rows: 1
   :widths: 24 56 20

   * - Channel
     - Meaning
     - Unit
   * - ``TDP<L>s``
     - arc length of the TDP from End A (deformed chord length along the nodes)
     - m
   * - ``TDP<L>x`` / ``y`` / ``z``
     - TDP position
     - m
   * - ``TDP<L>Lay``
     - layback: horizontal distance from the TDP to the suspended end
     - m
   * - ``TDP<L>Exc``
     - TDP excursion: horizontal displacement of the TDP from its initial (``t = 0``) position,
       projected on the initial horizontal direction from the TDP to the suspended end (positive
       toward the suspended end)
     - m
   * - ``TDP<L>Grd``
     - grounded length: deformed chord length along the nodes from the grounded end to the TDP
       (``TDP<L>s`` measured from the grounded end instead of End A). It varies continuously with
       the TDP: it grows from 0 as the TDP leaves the grounded end node, so a line whose
       neighbour of the anchor is just above the seabed reads a fraction of the first element, and
       it is 0 only when nothing touches (the grounded end node itself is off the seabed, or the
       TDP sits at that node). The whole line length when every node is grounded
     - m

The channels are available on every route, OpenFAST included, when the deck has a seabed
(``WtrDpth`` or ``bathymetryFile``). A line whose initial state is grounded at both ends or at
neither stops the run with exit code 1 naming the line. When the grounded end later lifts off,
the channels report that end node (and ``TDP<L>Grd`` reads 0); when the whole line rests on the
seabed, the suspended end node. ``TDP<L>Grd`` is the grounded length of the `Anchor uplift`_
check.

The seabed carries the line at its nodes, so the mesh at touchdown sets how finely the touchdown
point and the tension around it are resolved: a node lands on the floor at once, and in a
dynamic run its landing shakes the line. The node tension near touchdown converges at the second
order in the element length there. On the lazy-wave cable of
``lozon_gomex80_power_cable_motion.dat`` (bending length :math:`\sqrt{EI/T}` = 3.9 m at
touchdown, tension 1.3 to 1.9 kN) it departs from a 1024-element solution by at most 140, 55,
19 and 5.8 N with 3.3, 1.6, 0.8 and 0.4 m elements at touchdown over the heave cycle (time step
0.0125 s), and by 4.6, 1.0 and 0.25 N in the static state with 3.3, 1.6 and 0.8 m elements; on
the 3.3 m mesh ``TDP<L>s`` moves at up to 4 m/s while a node lands (0.7 m/s converged) and its
lowest value differs from the converged one by 0.6 m. Elements no longer than about a fifth of
:math:`\sqrt{EI/T}` at touchdown keep the node tension there within about 1.5 % of the
converged value through the motion, and a tenth within 0.5 %.

Point channels
~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 24 56 20

   * - Channel
     - Meaning
     - Unit
   * - ``Point<P>px`` / ``py`` / ``pz``
     - position component of point ``P`` (for a prescribed point on a ``motionFile`` run, the
       prescribed position at that time)
     - m
   * - ``Con<P>px`` / ``py`` / ``pz``
     - MoorDyn v1 spelling, identical to ``Point<P>p…``
     - m
   * - ``Point<P>Fx`` / ``Fy`` / ``Fz`` / ``FH``
     - resultant of the forces of the lines and finite-EI cables attached to point ``P`` (each
       the ``FairTen``/``AnchTen`` end force): the load on a shared anchor, or the line load a
       free point balances; ``FH`` is the horizontal magnitude. Available on every route
       (static, ``EI = 0``, finite-EI, multibody and OpenFAST)
     - N

Body and rod channels
~~~~~~~~~~~~~~~~~~~~~

The MoorDyn-F names, for Rigid6 bodies and for rods (free, fixed, pinned, prescribed, fixed or
pinned to a body, and in OpenFAST pinned to the platform), on every route that carries them, the
OpenFAST ``CompMooring = 5`` route included. Loads are evaluated at the committed state of the
output time.

.. list-table::
   :header-rows: 1
   :widths: 30 52 18

   * - Channel
     - Meaning
     - Unit
   * - ``Body<N>Px`` / ``Py`` / ``Pz``
     - reference-point position
     - m
   * - ``Body<N>Rx`` / ``Ry`` / ``Rz``
     - attitude, x-y'-z'' Euler angles of the deck convention
     - deg
   * - ``Body<N>Vx`` … ``Vz``, ``RVx`` … ``RVz``
     - reference-point velocity; angular velocity
     - m/s, deg/s
   * - ``Body<N>Ax`` … ``Az``, ``RAx`` … ``RAz``
     - reference-point acceleration; angular acceleration
     - m/s², deg/s²
   * - ``Body<N>Fx`` / ``Fy`` / ``Fz``, ``Mx`` / ``My`` / ``Mz``
     - net external force and moment on the body about its reference point (global axes):
       weight, buoyancy and hydrostatic restoring, Morison and external loads, seabed contact,
       the loads of its fixed rods, the attached line and cable end forces, and the pin forces
       of the rods pinned to it. Zero for a free body at rest in equilibrium
     - N, N·m
   * - ``Rod<N>Px`` / ``Py`` / ``Pz``, ``Vx`` … ``Vz``, ``Ax`` … ``Az``
     - End A position, velocity and acceleration
     - m, m/s, m/s²
   * - ``Rod<N>Rx`` / ``Ry``
     - MoorDyn's roll and pitch of the rod axis: its tilt φ from the vertical times
       ``-sin β`` and ``cos β``, β the heading of the axis
     - deg
   * - ``Rod<N>RVx`` … ``RVz``, ``RAx`` … ``RAz``
     - angular velocity and acceleration
     - deg/s, deg/s²
   * - ``Rod<N>Fx`` / ``Fy`` / ``Fz``, ``Mx`` / ``My`` / ``Mz``
     - net external force on the rod and its moment about End A: weight, buoyancy, Morison and
       seabed loads, the line and cable end forces and the connection moment (bending and
       torque) of a cable clamped at its ends, on a rod fixed to a body too (not the pin
       reaction of a pinned rod, whose ``M`` therefore vanishes at a static equilibrium)
     - N, N·m
   * - ``Rod<N>TenA`` / ``TenB``
     - magnitude of the summed line and cable end force at End A / End B
     - N
   * - ``Rod<N>Sub``
     - submerged fraction of the rod length, below the local waterline (still water: z = 0)
     - –
   * - ``Rod<N>N<k>Px`` / ``Py`` / ``Pz``
     - position of rod node ``k`` (0 = End A, ``NumSegs`` = End B)
     - m

A zero-length rod (``NumSegs`` 0) is modelled as a point; its ``Rod<N>`` channels are rejected
by name, and its motion is reported by the ``Point<P>`` channels of that point.

The axial tangent of every orientation channel points from End A toward End B (OrcaFlex's node
``Ez`` axis). Curvature, declination and azimuth are evaluated from the solved geometry on
every route (static, ``EI = 0`` dynamic, finite-EI dynamic, rod and Rigid6 decks).

.. _outputs-node-tangent:

The tangent of a node is the line's own direction there. On a finite-EI line it is the node's
tangent degree of freedom :math:`\mathbf r_{,s}` of the cubic-Hermite centreline, normalised: at
an end clamped by an ``END CONNECTIONS`` ``Rigid`` row it is the direction the connection holds,
at an end on a rotational spring the direction the spring lets the line take, and at every other
node the tangent of the solution, continuous through the node. On an ``EI = 0`` line, whose segments are straight, it is the direction from
the previous to the next node (from the end node to its neighbour at an end). The
``L<L>N<J>Dec``/``Azi`` channels, ``FairDecl``/``AnchDecl``, ``FairIncl``/``AnchIncl`` and
their aliases, the ``Declination``, ``Inclination`` and ``Azimuth`` columns of ``.static.out``,
the ``Declination`` envelope of the range graph and the ``line tangent`` of the initialisation
reports all take it, on every route (the standalone driver, the mixed and multibody routes, the
C API and Python, and OpenFAST). :func:`cabledyn.line_geometry` is a post-processing estimate from
the node positions alone.

Validation of channel names
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Every name is checked while the deck is parsed, before any solve, and a bad name stops the run
with exit code 1. A name is rejected when:

* it matches none of the forms above, or carries trailing text (``Point2px_raw``,
  ``Point2pzz``, ``FairTen1x``);
* it references an unknown line or point id, or a node number larger than the line's node
  count, or is a ``TDP<L>`` name with a suffix other than ``s``, ``x``, ``y``, ``z``, ``Lay``,
  ``Exc`` or ``Grd``;
* it is a ``Torq<L>N<J>``, ``Twist<L>N<J>`` or ``Twist<L>`` channel of a line that is not
  solved in torsion (``... carries no torque``, or ``... restrained at one end only and its
  torsion is not solved: <reason>``);
* on a mixed ``EI = 0`` + finite-EI deck (and in OpenFAST), it is a ``Point<P>`` channel of a
  ``Coupled``/``Vessel`` point attached **only** to finite-EI lines — that point is not part of
  the ``EI = 0`` point system that serves point channels. Use the cable's
  ``L<L>N<J>p{x,y,z}`` channel instead. ``Fixed`` points remain valid because they never move;
* in an OpenFAST ``CompMooring = 5`` run, it is longer than OpenFAST's 20-character channel
  header (``ChanLen``). The coupled initialisation stops with an error naming the channel
  rather than writing a truncated, possibly duplicate header.

Console output
--------------

The standalone driver writes a short initialisation report after the static solve. On the
``EI = 0``, finite-EI and static routes it goes to **stderr** (after the identity banner)::

     Parsing CableDyn input file: examples/chain_catenary_r3_100m.dat
      Created CableDyn model: 1 line object(s), 2 point(s), 1 section(s) [EI=0: 1, finite-EI: 0].
      Initial conditions: Newton static equilibrium with load continuation completed.
      Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.
      Line 1 fairlead effective tension:  5.09880E+005 N
         force [Fx, Fy, Fz]: [ 1.91549E+005,  0.00000E+000, -4.72532E+005] N, inclination=   67.934 deg
         line tangent: inclination=   67.242 deg, declination=  157.242 deg, azimuth=    0.000 deg
     CableDyn initialization completed.

``force`` is the force on the End-A node directed toward End B, with its inclination below the
horizontal. ``line tangent`` gives the direction of the line itself at End A. The two angles
differ slightly: the end force also carries the end node's share of the distributed load (weight,
drag, seabed reaction) and, on a finite-EI line, the end shear. On a finite-EI deck whose End B
is not ``Fixed`` the line is labelled ``axial force component`` instead: that route reports the
axial part of the end resultant only.
On a mixed ``EI = 0`` + finite-EI deck the report is shorter and goes to **stdout**::

     CableDyn mixed standalone aggregate: <n> line(s) [<n0> EI=0, <n1> finite-EI].
     Parsed <np> point(s) and <ns> section row(s).
     Static equilibrium fairlead results:
       Line <L>: FairTen=<T> N, tangent inclination=<deg> deg, force=(<Fx> <Fy> <Fz> ) N

Dynamic runs then print progress to **stdout** at 5 % intervals of the march, with the ETA
estimated from the average wall time per committed step::

     Dynamic simulation: 2000 step(s), simulated duration      200.000 s, dtM =  1.00000E-01 s.
     Progress:    5.0% | t =       10.000 s | elapsed 000:00:02 | ETA 000:00:38

Two further stdout records may follow a completed march: ``Recovery audit: …`` when the
integrator subdivided nominal steps (with the number of subdivided intervals and the maximum
sub-step count used), and, on cubic-Hermite decks with the tensile monitor in warning mode,
``Tensile monitor: line <L> …`` summarising compression events (``tensile_safety warn`` in
``OPTIONS``, see :doc:`options`). The final stdout line of a
successful run is described in :doc:`cli`.

In OpenFAST
-----------

Under ``CompMooring = 5`` the selected channels flow through OpenFAST's normal output system
(``WriteOutput``), and CableDyn additionally writes its own files, named from the OpenFAST
output root:

.. list-table::
   :header-rows: 1
   :widths: 36 64

   * - File
     - Contents
   * - ``<RootName>.CD.static.out``
     - the static range table of the converged initialisation (same columns as
       ``.static.out`` above; title ``CableDyn coupled static configuration …``), at the
       equilibrium the console summary reports, before any SeaState kinematics act. Always
       written, whatever the ``OUTPUTS`` selection.
   * - ``<RootName>.CD.out``
     - time history of the deck ``OUTPUTS`` channels, written only when at least one channel is
       selected
   * - ``<FarmRoot>.FarmCD.static.out`` / ``<FarmRoot>.FarmCD.out``
     - the same two files for a FAST.Farm run, named from the FAST.Farm output root
   * - ``<RootName>.CD.rst.dat``
     - temporary copy of the CableDyn deck, written in the ``MooringFile`` folder when a run
       restarts from a checkpoint; the module rebuilds its model from it and removes it after use
       (see :doc:`openfast`)

``<RootName>.CD.out`` layout — note that it differs from the standalone ``.out``:

* **no title line**;
* header row ``Time`` followed by the channel tokens;
* a **units row**: ``(s)`` followed by each channel's unit — ``(N)`` tensions and forces,
  ``(deg)`` angles, ``(m)`` positions, ``(m/s)`` velocities, ``(m/s2)`` accelerations,
  ``(deg/s)`` / ``(deg/s2)`` body and rod angular rates, ``(1/m)`` curvature, ``(N.m)`` bend
  moment and body/rod moments, ``(-)`` ``Rod<N>Sub``;
* data rows: time as ``ES25.16E3`` (full double precision), values as ``ES15.6E3`` (7 significant
  digits, three-digit exponent), TAB-separated.

The first data row is the static initialisation at ``t = 0``; every further row is written after
each committed CableDyn step, at every ``dtM`` boundary. It is independent of OpenFAST's ``DT_Out``
and never repeats held values between
CableDyn steps. If OpenFAST retries a step, at any ``dtM``, the provisional row is replaced rather
than duplicated, and a restore of an operating point (``CalcSteady``) keeps the rows of the run;
the file is flushed after every row, so it is readable during a run and intact after a crash.

Select CableDyn channels in the ``OUTPUTS`` section of the CableDyn ``MooringFile``; they are not
members of the top-level ``.fst`` ``OutList``. The ``TDP<L>`` channels are evaluated from the
coupled state against the touchdown reference of the converged initialisation. The ``LINES`` flag
``r`` adds ``<RootName>.CD.Line<L>.range.out`` (see above) to a single-turbine run; a FAST.Farm
shared-mooring deck with that flag is rejected. For
a single-turbine run the module also prints
every selected channel's static value to the screen after initialisation. A deck with no
``OUTPUTS`` section is valid but publishes no channels.

Reading and post-processing
---------------------------

:func:`cabledyn.read_output` reads every file on this page strictly and attaches the units
defined above, returning time-history or static-profile objects that plot ``FairTen1`` against
time, ``Curvature`` or ``Tension`` against ``ArcLength``, or the static centreline.
:func:`cabledyn.read_range_graphs` returns the envelopes of a ``.range.out`` file as
:class:`cabledyn.RangeGraph` objects. Dynamic
``Line<L>.p.out`` and ``Line<L>.t.out`` files additionally expose interpolated snapshots and
per-segment envelopes. See :doc:`python` and :doc:`api_python`.

For time-history channels, :meth:`cabledyn.TimeHistory.fatigue` provides weighted rainflow
cycles and an uncorrected damage-equivalent **range** (the Wöhler exponent and reference cycle
count or frequency are mandatory inputs); :meth:`cabledyn.TimeHistory.spectrum` a one-sided
Welch power spectral density with spectral moments; and :meth:`cabledyn.TimeHistory.coherence`
the magnitude-squared coherence of two channels. These are derived Python results; they never
modify the native files.

Some pyDatView versions do not recognise the multi-line ``.static.out`` table directly. Export
one line to a normalised table with units embedded in the header:

.. code-block:: powershell

   cabledyn-post export case.static.out line4_static.csv --line 4

The conversion preserves values and row order, does not add a time column, and refuses to
overwrite an existing file unless ``--overwrite`` is given.
