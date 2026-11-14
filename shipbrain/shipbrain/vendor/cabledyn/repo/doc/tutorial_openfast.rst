.. SPDX-License-Identifier: Apache-2.0

Tutorial 9 — A floating wind turbine in OpenFAST
================================================

**Goal:** run the IEA-15MW reference turbine on the UMaine VolturnUS-S semi-submersible in the
release ``openfast.exe`` (OpenFAST, maintained by NLR, the National Laboratory of the Rockies,
formerly NREL) with CableDyn as its mooring module (``CompMooring = 5``), read the
CableDyn results, compare against stock MoorDyn in the same binary, and add a lazy-wave power
cable.

**Needs:** ``openfast.exe`` from the release, the ``examples`` folder, and Git (or a browser) to
fetch the turbine model · **Run time:** under half a minute for 70 s of simulation, about a
third of it SeaState generating the wave grid (the MoorDyn comparison run takes a few minutes)

.. contents::
   :local:
   :depth: 1

1. Fetch the turbine model
--------------------------

The CableDyn repository ships the mooring decks and ``.fst`` templates in
``examples/openfast/``, but not the turbine sub-models (ElastoDyn, SeaState, HydroDyn with its
WAMIT database, AeroDyn, InflowWind), which are maintained by the OpenFAST project. The templates
are wired to the IEA-15MW turbine-1 files of OpenFAST's regression-test case
``glue-codes/fast-farm/MD_Shared``. Use the revision the release was tested against,
``dd5feaaaa500ba7283140107806300d551cff0a7``.

With Git (downloads only that folder, about 7 MB):

.. code-block:: powershell

   Set-Location C:\CableDyn
   git clone --filter=blob:none --no-checkout https://github.com/OpenFAST/r-test.git
   Set-Location r-test
   git sparse-checkout set glue-codes/fast-farm/MD_Shared
   git checkout dd5feaaaa500ba7283140107806300d551cff0a7
   Set-Location ..

Without Git, download
``https://github.com/OpenFAST/r-test/archive/dd5feaaaa500ba7283140107806300d551cff0a7.zip``
(the whole regression suite, much larger) and extract only ``glue-codes/fast-farm/MD_Shared``
to ``C:\CableDyn\r-test\glue-codes\fast-farm\MD_Shared``.

2. Assemble the case folder
---------------------------

Copy the turbine model and the CableDyn/MoorDyn integration files (every ``.fst`` and ``.dat``
in ``examples\openfast``) into one folder:

.. code-block:: powershell

   $case = 'C:\CableDyn\iea15_case'
   New-Item -ItemType Directory -Force $case | Out-Null
   Copy-Item -Recurse .\r-test\glue-codes\fast-farm\MD_Shared\* $case
   Copy-Item .\examples\openfast\*.fst, .\examples\openfast\*.dat $case
   Set-Location $case

The folder now holds, among others:

.. list-table::
   :header-rows: 1
   :widths: 46 54

   * - File
     - Role
   * - ``IEA-15-UMaine_CompMooring5_CableDyn.fst``
     - top-level OpenFAST input selecting CableDyn
   * - ``CableDyn_UMaine.dat``
     - the CableDyn ``MooringFile``: three 850 m R4 chains, 200 m water depth
   * - ``IEA-15-UMaine_CompMooring3_MoorDyn.fst`` / ``MoorDyn_UMaine.dat``
     - the identical model with stock MoorDyn, for the A/B
   * - ``IEA-15-240-RWT-UMaineSemi_ElastoDynT1.dat``, ``..._HydroDynT1.dat``, ``SeaState.dat``,
       ``HydroData\``, ``Airfoils\``, …
     - the turbine and platform model from ``MD_Shared``

3. Prepare the turbine model
----------------------------

``MD_Shared`` is a two-turbine FAST.Farm case. Its turbine-1 files start the platform at its farm
pose (20.3 m surge, 180° yaw, small roll/pitch/heave) and set HydroDyn's reference yaw
``PtfmRefY`` to 180°. The CableDyn and MoorDyn templates place the fairleads in platform axes
and the anchors around the origin, so reset the platform to the origin:

