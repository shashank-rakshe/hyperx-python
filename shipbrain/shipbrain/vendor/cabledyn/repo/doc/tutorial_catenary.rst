.. SPDX-License-Identifier: Apache-2.0

Tutorial 1 — A grounded catenary chain
======================================

**Goal:** solve the static equilibrium of one chain mooring line with a long grounded portion,
read both result files, and check the answer against the analytical catenary.

**Deck:** ``examples/chain_catenary_r3_100m.dat`` · **Route:** ``EI = 0`` cable path, static
only · **Run time:** < 1 s

The deck
--------

A CableDyn deck is plain text: a title, then sections introduced by a dashed header. The
``(-)``, ``(m)`` rows are optional unit labels. Lines starting with ``--`` are comments.

.. code-block:: text

   --------------------- LINE TYPES ---------------------------------------
   TypeName   Diam     MassDenInAir   EA         BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
   (-)        (m)      (kg/m)         (N)        (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
   chainR3    0.2466   373.5          1.607e9    -1.0       0.0      1.37  0.64  1.0   0.0
   --------------------- POINTS -------------------------------------------
   ID    Type      X        Y      Z         Mass    Vol     CdA    Ca
   (-)   (-)       (m)      (m)    (m)       (kg)    (m^3)   (m^2)  (-)
   1     Fixed     500.0    0.0    -100.0    0       0       0      0
   2     Coupled   0.0      0.0    0.0       0       0       0      0
   --------------------- LINES --------------------------------------------
   ID    NodeA   NodeB   Outputs
   (-)   (-)     (-)     (-)
   1     2       1       -
   --------------------- SECTIONS -----------------------------------------
   LineID   LineType   Length   NumSegs
   (-)      (-)        (m)      (-)
   1        chainR3    550.0    55
   --------------------- OPTIONS ------------------------------------------
   9.80665      g         - Gravitational acceleration (m/s^2) [default: 9.80665]
   1025.0       rhoW      - Water density (kg/m^3) [default: 1025]
   100.0        WtrDpth   - Water depth (m) [default: absent standalone; host-owned OpenFAST]
   1.0e5        kBot      - Seabed penalty stiffness base (Pa/m) [default: 1.0e5]
   1.0e4        cBot      - Seabed normal damping base (Pa-s/m) [default: 1.0e4]
   ...          (the remaining rows restate defaults)
   --------------------- OUTPUTS ------------------------------------------
   "FairTen1"
   "AnchTen1"
   "FairIncl1"
   "AnchIncl1"

Read it section by section:

``LINE TYPES``
   One material, ``chainR3``: a 137 mm R3 studless chain represented by its volume-equivalent
   diameter 0.2466 m (used for buoyancy, drag, and added mass), 373.5 kg/m dry mass, and axial
   stiffness ``EA = 1.607e9 N``. ``EI = 0`` selects the cable path: no bending stiffness, the
   right model for chain. ``BA/-zeta = -1.0`` sets axial damping as a damping ratio (only used
   in dynamics). The drag and added-mass coefficients are also dynamic-only.
``POINTS``
   The line ends. Point 1 is a ``Fixed`` anchor on the seabed 500 m away; point 2 is a
   ``Coupled`` fairlead at the origin. ``Coupled`` means "driven by the caller": held in place
   here, moved by a motion file (:doc:`tutorial_motion`) or by OpenFAST (:doc:`tutorial_openfast`),
   which is maintained by NLR (National Laboratory of the Rockies, formerly NREL).
``LINES``
   One line object from ``NodeA = 2`` to ``NodeB = 1``. By convention **End A is the fairlead
   (upper) end and End B the anchor**, as in OrcaFlex (Orcina); every "fairlead" output refers to End A.
``SECTIONS``
   The line's make-up from End A to End B: here a single 550 m section of ``chainR3`` meshed with
   55 elements of 10 m. A composite line simply has more rows (Tutorial 2).
``OPTIONS``
   One ``value keyword - description`` row per setting. ``WtrDpth = 100`` puts a flat seabed at
   ``z = -100 m``; ``kBot`` is its contact stiffness. Without ``dtM``/``TMax`` the run stops at
   the static solution. Every keyword is documented in :doc:`options`.
``OUTPUTS``
   One quoted channel per row: fairlead and anchor tension and their inclination below
   horizontal. The vocabulary is in :doc:`outputs`.

The fairlead-to-anchor straight distance is 509.9 m and the chain is 550 m long, so the line is
slack and a long length of it must lie on the seabed.

Run it
------

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null   # already there after the quickstart
   .\CableDyn_driver.exe .\examples\chain_catenary_r3_100m.dat .\results\r3_100m

.. code-block:: text

     Parsing CableDyn input file: .\examples\chain_catenary_r3_100m.dat
      Created CableDyn model: 1 line object(s), 2 point(s), 1 section(s) [EI=0: 1, finite-EI: 0].
      Initial conditions: Newton static equilibrium with load continuation completed.
      Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.
      Line 1 fairlead effective tension:  5.09880E+005 N
         force [Fx, Fy, Fz]: [ 1.91549E+005,  0.00000E+000, -4.72532E+005] N, inclination=   67.934 deg
         line tangent: inclination=   67.242 deg, declination=  157.242 deg, azimuth=    0.000 deg
     CableDyn initialization completed.
   CableDyn_driver: converged run written to .\results\r3_100m.out

(The version banner that precedes these lines is omitted from here on.) The solver started from
an analytical catenary guess and converged the full nonlinear problem — weight, buoyancy, axial
stretch, and unilateral seabed contact — with Newton iterations. Nothing had to be tuned.

Read the result
---------------

``results\r3_100m.out`` has a title line, the channel header, and — for a static run — one row
at ``t = 0``. Columns are tab-separated:

.. code-block:: text

   # CableDyn driver output (static IC; converged=T)
   Time(s)	FairTen1	AnchTen1	FairIncl1	AnchIncl1
     0.0000000000000000E+000	 5.0988032E+005	 1.9241379E+005	 6.7242193E+001	-6.8947041E-001

``results\r3_100m.static.out`` is the along-arc profile (OrcaFlex's range graph), one row per
node from End A to End B:

.. code-block:: text

   CableDyn static configuration profile (deformed arc; public node order EndA -> EndB)
   LineID  Node  ArcLength      X              Y     Z               Tension        Curvature      ...  Inclination
   (-)     (-)   (m)            (m)            (m)   (m)             (N)            (1/m)          ...  (deg)
   1       1     0.0000000E+000 0.0000000E+000 0.0   0.0000000E+000  5.0988032E+005 2.6415668E-003 ...  6.7242193E+001
   1       15    1.4002840E+002 8.9968505E+001 0.0  -9.9511773E+001  1.9407748E+005 1.6239256E-002 ...  7.9569251E+000
   1       16    1.5002959E+002 9.9953125E+001 0.0  -1.0008731E+002  1.9170904E+005 5.3673300E-003 ...  1.7610289E+000
   1       56    5.5007727E+002 5.0000000E+002 0.0  -1.0000000E+002  1.9241379E+005 1.1219455E-003 ... -6.8947041E-001

(columns trimmed for width). Touchdown lies between nodes 15 and 16, about 145 m along the line
and 95 m from the fairlead horizontally: the remaining ~400 m of chain rests on the seabed, where
the tension is constant at 191.5 kN. The small negative ``Z`` below ``-100``
is the seabed penetration that balances the chain's weight through ``kBot``.

Check it by hand
----------------

For an inextensible catenary touching down tangentially, the horizontal tension ``H`` is the
grounded-chain tension and the fairlead tension is ``H + w h``, where ``w`` is the submerged
weight per metre and ``h`` the fairlead height above the seabed:

* ``w = (373.5 − 1025·π/4·0.2466²)·9.80665 = 3183 N/m``;
* ``H = 191.5 kN`` (the grounded-chain tension in the profile), so the catenary parameter is
  ``a = H/w = 60.2 m``;
* suspended length ``√(h² + 2ah) = √(100² + 2·60.2·100) = 148 m`` — CableDyn's touchdown is at
  140–150 m;
* fairlead tension ``H + w h = 191.5 + 318.3 = 509.8 kN``.

``FairTen1`` reports 509.9 kN. End-of-line tension channels report the **line-end force**: the
first element's tension plus the fairlead node's share of the chain weight, so they match the
point value at the fairlead (:doc:`outputs`). ``AnchTen1`` (192.4 kN) is larger than ``H`` for
the same reason: the anchor point sits just above the penetrated seabed and holds the weight of
its half element.

.. admonition:: What you exercised
   :class: tip

   The ``EI = 0`` cable element, the analytical seed and the Newton static solve,
   penalty seabed contact, and both standard output files. Tension is the **effective** tension
   (:doc:`conventions`); inclination is signed below horizontal, so the anchor's ``-0.69°``
   means the chain arrives very slightly upward, lying on the penetrated seabed.

Natural periods and mode shapes
-------------------------------

``chain_modes.dat`` is this deck with ``12 nModes``: a modal analysis about the static
equilibrium, ends held, with the Morison added mass and the linearised seabed contact. The
frequencies and the mode shapes, scaled to a unit largest nodal displacement, go to
``<root>.modes.out``. The first periods are 47.1, 23.8, 16.0, 12.1 and 9.7 s. Modes 1–7 are out of
plane: the grounded chain on a frictionless seabed is held sideways only by its tension. The first
in-plane mode is mode 8, at 6.54 s (0.153 Hz). The run takes well under a second.

Exercises
---------

1. **Mesh convergence.** Copy the deck, change ``NumSegs`` from 55 to 110, and rerun. ``FairTen1``
   becomes 510.6 kN and ``AnchTen1`` 192.4 kN: the end channels barely move, because they already
   report the line-end force. Report tension channels with the mesh you used.
2. **Grounded length in Python.** With the Python package installed (:doc:`installation`), count
   the grounded nodes:

   .. code-block:: python

      from cabledyn import read_output
      z = read_output(r"results\r3_100m.static.out").column("Z")
      print((z <= -99.9).sum(), "of", z.size)     # 41 of 56

3. **Anchor radius.** Move the anchor to ``X = 520`` and rerun. Predict first: the grounded length
   shrinks and both tensions rise (``FairTen1`` = 998.4 kN). At ``X = 540`` the 550 m chain is
   almost straight and must stretch: ``FairTen1`` jumps to 5.34 MN and ``AnchIncl1`` turns
   positive (+0.91°), i.e. the line now lifts the anchor — something a drag anchor cannot resist.
   This stiffening is why offset limits govern catenary mooring design.
4. **Shallow water.** Run ``examples/chain_catenary_shallow_30m.dat`` (the quickstart deck) and
   repeat the hand check with ``h = 30 m``.

Next: :doc:`tutorial_spread`.
