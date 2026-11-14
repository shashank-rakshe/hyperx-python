.. SPDX-License-Identifier: Apache-2.0

Tutorial 7 — Buoys, bodies, and rods
====================================

**Goal:** moor a free-floating rigid body and a rigid rod, let them find their dynamic
equilibrium under current, and learn the time-step rule for coupled bodies.

**Decks:** ``examples/rigid6_buoy.dat``, ``examples/rod_moored_spar.dat``, and for reference
``examples/clump_weight_free_point.dat``, ``examples/connect_weighted_point.dat`` ·
**Route:** ``EI = 0`` point-system dynamics · **Run time:** a few seconds

Which object to use
-------------------

.. list-table::
   :header-rows: 1
   :widths: 26 30 44

   * - Object
     - Declared in
     - Degrees of freedom and loads
   * - ``Connect`` / ``Free`` point
     - ``POINTS`` (``Mass``, ``Vol``, ``CdA``, ``Ca``)
     - 3 translations; a clump weight, a small float, or a node where several lines meet
   * - ``Point3`` body
     - ``BODIES``
     - 3 translations; a buoy or clump carrying one line
   * - ``Rigid6`` body
     - ``BODIES`` + ``Body<N>`` points
     - 6 DOF; lines attach at body-frame offsets, so line loads create moments; buoyancy,
       hydrostatic stiffness ``C33/C44/C55``, lumped drag ``CdA`` and added mass ``Ca``
   * - rigid rod
     - ``ROD TYPES`` + ``RODS`` + ``Rod<N>A``/``Rod<N>B`` points
     - a rigid cylinder between two ends with distributed buoyancy, drag, and added mass;
       ``Free``, ``Fixed``, or prescribed

All of them need a dynamic deck (``dtM`` and ``TMax``). ``Connect``/``Free`` points, free
bodies, and free rods start from their static force balance (every attached line re-solved for
the moving ends); ``deck bodyIC`` keeps the deck pose instead, for example for a free-decay
test.
Bodies, rods, points and lines may share one deck; mixed topologies run on one multibody march.
The column-by-column grammar is in :doc:`driver_format`.

A moored Rigid6 buoy
--------------------

``rigid6_buoy.dat`` holds a submerged, net-buoyant buoy (20 t, 40 m³ displaced) 20 m below the
surface in 100 m of water with three taut polyester legs:

.. code-block:: text

   --------------------- BODIES -------------------------------------------
   ID  Type    X    Y    Z      Roll  Pitch  Yaw   Mass    Vol   C33  C44  C55  CdA   Ca   Ixx     Iyy     Izz
   1   Rigid6  0.0  0.0  -20.0  0.0   0.0    0.0   2.0e4   40.0  0.0  0.0  0.0  8.0   0.5  3.5e4   3.5e4   3.5e4
   --------------------- POINTS -------------------------------------------
   ID    Type      X          Y          Z         Mass    Vol     CdA    Ca
   1     Body1     1.5        0.0        -2.0      0       0       0      0
   2     Body1     -0.75      1.299      -2.0      0       0       0      0
   3     Body1     -0.75      -1.299     -2.0      0       0       0      0
   4     Fixed     40.0       0.0        -100.0    0       0       0      0
   5     Fixed     -20.0      34.641     -100.0    0       0       0      0
   6     Fixed     -20.0      -34.641    -100.0    0       0       0      0

* The ``BODIES`` row places the body reference point at ``(0, 0, -20)`` and gives mass,
  displaced volume, hydrostatic stiffness (zero here: the buoy is fully submerged, so there is
  no waterplane), drag area, added-mass coefficient, and diagonal inertia.
* ``Body1`` points are **attachment offsets in the body frame**: three padeyes 1.5 m off-axis and
  2 m below the reference point. They move rigidly with the body.
* Net buoyancy is ``(1025·40 − 20 000)·g = 206 kN`` upward, carried by three 86.85 m legs
  (``EA = 5e7 N``) to anchors on a 40 m radius. ``uniform 0.6 0.0 0.0 current`` pushes it in
  ``+X``; ``dtM = 0.01``, ``TMax = 60``.

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null   # already there after the quickstart
   .\CableDyn_driver.exe .\examples\rigid6_buoy.dat .\results\buoy