.. code-block:: powershell

   $ed = 'IEA-15-240-RWT-UMaineSemi_ElastoDynT1.dat'
   (Get-Content $ed) -replace '^\s*\S+(\s+Ptfm(Surge|Sway|Heave|Roll|Pitch|Yaw)\s)', '          0$1' |
       Set-Content $ed -Encoding ascii
   $hd = 'IEA-15-240-RWT-UMaineSemi_HydroDynT1.dat'
   (Get-Content $hd) -replace '^\s*\S+(\s+PtfmRefY\s)', '             0$1' |
       Set-Content $hd -Encoding ascii

This sets ``PtfmSurge``, ``PtfmSway``, ``PtfmHeave``, ``PtfmRoll``, ``PtfmPitch``, ``PtfmYaw``
(ElastoDyn) and ``PtfmRefY`` (HydroDyn) to zero and changes nothing else.

.. warning::

   Skipping this step still runs to completion, but the yawed, offset platform stretches line 1
   far beyond its 850 m length: CableDyn and MoorDyn then both report a physically meaningless
   321 MN fairlead tension. Always read the initial fairlead tensions before trusting a coupled
   run.

``MD_Shared``'s ``SeaState.dat`` computes the wave kinematics on a grid that covers only the
platform: ``X_HalfWidth = Y_HalfWidth = 100 m``, ``Z_Depth = 40 m``, ``NX = NY = NZ = 2``. The
mooring lines reach anchors 838 m away on the 200 m seabed, and SeaState gives every line node
outside the grid the kinematics of the grid boundary. Enlarge the grid to cover the lines:

