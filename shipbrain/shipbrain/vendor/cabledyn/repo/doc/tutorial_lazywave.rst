.. SPDX-License-Identifier: Apache-2.0

Tutorial 3 — A lazy-wave power cable
====================================

**Goal:** find the installed equilibrium of a dynamic power cable with a buoyancy section,
locate its sag bend, hog bend, and touchdown, and read curvature and minimum bend radius.

**Deck:** ``examples/lozon_gomex80_power_cable.dat`` (Lozon et al. 2025, Gulf of Mexico, 80 m
water depth) · **Route:** cubic-Hermite finite-EI path, static · **Run time:** < 1 s

Why a different element
-----------------------

A power cable has bending stiffness that matters: the fatigue- and bend-radius-critical
quantities are the curvatures at the sag bend, the hog (arch) bend, and touchdown. Giving a line
type ``EI > 0`` switches its line to CableDyn's cubic-Hermite element, which carries position
and tangent at every node and evaluates the exact nonlinear centreline curvature. Chains with
``EI = 0`` in the same deck keep the cable element. See :doc:`solver_paths`.

The deck
--------

.. code-block:: text

   --------------------- LINE TYPES ---------------------------------------------
   TypeName  Diam   MassDenInAir  EA       BA   EI       Cd_n  Cd_t  Ca_n  Ca_t
   bare      0.160  36.70         4.69e8   0.0  1.99e4   1.2   0.1   1.0   0.0
   buoy      0.290  59.53         4.69e8   0.0  1.99e4   1.2   0.1   1.0   0.0
   --------------------- POINTS ------------------------------------------------
   ID  Type     X       Y    Z
   1   Coupled  5.0     0.0  -14.0
   2   Fixed    125.0   0.0  -80.0
   --------------------- LINES -------------------------------------------------
   ID  NodeA  NodeB  Outputs
   1   1      2      -
   --------------------- SECTIONS ----------------------------------------------
   LineID  LineType  Length   NumSegs
   1       bare      68.114   448
   1       buoy      50.000   320
   1       bare      52.101   256
   --------------------- OPTIONS -----------------------------------------------
   80.0     WtrDpth   ...
   0.0      TMax      - ... 0 selects static initialization only
   True     tensile_safety  - Refine and reject local axial compression in this tensile cable
   ...
   --------------------- OUTPUTS -----------------------------------------------
   "FairTen1"  "AnchTen1"  "FairIncl1"  "AnchIncl1"  "Curv1N383"  "BendMom1N383"

(one channel per row in the file). Points to notice:

* Two line types share ``EA`` and ``EI`` but differ in outer diameter and mass. ``bare`` is
  heavy in water (36.7 kg/m vs 20.6 kg/m displaced); the ``buoy`` section, representing the
  distributed buoyancy modules as an equivalent cylinder, displaces 67.7 kg/m against 59.5 kg/m
  of mass and is therefore **net buoyant**. That is what lifts the arch.
* One line, three ordered sections, End A at the hang-off (``Coupled``, 14 m below the surface)
  and End B at a ``Fixed`` seabed termination 120 m away. The cable is longer than the span, so
  its tail rests on the seabed.
* The mesh is fine (1024 elements, ~0.17 m) so that the touchdown and the section transitions
  are resolved. ``Curv1N383`` asks for curvature at node 383, in the sag bend.
* ``TMax = 0`` makes this a static-only run; ``tensile_safety`` refines and rejects a solution
  with local axial compression. There is no initial-shape input: CableDyn finds the shape.

Run it
------

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null   # already there after the quickstart
   .\CableDyn_driver.exe .\examples\lozon_gomex80_power_cable.dat .\results\lazywave80

.. code-block:: text

      Created CableDyn model: 1 line object(s), 2 point(s), 3 section(s) [EI=0: 0, finite-EI: 1].
      Initial conditions: Newton static equilibrium with load continuation completed.
      Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.
      Line 1 fairlead effective tension:  9.32017E+003 N
         force [Fx, Fy, Fz]: [ 1.32690E+003, -0.00000E+000, -9.22523E+003] N, inclination=   81.815 deg
         line tangent: inclination=   81.601 deg, declination=  171.601 deg, azimuth=    0.000 deg
     CableDyn initialization completed.
   CableDyn_driver: converged run written to .\results\lazywave80.out

.. code-block:: text

   # CableDyn driver output (finite-EI dynamic; production cubic-Hermite route)
   Time(s)  FairTen1       AnchTen1       FairIncl1      AnchIncl1       Curv1N383      BendMom1N383
   0.0...   9.3201701E+003 1.3269019E+003 8.1600621E+001 -3.6920305E-001 9.6829202E-002 1.9269011E+003

Read the shape
--------------

Plot ``Z`` against ``X`` and ``Curvature`` against ``ArcLength`` from
``results\lazywave80.static.out`` (Python, pyDatView, or a spreadsheet). The profile gives:

.. list-table::
   :header-rows: 1
   :widths: 26 20 18 36

   * - Feature
     - Arc length
     - Depth ``Z``
     - Curvature
   * - hang-off (End A)
     - 0 m
     - −14.0 m
     - tension 9.32 kN, 81.6° below horizontal
   * - sag bend (lowest point before the arch)
     - 58.5 m
     - −64.1 m
     - 0.0968 1/m — **minimum bend radius 10.3 m**
   * - hog bend (arch crest, buoyancy section)
     - 87.2 m
     - −52.5 m
     - 0.056 1/m
   * - touchdown region
     - ~131–136 m
     - −79 to −80 m
     - 0.076 1/m peak
   * - End B (seabed termination)
     - 170.2 m
     - −80.0 m
     - tension 1.33 kN

170 of the 1025 nodes rest on the seabed. ``Curv1N383`` in ``.out`` is the sag-bend node, and
``BendMom1N383 = EI × κ = 1.99e4 × 0.0968 = 1927 N·m``. The horizontal tension is the same at
both ends (1.33 kN): the only horizontal external loads in statics are the end reactions.

In Python:

.. code-block:: python

   import numpy as np
   from cabledyn import read_output
   p = read_output(r"results\lazywave80.static.out")
   s, z, k = p.column("ArcLength"), p.column("Z"), p.column("Curvature")
   i = int(np.argmax(k))
   print(f"max curvature {k[i]:.4f} 1/m at s = {s[i]:.1f} m -> MBR {1/k[i]:.1f} m")
   print("grounded nodes:", int((z <= -79.99).sum()))

.. code-block:: text

   max curvature 0.0968 1/m at s = 58.1 m -> MBR 10.3 m
   grounded nodes: 170

.. admonition:: Check the equilibrium, not only the end tension
   :class: important

   A lazy-wave cable can have more than one equilibrium. A plausible fairlead tension does not
   prove the right branch: always inspect the curvature profile for a smooth sag bend, arch, and
   touchdown with no kinks at section boundaries, and compare peak curvature with the design
   minimum bend radius. The three Lozon reference cables agree with OrcaFlex and the published
   values in :doc:`validation`.

Discrete buoyancy modules
-------------------------

``lazy_wave_buoyancy_modules.dat`` replaces the smeared 50 m buoyant section with the bare cable
and ten modules at a 5 m pitch, in a 0.5 m/s current. One ``ATTACHMENTS`` series row places them:

.. code-block:: text

   LineID  ArcLength           Mass    Volume  CdA   Ca   CdAx
   1       70.614:5.0:115.614  114.15  0.2297  0.78  1.0  0.2042

Each module carries 5 m worth of the extra mass and volume of the 0.29 m section, with
``CdA = Cd_n (d_m − d) p`` and ``CdAx = π Cd_t (d_m − d) p``, so it matches the smeared section
in the current. ``lazy_wave_buoyancy_smeared.dat`` gives that section as an
``EQUIVALENT BUOYANCY`` row on the same mesh, whose 0.156 m elements put a node on every module.
The global answer is the same: fairlead tension 9165 N against 9160 N, touchdown at 138.26 m
against 138.27 m of arc, arch crest at z = −47.49 m against −47.48 m, and all nodes within
0.035 m. The local bending is not: over the arch the curvature is a sawtooth, 0.084 1/m at a
module against 0.061 1/m smeared, and about 20 % lower between modules. The sag-bend
(0.085 1/m) and touchdown (0.113 1/m) peaks are unchanged. Use modules when the arch bending
matters, and the smeared section for the global response.

Natural periods of the lazy wave
--------------------------------

``lazy_wave_modes.dat`` adds ``10 nModes`` to the 80 m cable on its 1024-element
mesh. The modes are solved about the static equilibrium with both ends held, the added mass and
the linearised seabed contact included, and written to ``<root>.modes.out``. The first periods
are 72.8 s (out of plane), 39.9 s (in plane), 31.0 s (out of plane), 20.4 s (in plane, mostly
vertical), 19.9 s (out of plane, along the grounded run) and 16.9 s (in plane). Between 512 and
2048 elements the out-of-plane periods and the 20.4 s mode agree to four digits. The in-plane
modes that move the touchdown (39.9 s, 16.9 s and 11.7 s) shift by up to 0.5 %, because the
linearised seabed contact at the touchdown changes with the node spacing. The run takes about
a second, a quarter of it in the modal solve.

Exercises
---------

1. **Deeper sites.** Run ``lozon_gomaine200_power_cable.dat`` (200 m) and
   ``lozon_humboldt800_power_cable.dat`` (800 m). Compare hang-off tension and minimum bend
   radius; the deep cable is dominated by suspended weight.
2. **Buoyancy sizing.** Copy the 80 m deck and increase the ``buoy`` mass from 59.53 to
   64.00 kg/m (less net buoyancy). Predict first, then check: the arch crest drops from −52.5 m
   to −64.4 m, the tail lengthens (213 grounded nodes), and the peak curvature rises to
   0.110 1/m — the minimum bend radius falls from 10.3 m to 9.1 m.
3. **Mesh.** Halve every ``NumSegs`` (224/160/128) and rerun. The peak curvature stays at
   0.0968 1/m and the hang-off tension changes by less than 0.001 N, so the shipped mesh is converged for
   these quantities. Do this check on every new cable before trusting a bend-radius result.

Next: :doc:`tutorial_motion`.