.. code-block:: text

      Initial conditions: body/rod static equilibrium (1 object(s), largest move 4.235E-02 m) completed.
      ...
      Created CableDyn model: 3 line object(s), 6 point(s), 3 section(s) [EI=0: 3, finite-EI: 0].
      Initial conditions: Newton static equilibrium with load continuation completed.
      Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.
      Line 1 fairlead effective tension:  6.98240E+004 N
         force [Fx, Fy, Fz]: [ 3.11000E+004,  1.06826E-016, -6.25154E+004] N, inclination=   63.551 deg
         line tangent: inclination=   63.562 deg, declination=  153.562 deg, azimuth=    0.000 deg
      ...
     CableDyn initialization completed.
     Dynamic simulation: 6000 step(s), simulated duration       60.000 s, dtM =  1.00000E-02 s.
     ...
   CableDyn_driver: converged run written to .\results\buoy.out

The static solve first moves the body to its equilibrium under net buoyancy and current drag
(the largest move is 4.2 cm), so the buoy starts the march at rest and the channels keep their
``t = 0`` values. Mean values over the last 20 s:

.. list-table::
   :header-rows: 1
   :widths: 40 30 30

   * - Channel
     - ``t = 0``
     - mean, 40–60 s
   * - ``FairTen1`` (leg anchored downstream, at +X)
     - 69.82 kN
     - 69.82 kN
   * - ``FairTen2`` = ``FairTen3``
     - 79.44 kN
     - 79.44 kN
   * - ``Point1px`` (padeye 1, x)
     - 1.586 m
     - 1.586 m
   * - ``Point1pz`` / ``Point2pz`` (padeye depths)
     - −21.975 / −22.026 m
     - −21.975 / −22.026 m

The current moves the buoy about 4 cm downstream, toward line 1's anchor, and pitches it about
1.3°, so padeye 1 moves about 9 cm. That leg (line 1,
anchored at ``+X``) unloads while the two upstream legs load up, and the unequal padeye depths
show the body **pitching** slightly under the unbalanced leg moments — a response a 3-DOF point
buoy cannot represent.

.. admonition:: Time step for bodies
   :class: important

   Bodies and rods are advanced monolithically with their lines (``bodyScheme monolithic``,
   the default): one implicit step, with a Newton iteration on the body accelerations around
   the implicit line steps (see :doc:`theory`). The scheme adds no numerical damping, and by
   default a step too coarse for the stiffest body-mooring mode is sub-divided automatically.
   ``dtM`` must still resolve the physics of interest: the wave period and the body-line motion.
   For this buoy the settled position is the same from ``dtM = 0.005`` to 0.1 s. Always halve ``dtM``
   once on a new body model and compare.

A rigid rod on four legs
------------------------

``rod_moored_spar.dat`` stands a 10 m, 1 m-diameter buoyant rod upright between
``z = -30`` and ``-20`` m in 50 m of water:

.. code-block:: text

   --------------------- ROD TYPES ----------------------------------------
   Name     Diam    Mass     Cd     Ca     CdEnd  CaEnd  CdAx   CaAx
   spar     1.0     300.0    0.8    1.0    0.0    0.0    0.2    0.0
   --------------------- RODS ---------------------------------------------
   ID   RodType   Type   XA    YA    ZA      XB    YB    ZB      NumSegs   Outputs
   1    spar      Free   0.0   0.0   -30.0   0.0   0.0   -20.0   1         p
   --------------------- POINTS -------------------------------------------
   1     Rod1A     0.0      0.0    -30.0     0       0       0      0
   2     Rod1B     0.0      0.0    -20.0     0       0       0      0
   3     Fixed     25.0     0.0    -50.0     0       0       0      0
   ...

``ROD TYPES`` columns 6–7 are MoorDyn's end coefficients ``CdEnd``/``CaEnd``; the optional
columns 8–9 add the CableDyn axial side drag and added mass ``CdAx``/``CaAx`` (here an axial
drag of 0.2 and no end effects).
``Rod1A``/``Rod1B`` points attach lines to the rod's End A and End B; their coordinates are
taken from the ``RODS`` row. With ``staggered bodyScheme`` each rod end must carry at least one
line; the default monolithic scheme has no such restriction. Two legs run from
the bottom to anchors 25 m up- and downstream, two from the top to anchors 30 m to either side.
``Outputs = p`` writes the rod's end positions to ``<root>.Rod1.p.out``.

.. code-block:: powershell

   .\CableDyn_driver.exe .\examples\rod_moored_spar.dat .\results\spar

Over 15–30 s the top of the rod (``Point2px``) sits 0.70 m downstream of the bottom (0.002 m):
the 0.5 m/s current tilts the rod about 4° about its bottom bridle. The rod starts at this static
equilibrium (``bodyIC``), so the positions hold steady through the 30 s run.

A cable clamped to the buoy
---------------------------

``buoy_clamped_cable.dat`` hangs a finite-EI cable from the keel of a floating ``Rigid6`` buoy
and clamps it there at 60° below horizontal:

