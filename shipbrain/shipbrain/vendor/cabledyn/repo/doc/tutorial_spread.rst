.. SPDX-License-Identifier: Apache-2.0

Tutorial 2 — A spread mooring and its output channels
=====================================================

**Goal:** model the three-line chain mooring of the IEA-15MW VolturnUS-S semi-submersible,
request node-level channels and per-line files, and compute the system's restoring force for a
platform offset.

**Deck:** ``examples/spread_3line_chain.dat`` · **Route:** ``EI = 0`` cable path, static ·
**Run time:** < 1 s

The deck
--------

The line type and options are those of Tutorial 1 scaled to the reference platform: an R4
studless chain (volume-equivalent diameter 0.333 m, 685 kg/m, ``EA = 3.27e9 N``), 850 m per line,
200 m water depth, and a stiffer seabed (``kBot = 3.0e6``). What is new is the topology:

.. code-block:: text

   --------------------- POINTS -------------------------------------------
   ID    Type      X         Y         Z         Mass    Vol     CdA    Ca
   1     Fixed     837.6     0.0       -200.0    0       0       0      0
   2     Coupled   58.0      0.0       -14.0     0       0       0      0
   3     Fixed    -418.8     725.383   -200.0    0       0       0      0
   4     Coupled  -29.0      50.229    -14.0     0       0       0      0
   5     Fixed    -418.8    -725.383   -200.0    0       0       0      0
   6     Coupled  -29.0     -50.229    -14.0     0       0       0      0
   --------------------- LINES --------------------------------------------
   ID    NodeA   NodeB   Outputs
   1     2       1       -
   2     4       3       -
   3     6       5       -
   --------------------- SECTIONS -----------------------------------------
   LineID   LineType   Length   NumSegs
   1        chain      850.0    50
   2        chain      850.0    50
   3        chain      850.0    50

Three fairleads sit on a 58 m radius, 14 m below the still-water line, at azimuths 0°, 120°, and
240°; three anchors lie on the seabed at 837.6 m radius. Each line runs from its fairlead
(End A) to its anchor (End B). Every ``SECTIONS`` row names the line it belongs to by
``LineID``; a composite line (chain–polyester–chain, say) is **one** ``LINES`` row with several
ordered ``SECTIONS`` rows — see ``examples/composite_chain_poly_chain.dat``.

Add channels and per-line files
-------------------------------

Copy the deck to ``my_spread.dat``. In ``LINES``, change line 1's ``Outputs`` flag from ``-``
to ``pt``; at the end of ``OUTPUTS``, add three channels:

.. code-block:: text

   1     2       1       pt
   ...
   "FairDecl1"
   "Ten1N26"
   "L1N26pz"

``p`` writes node positions and ``t`` segment tensions for line 1 to separate files.
``FairDecl1`` is the declination (angle from vertical-up), ``Ten1N26`` the
tension at node 26 of line 1 (nodes are numbered 1…51 from End A), and ``L1N26pz`` that node's
``z`` coordinate. The full vocabulary is in :doc:`outputs`.

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null   # already there after the quickstart
   Copy-Item .\examples\spread_3line_chain.dat .\my_spread.dat
   # edit my_spread.dat as above, then:
   .\CableDyn_driver.exe .\my_spread.dat .\results\spread

.. code-block:: text

      Created CableDyn model: 3 line object(s), 6 point(s), 3 section(s) [EI=0: 3, finite-EI: 0].
      Initial conditions: Newton static equilibrium with load continuation completed.
      Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.
      Line 1 fairlead effective tension:  2.43712E+006 N
         force [Fx, Fy, Fz]: [ 1.35070E+006,  0.00000E+000, -2.02858E+006] N, inclination=   56.343 deg
         line tangent: inclination=   55.685 deg, declination=  145.685 deg, azimuth=    0.000 deg
      Line 2 fairlead effective tension:  2.43715E+006 N
         force [Fx, Fy, Fz]: [-6.75364E+005,  1.16977E+006, -2.02860E+006] N, inclination=   56.343 deg
         line tangent: inclination=   55.684 deg, declination=  145.684 deg, azimuth=  120.000 deg
      Line 3 fairlead effective tension:  2.43715E+006 N
         force [Fx, Fy, Fz]: [-6.75364E+005, -1.16977E+006, -2.02860E+006] N, inclination=   56.343 deg
         line tangent: inclination=   55.684 deg, declination=  145.684 deg, azimuth=  240.000 deg
     CableDyn initialization completed.
   CableDyn_driver: converged run written to .\results\spread.out

The run writes four files:

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - File
     - Contents
   * - ``spread.out``
     - the 15 requested channels at ``t = 0``
   * - ``spread.static.out``
     - the nodal profile of **all three** lines (``LineID`` column)
   * - ``spread.Line1.p.out``
     - line 1 node positions ``Node X(m) Y(m) Z(m)``, End A → End B
   * - ``spread.Line1.t.out``
     - line 1 segment tensions ``Segment Tension(N)``, End A → End B

The last three channels of ``spread.out`` are:

.. code-block:: text

   FairDecl1        Ten1N26          L1N26pz
   1.4568478E+002   1.3507024E+006  -2.0000585E+002

Node 26 (mid-line) sits on the seabed (``z = -200.006 m``) and carries exactly the horizontal
tension 1.351 MN, which equals the fairlead's ``Fx`` above: on a frictionless seabed the grounded
chain transmits the horizontal load unchanged to the anchor.

Interpret the fairlead report
-----------------------------

The console block is printed for every line, whether or not you request channels. Its force is
the load the line applies to its End A, directed along the line toward End B. The three lines
are identical, so the vertical loads add (3 × 2.029 MN = 6.09 MN, the mooring's contribution to
the platform's vertical equilibrium) while the horizontal loads cancel. Declination is measured
from vertical-up (145.7° = 55.7° below horizontal); azimuth from ``+X`` toward ``+Y``. These
conventions are defined once in :doc:`conventions`.

Exercises
---------

1. **Restoring force.** Surge the platform 10 m: add 10 to the ``X`` of points 2, 4, and 6 and
   rerun. The console forces become ``Fx = +0.968 MN`` (line 1, now slacker) and ``-0.820 MN``
   (lines 2 and 3). Their sum, ``-0.671 MN``, is the mooring restoring force on the platform —
   an average stiffness of about 67 kN/m over the first 10 m. Repeat at 20 m to see the
   stiffening.
2. **Four lines.** Run ``examples/spread_4line_chain.dat`` and check that the four fairlead
   azimuths and tensions are symmetric.
3. **Composite line.** Run ``examples/composite_chain_poly_chain.dat`` and plot ``Tension``
   against ``ArcLength`` from its ``.static.out``: the slope changes where the submerged weight per
   metre changes at the section boundaries.

Next: :doc:`tutorial_lazywave`.