.. code-block:: powershell

   $ss = 'SeaState.dat'
   (Get-Content $ss) -replace '^\s*\S+(\s+[XY]_HalfWidth\s)', '           900$1' `
                     -replace '^\s*\S+(\s+Z_Depth\s)', '     "default"$1' `
                     -replace '^\s*\S+(\s+NX\s)', '            37$1' `
                     -replace '^\s*\S+(\s+NZ\s)', '            11$1' |
       Set-Content $ss -Encoding ascii

This sets ``X_HalfWidth`` and ``Y_HalfWidth`` to 900 m, ``Z_Depth`` to the water depth, 37 grid
points along each half of x (25 m spacing) and 11 in depth. ``NY`` stays 2 because the
long-crested sea travels along x and does not vary in y. SeaState then needs about 4.6 GB of
memory and several seconds to generate the grid. Without this step the run still completes, but
CableDyn warns that 147 of its 153 line nodes lie outside the SeaState wave-kinematics grid, and
the line-1 fairlead tension standard deviation comes out 18 % too high. Grid sizing is
described in :ref:`openfast:SeaState grid`.

4. How CableDyn is wired in
---------------------------

Two rows of the ``.fst`` select the module and its input:

.. code-block:: text

         5   CompMooring     - Compute mooring system (switch) {0=None; 1=MAP++; 2=FEAMooring; 3=MoorDyn; 4=OrcaFlex; 5=CableDyn}
   "CableDyn_UMaine.dat"  MooringFile     - Name of file containing mooring system input parameters (quoted string)

The rest of the template: ``TMax = 70 s``, glue step ``DT = 0.025 s``, ElastoDyn, SeaState, and
HydroDyn on; InflowWind, AeroDyn, and ServoDyn off (no wind, no controller DLL needed).
``SeaState.dat`` from ``MD_Shared`` specifies an irregular JONSWAP sea, ``Hs = 6 m``,
``Tp = 12 s``.

Division of responsibility:

* **OpenFAST owns** the clock (``TMax``, ``DT``), gravity, water density, water depth, the
  platform motion, and the wave/current field (SeaState). Their values in the CableDyn deck are
  overridden; ``motionFile`` and deck ``waves`` rows are rejected in a coupled deck, and a deck
  ``current`` row is kept only as a steady current on a single-turbine, pure ``EI = 0`` deck
  without Rigid6 bodies or rods in a SeaState without waves or current.
* **The CableDyn deck owns** line types, points, lines, sections, seabed contact, solver
  settings, its own time step ``dtM``, and the ``OUTPUTS`` list. Fairlead ``Coupled`` points are
  given in platform axes; ``Fixed`` anchors in global axes.
* **The time step.** ``CableDyn_UMaine.dat`` sets ``dtM = 0.025`` = ``DT``, so CableDyn solves
  every glue step, which is also the default without a deck ``dtM``. A larger ``dtM`` solves
  once per several glue steps and holds the loads between solves, which is faster but delays
  them. For fatigue, snap, or touchdown work keep ``dtM = DT`` or prove that a coarser value
  converges.

The complete ownership table is in :doc:`options`; the coupling contract in :doc:`openfast`.

5. Run it
---------

.. code-block:: powershell

   C:\CableDyn\openfast.exe .\IEA-15-UMaine_CompMooring5_CableDyn.fst

The CableDyn part of the console (other modules' lines trimmed):

.. code-block:: text

    Running CableDyn (v0.4.2, 2026-11-09).
      CableDyn: geometrically exact finite-element statics and dynamics of mooring lines and dynamic power cables.
      ...
      CableDyn time step dtM = 2.50000E-02 s (1 x glue DT; deck dtM)
     Parsing CableDyn input file: .\CableDyn_UMaine.dat
      CableDyn: SeaState wave/current kinematics drive the mooring hydro (153 sampling nodes,
      refreshed every mooring step).
      Created CableDyn model: 3 line object(s), 6 point(s), 3 section(s) [EI=0: 3, finite-EI: 0].
      Initial conditions: Newton static equilibrium with load continuation completed.
      Line results below are at this equilibrium; SeaState kinematics act from t = 0.
      Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.
      Line 1 fairlead effective tension: 2.43712E+06 N
         force [Fx, Fy, Fz]: [-1.35070E+06, 0, -2.02858E+06] N, inclination=56.343 deg
         line tangent: inclination=55.685 deg, declination=145.68 deg, azimuth=180 deg
      Line 2 fairlead effective tension: 2.43715E+06 N
         ...
     CableDyn initialization completed.
       Requested CableDyn OUTPUTS at t = 0 s (equilibrium pose, SeaState kinematics at t = 0):
         FairTen1 = 2.43752E+06 (N)
         AnchTen1 = 1.35164E+06 (N)
         FairIncl1 = 55.685 (deg)
         ...
       These values are also the t = 0 CableDyn columns in the OpenFAST output file.
    Time: 0 of 70 seconds.
    ...
    Simulated Time:        70 seconds

    OpenFAST terminated normally.

Check, in order:

#. ``Running CableDyn (`` — the CableDyn-enabled executable is in use. A stock OpenFAST rejects
   ``CompMooring = 5`` during input validation.
#. The line inventory (3 lines, 6 points) and ``dtM``, and no ``WARNING: CableDyn mooring module:
   ... lie outside the SeaState wave-kinematics grid`` line (step 3).
#. The initial fairlead tensions: 2.437 MN per line, with the line tangent 55.7° below
   horizontal, as in the standalone ``spread_3line_chain.dat`` of :doc:`tutorial_spread`. The
   tension is the magnitude of the line-end force, which includes the fairlead node's share of
   the chain weight, so the force points slightly steeper, 56.3° below horizontal, with a
   horizontal component of 1.351 MN.
#. The ``OUTPUTS`` at t = 0: ``FairTen1`` reads 2.4375 MN, 0.02 % above the equilibrium value
   above. The equilibrium is solved before the SeaState kinematics act, and at t = 0 the wave
   kinematics add their hydrodynamic load on the fairlead end node. In still water
   (``WaveMod = 0``) the two values are equal. ``.CD.static.out`` holds the equilibrium, and the
   t = 0 row of ``.CD.out`` and of the main ``.out`` holds the t = 0 values.
#. ``OpenFAST terminated normally.``

6. Result files
---------------

.. list-table::
   :header-rows: 1
   :widths: 46 54

   * - File
     - Contents
   * - ``IEA-15-UMaine_CompMooring5_CableDyn.out``
     - the OpenFAST table at ``DT_Out``: platform motions, tower loads, …, and the CableDyn
       ``OUTPUTS`` channels
   * - ``IEA-15-UMaine_CompMooring5_CableDyn.CD.out``
     - CableDyn's own table: the ``OUTPUTS`` channels at ``t = 0`` and at every committed
       CableDyn step (every ``dtM``), with a units row
   * - ``IEA-15-UMaine_CompMooring5_CableDyn.CD.static.out``
     - the initial nodal equilibrium of every line (arc length, coordinates, tension, curvature,
       bend moment, declination, inclination, azimuth)
   * - ``*.ED.sum``, ``*.HD.sum``
     - the usual OpenFAST module summaries

.. code-block:: text

   Time                      FairTen1        AnchTen1        FairIncl1       AnchIncl1       FairTen2 ...
   (s)                       (N)             (N)             (deg)           (deg)           (N)      ...
     0.0000000000000000E+000   2.437520E+006   1.351636E+006   5.568478E+001  -1.961023E-002   2.436576E+006 ...
     2.5000000000000001E-002   2.438082E+006   1.351645E+006   5.568463E+001  -1.961023E-002   2.435530E+006 ...

CableDyn channels are chosen in the deck's ``OUTPUTS`` section (keep its closing ``END``), not in
the ``.fst`` ``OutList``. Channel names and units: :doc:`outputs`; sign and angle conventions:
:doc:`conventions`.

7. Compare with MoorDyn
-----------------------

The same binary still contains stock MoorDyn. The twin ``.fst`` differs only in
``CompMooring = 3`` and ``MooringFile = "MoorDyn_UMaine.dat"``. That deck sets the MoorDyn option
``SeaState WaterKin``, so MoorDyn's lines see the same SeaState waves that CableDyn samples at its
line nodes by default. Without that row MoorDyn lines see still water while CableDyn's see the
waves, and the fairlead tension standard deviations then differ by tens of percent for reasons
that have nothing to do with the solvers:

.. code-block:: powershell

   C:\CableDyn\openfast.exe .\IEA-15-UMaine_CompMooring3_MoorDyn.fst

Its console shows ``Running MoorDyn (v2.3.8, ...)``, ``Water kinematics will be simulated using
the SeaState method``, a dynamic-relaxation initialisation, and ``MoorDyn initialization
completed.``; MoorDyn writes ``...MD.out`` and puts its channels (upper-case ``FAIRTEN1`` …) in
the main ``.out``. Statistics over 10–70 s from the two main output files:

.. list-table::
   :header-rows: 1
   :widths: 28 18 18 18 18

   * - Channel
     - CableDyn mean
     - MoorDyn mean
     - CableDyn std
     - MoorDyn std
   * - ``PtfmSurge`` (m)
     - 0.899
     - 0.899
     - 1.380
     - 1.378
   * - ``PtfmHeave`` (m)
     - −1.030
     - −1.030
     - 1.221
     - 1.221
   * - ``PtfmPitch`` (deg)
     - 1.496
     - 1.496
     - 1.390
     - 1.390
   * - fairlead tension, line 1 (MN)
     - 2.456
     - 2.456
     - 0.115
     - 0.116
   * - fairlead tension, line 2 (MN)
     - 2.372
     - 2.372
     - 0.064
     - 0.064

The platform motions agree to within 0.2 %, the mean fairlead tensions to within 0.01 % and
their standard deviations to within 0.5 %. Both codes report the fairlead tension as the force
at the line end, which includes the end node's share of the chain weight. On this stiff chain
the MoorDyn deck uses a 0.2 ms explicit step and a dynamic-relaxation start and evaluates the
SeaState kinematics at every node of every substep, so allow a few minutes for that run.

To compare in still water instead, set ``WaveMod = 0`` in ``SeaState.dat`` for both runs. To keep
the waves on the platform but remove them from CableDyn's lines (for example against a MoorDyn
deck without ``WaterKin``), point the CableDyn deck's ``WaterKin`` row at a MoorDyn-style
WaterKin file with ``WaveKinMod 0`` and ``CurrentMod 0`` (:ref:`waterkin-file-modes`).

A 70 s run is a smoke test, not a comparison. For a real A/B, keep wind, waves, controller,
``DT``, output channels, and initial conditions identical, discard the start-up transient, run
at least one hour of analysis window, and compare statistics, spectra, and damage-equivalent
loads (:doc:`tutorial_python`). The published comparisons are in :doc:`validation`.

8. Add a lazy-wave power cable
------------------------------

``examples/iea15mw_umaine_mixed_cabledyn.dat`` adds a fourth, finite-EI line to the same three
chains: a dynamic power cable from a platform hang-off to a seabed termination, with a
bare/buoyant/bare section layout that forms a lazy wave and a grounded tail on the 200 m
seabed. Copy it into the case folder and point a copy of the ``.fst`` at it:

.. code-block:: powershell

   Copy-Item C:\CableDyn\examples\iea15mw_umaine_mixed_cabledyn.dat .
   (Get-Content .\IEA-15-UMaine_CompMooring5_CableDyn.fst) `
       -replace '"CableDyn_UMaine.dat"', '"iea15mw_umaine_mixed_cabledyn.dat"' |
       Set-Content .\Mixed_CableDyn.fst -Encoding ascii
   C:\CableDyn\openfast.exe .\Mixed_CableDyn.fst