.. code-block:: text

   --------------------- END CONNECTIONS ------------------------------
   LineID  End  Stiffness  EzX   EzY  EzZ
   4       A    Rigid      -0.5  0.0  -0.86603

The direction is given in the body frame and turns with the buoy. The clamp moment,
``BendMom4N1``, acts on the body in the static solve and in the dynamics, and is part of
``Body1M*``. At rest the clamp carries 9.63 kN·m (a pinned cable would leave at 82°) and
``Body1My`` is zero; the moment tilts the buoy to a static pitch of 0.15° instead of 0.30°
pinned. In 1 m, 14 s swell the clamp moment ranges from 8.7 to 11.0 kN·m and the buoy pitches
between −1.35° and +1.07°. With ``Pinned`` the end moment stays below 0.1 N·m. The first 10 m of
cable use 0.25 m elements to resolve the bending near the clamp; ``BendMom4N1`` is the moment the
end element carries in equilibrium, so halving them changes it by under 0.01 % (0.5 % for twice
the elements' length). A finite ``Stiffness`` in N·m/rad models a compliant hang-off.

A spar with pinned rods
-----------------------

``spar_pinned_rods.dat`` builds a spar from a free ``Rigid6`` body (1300 t of ballast with its
centre of gravity 50 m below the reference point, ``Volume`` 0) and a ``Body1`` hull rod, 6 m in
diameter, from 60 m draft to 10 m freeboard, which provides the buoyancy and the waterplane
restoring. Two ``Body1Pinned`` outrigger rods are pinned at the keel: each has its own three
rotations, loads the spar only through its pin force, and carries a polyester tether from its tip
(``R2B``, ``R3B``). Three chain catenaries hold the spar.

The static solve balances everything in the 0.4 m/s current: the spar rises 1.35 m and drifts
1.78 m, and the outriggers settle 148.5° from the upward vertical with 410 kN tethers. In the
4 m, 8 s Airy wave the spar pitches ±3.4°, its mean surge grows to 4.3 m, and the tether tension
cycles between 360 and 502 kN. Halving ``dtM`` to 0.01 s changes these values only in the fourth
digit. A run takes about 2 s.

The multibody march
-------------------

``mixed_body_rods_points.dat`` puts every object type on one march: a free ``Rigid6`` buoy on
three taut nylon legs, a ``Body1`` can, a ``Body1Pinned`` arm with a tether, a chain through two
``Free`` points (a 100 kg float and a 400 kg clump), and a finite-EI cable whose pinned End A
loads the buoy. ``deck bodyIC`` starts the buoy 3 m off its equilibrium, so the run is a free
decay: the surge swings to −2.20 m at 10 s and back to +1.61 m at 21 s (a period of about 21 s),
the arm leans up to 3.9°, the leg tension moves between 70 and 149 kN, and the cable top tension
stays within 7.8–8.1 kN. Halving ``dtM`` to 0.0025 s reproduces the surge and the tensions to
about five significant figures. A run takes about 3 s.

A broken mooring line
---------------------

A ``FAILURE`` row detaches line ends from a point during the run, at a set time or when the end
tension first reaches a threshold. ``als_volturnus_line_break_time.dat`` models the IEA-15MW
VolturnUS-S as one free ``Rigid6`` body on its three chains in a JONSWAP sea with a steady
thrust, and breaks line 1 at its fairlead at t = 300 s:

.. code-block:: text

   --------------------- FAILURE ------------------------------------------
   FailID  Point  Line(s)  FailTime  FailTen
   (-)     (-)    (-)      (s)       (N)
   1       P1     1        300.0     0

The detached end falls freely and the platform settles on lines 2 and 3, 62 m from its origin
against 23 m before the break; the windward line peaks at 12.73 MN (12.53 MN before the break).
A deck with ``FAILURE`` runs its bodies on the staggered scheme. The examples ``README.md``
tabulates the transient and its ``dtM`` convergence.

Exercises
---------

1. **Stronger current.** Set the buoy's current to 1.5 m/s. How much further does line 1
   unload? Check
   ``FairTen1`` for zero values: dynamic lines are tension-only.
2. **Point buoy.** Replace the Rigid6 body by a ``Point3`` body with one leg and compare the
   motion. What is lost?
3. **Waves on a body.** Add ``airy 2.0 10.0 0.0 waves`` to the buoy deck. Bodies receive lumped
   translational wave loads through ``CdA``/``Ca``; lines receive distributed loads.
4. **Clump weights and connections.** Run ``clump_weight_free_point.dat`` and
   ``connect_weighted_point.dat`` to see ``Free`` and ``Connect`` points with mass and volume.

Next: :doc:`tutorial_python`.