.. code-block:: text

      Created CableDyn model: 4 line object(s), 8 point(s), 6 section(s) [EI=0: 3, finite-EI: 1].
      ...
      Line 4 fairlead effective tension: 11922 N
         force [Fx, Fy, Fz]: [1230, 0, -11858] N, inclination=84.078 deg
         line tangent: inclination=83.973 deg, declination=173.97 deg, azimuth=0 deg
      ...
         Curv4N38 = 9.01822E-02 (1/m)
         BendMom4N38 = 1794.6 (N.m)

CableDyn found the cable's touchdown and lazy-wave shape by itself: in
``Mixed_CableDyn.CD.static.out``, 149 of line 4's 249 nodes lie on the seabed. Node 38, 74 m
from the hang-off, is the peak of the sag bend. The cable's elements are at most half its bending
length :math:`(EI/|w|)^{1/3}` (the deck's comments give the numbers), which resolves the bends
and the touchdown. The chain moorings
use the cable element and the power cable the cubic-Hermite bending element, in one deck and one
coupled solve. Plot line 4's ``Curvature`` against ``ArcLength`` before looking at the time
history, and request ``Curv4N<J>``/``BendMom4N<J>`` channels at the hang-off, sag bend, arch, and
touchdown for fatigue.

Exercises
---------

1. **Wind.** Set ``CompInflow = 1`` and ``CompAero = 2`` in a copy of the ``.fst`` (the
   ``MD_Shared`` InflowWind and AeroDyn files are already present) and compare the mean surge and
   line-1 tension with the parked case.
2. **Supercycling.** Set ``dtM`` to 0.1 in ``CableDyn_UMaine.dat``. The console now
   reports ``dtM = 0.1 s (4 x glue DT; deck dtM)``, CableDyn solves once per four glue steps,
   and ``.CD.out`` has one row per 0.1 s. Here the line-1 tension statistics over 10–70 s barely
   move (mean 2.456 MN, std 0.116 MN, against 2.456 and 0.115 MN); verify that for your own
   quantities before adopting a coarser step.
3. **Still water.** Set ``WaveMod = 0`` in ``SeaState.dat``. Without waves the platform settles
   toward its still-water pose (mean heave −1.1 m, pitch 1.5°) with a decaying heave–pitch
   oscillation, and the line-1 tension stays within ±2 % of 2.41 MN.

Where next: :doc:`openfast` (checkpoint/restart, linearisation, FAST.Farm, line failures,
active tensioning), :doc:`coupling_boundary`, and :doc:`troubleshooting`.
