.. SPDX-License-Identifier: Apache-2.0

Tutorial 5 — Current, waves, and convergence
============================================

**Goal:** add a current, a regular Airy wave, and an irregular JONSWAP sea to a dynamic mooring
line; then show that the result is converged in time step and mesh.

**Decks:** ``examples/dynamic_chain_held.dat``, ``dynamic_chain_current.dat``,
``dynamic_chain_waves.dat`` · **Route:** ``EI = 0`` cable dynamics · **Run time:** < 1 s each

The baseline
------------

``dynamic_chain_held.dat`` is a 410 m chain in 50 m of water with the fairlead held at the
surface. It adds two options to a static deck:

.. code-block:: text

   0.05         dtM       - CableDyn internal time step (s)
   10.0         TMax      - Standalone simulation duration (s)

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null   # already there after the quickstart
   .\CableDyn_driver.exe .\examples\dynamic_chain_held.dat .\results\held

The held line starts in static equilibrium and nothing disturbs it, so every row of
``held.out`` repeats the static values (``FairTen1 = 1005.63 kN``). This is the first check of any
dynamic model: **a system started at equilibrium with no forcing must stay there.** A drift here
would point to an inconsistent initial condition.

Environment records
-------------------

The current and wave decks differ from the baseline by one row each:

.. code-block:: text

   uniform 1.0 0.0 0.0  current   - Current model and X/Y/Z velocity (m/s) {none; uniform; profile}

.. code-block:: text

   airy 2.0 8.0 0.0     waves     - Wave model, height, period, and direction (m, s, deg) {none; airy; jonswap}

* ``current`` accepts ``none``, ``uniform vx vy vz``, or a two-level
  ``profile z1 vx1 vy1 vz1 z2 vx2 vy2 vz2``; use a WaterKin current table for more levels.
  The static initial condition includes the current's steady drag, so the line starts the
  march at rest in the current.
* ``waves`` accepts, for example, ``none``, ``airy H T direction`` (regular linear wave), or
  ``jonswap Hs Tp gamma direction`` (irregular sea); ``stream``, ``pm``/``issc``,
  ``torsethaugen``, and ``ochihubble`` rows and multi-train ``wavetrain`` rows are shown below
  and listed in :doc:`options`. Waves need ``WtrDpth`` for dispersion.
* ``WaveSeed`` (default ``1``) selects the random JONSWAP realisation: the same seed always
  reproduces the same sea, and extreme-value statistics need several seeds.
* ``rampTime`` (default ``0``, off) fades the waves in from still water with a half-cosine over
  the given time. The static initial condition has no waves, so switching the full sea
  on at ``t = 0`` gives a start-up transient; a ramp of one to two peak periods, e.g.
  ``16.0 rampTime``, removes it. Discard at least the ramp window from the statistics.
* The fluid loads are Morison drag and added mass on the relative velocity, plus Froude–Krylov
  and buoyancy from the wave field. Directions are in degrees from ``+X`` toward ``+Y``.

Full syntax and restrictions are in :doc:`options`. In a coupled run of OpenFAST (maintained by
NLR, the National Laboratory of the Rockies, formerly NREL) the host's SeaState supplies these
fields instead (:doc:`tutorial_openfast`).

Run the three cases for 60 s
----------------------------

Copy the three decks, set ``TMax`` to ``60.0`` in each, and add a JONSWAP copy of the wave deck
with ``jonswap 2.0 8.0 3.3 0.0 waves``. Then:

.. code-block:: powershell

   .\CableDyn_driver.exe .\current60.dat .\results\current60
   .\CableDyn_driver.exe .\airy60.dat    .\results\airy60
   .\CableDyn_driver.exe .\jonswap60.dat .\results\jonswap60

``FairTen1`` statistics over the settled window 20–60 s:

.. list-table::
   :header-rows: 1
   :widths: 30 17 17 18 18

   * - Case
     - Mean (kN)
     - Std (kN)
     - Min (kN)
     - Max (kN)
   * - held, still water
     - 1005.63
     - 0
     - 1005.6
     - 1005.6
   * - uniform current 1.0 m/s
     - 1020.34
     - 0
     - 1020.3
     - 1020.3
   * - Airy, H = 2 m, T = 8 s
     - 1005.95
     - 1.28
     - 1003.0
     - 1008.0
   * - JONSWAP, Hs = 2 m, Tp = 8 s, γ = 3.3
     - 1005.81
     - 0.72
     - 1003.7
     - 1008.2

Interpretation: the current adds a steady drag that raises the mean tension by 15 kN; the
waves leave the mean unchanged and add a small oscillation, because with the fairlead held the
waves can only act on the line itself. In a real floating system the dominant dynamic tension
comes from the platform motion, which you add with a motion file (:doc:`tutorial_motion`) or by
coupling to OpenFAST (:doc:`tutorial_openfast`). The JONSWAP record is irregular: judge it by
statistics and spectra over a long window (:doc:`tutorial_python`), never by one peak.

Time-step convergence
---------------------

Repeat the Airy case at ``dtM = 0.1``, ``0.05``, and ``0.025``:

.. list-table::
   :header-rows: 1
   :widths: 28 18 18 18 18

   * - ``dtM`` (s)
     - Mean (kN)
     - Std (kN)
     - Min (kN)
     - Max (kN)
   * - 0.1
     - 1005.95
     - 1.24
     - 1003.1
     - 1008.0
   * - 0.05
     - 1005.95
     - 1.28
     - 1003.0
     - 1008.0
   * - 0.025
     - 1005.95
     - 1.30
     - 1002.9
     - 1008.2

The mean is converged at every step and the standard deviation changes by less than 2 % between 0.05
and 0.025 s — adequate for this quantity. Compare means, standard deviations, ranges, and, for
fatigue, damage-equivalent loads; one final value proves nothing.

Mesh convergence
----------------

Double the elements (``NumSegs`` 41 → 82) at ``dtM = 0.05``: the mean moves from 1005.95 to
1005.65 kN (−0.03 %) and the standard deviation from 1.28 to 1.27 kN. The fairlead channel
reports the line-end force (:doc:`tutorial_catenary`), so the mesh barely moves it. Decide the
mesh on the quantity you report.

.. admonition:: A convergence protocol
   :class: tip

   #. Start at a ``dtM`` that resolves the shortest wave or motion period with at least 40–100
      steps.
   #. Halve ``dtM`` until the statistics you report change by less than your tolerance.
   #. Refine the mesh the same way.
   #. Record both in the analysis report.

Irregular and spread seas
-------------------------

``chain_torsethaugen_spread.dat`` puts the held chain in a Torsethaugen sea:

.. code-block:: text

   torsethaugen 5.0 11.0 30.0 waves
   4.0       WaveSpreading
   9         WaveDirections
   100       WaveComponents
   1         WaveSeed
   20.0      rampTime

The wind-sea and swell peaks of the spectrum follow from Hs and Tp. Each frequency is spread over
±90° about 30° with D(θ) ∝ cos⁸(θ − 30°) in nine direction bins, and the same seed always gives
the same sea. Over 20–300 s the fairlead tension has a mean of 1.006 MN and a standard deviation
of 4.0 kN; with ``0.0 WaveSpreading`` (long-crested) the deviation is 5.0 kN.

``chain_two_train_sea.dat`` replaces the ``waves`` row (kept as ``none``) by two ``wavetrain``
rows, each with its own heading and spreading (train *i* uses the seed ``WaveSeed`` + 7919 (*i* − 1)):

.. code-block:: text

   jonswap 3.0 7.0 3.3 0.0 6.0 wavetrain
   jonswap 2.0 14.0 5.0 60.0 0.0 wavetrain

The fairlead tension deviation is 1.95 kN, against 1.58 kN for the wind sea alone.

MoorDyn-C kinematics files
--------------------------

``moordynC_wavekin/chain_wavekin7_currents1.dat`` reads MoorDyn-C's fixed-name files from its own
folder. ``7 WaterKin`` (value 7, as in MoorDyn-C's ``WaveKin 7``) loads
``wave_frequencies.txt``, ``omega Re Im beta`` rows with the first at ω = 0: here nine components
of a 2.5 m, 9 s JONSWAP sea travelling along +X. ``1 Currents`` loads ``current_profile.txt``, a
``z ux uy uz`` table rising from 0.2 m/s at the seabed to 0.6 m/s at the surface. The ``waves``
and ``current`` rows stay ``none``: a second source is rejected as double counting. CableDyn
evaluates the components and the profile exactly at every node, so ``water_grid.txt`` is not
needed. The current enters the static state (fairlead tension 1.0076 MN against 1.0056 MN in
still water), and the waves add a 2.1 kN standard deviation over 120 s.

Nonlinear regular waves
-----------------------

In shallow water a steep wave is not sinusoidal. ``stream_wave_shallow_chain.dat`` puts the 30 m
R4 chain under ``stream 8.0 10.0 0.0 waves`` (H/d = 0.27), a Dean stream-function wave with
``20 StreamOrder`` Fourier terms; ``airy_wave_shallow_chain.dat`` is the same deck with ``airy``.
Over t = 30–60 s:

.. list-table::
   :header-rows: 1

   * - Wave
     - FairTen1 min / max / mean (kN)
     - AnchTen1 min / max / mean (kN)
   * - stream
     - 134.5 / 168.5 / 151.7
     - 19.6 / 39.0 / 29.1
   * - Airy
     - 133.0 / 168.6 / 151.3
     - 22.8 / 38.7 / 30.6

The fairlead range barely changes (34.0 against 35.6 kN), but the anchor tension range is 22 %
larger under the stream wave (19.4 against 15.9 kN).

Anisotropic seabed friction
---------------------------

``laid_cable_cross_current.dat`` lays half of a 230 m cable on the seabed in a 1.2 m/s cross
current (+Y), with different friction along and across the cable:

.. code-block:: text

   0.3  frictionMuAxial
   1.0  frictionMuLateral

The static solve finds where the laid run stops sliding, and the 10 s march keeps it there. The
current loads the run across its axis, so the lateral coefficient decides:

.. list-table::
   :header-rows: 1

   * - Friction (axial / lateral)
     - FairTen1 (kN)
     - TDP1s (m)
     - Sway at s = 160 m (m)
   * - 0.3 / 1.0 (deck)
     - 59.0
     - 109.6
     - 0.01
   * - 1.0 isotropic
     - 59.0
     - 109.6
     - 0.01
   * - 0.3 isotropic
     - 64.3
     - 117.1
     - 11.8
   * - none
     - 73.9
     - 127.9
     - 19.6

A single coefficient equal to the axial value lets the laid run slide up to 16 m sideways and
raises the fairlead tension by 9 %.

Exercises
---------

1. **Current profile.** Replace the uniform current by
   ``profile -50.0 0.2 0.0 0.0 0.0 1.0 0.0 0.0 current`` (0.2 m/s at the seabed, 1.0 m/s at the
   surface). How much of the mean-tension increase remains? (About 6 kN of the 15 kN: drag
   scales with the square of the local velocity.)
2. **Wave direction.** Run the Airy case with direction 90°. The tension reacts more, not less:
   its standard deviation over 20–60 s rises from 1.28 kN at 0° to 1.88 kN at 90° (range
   1003.0–1009.0 kN), with the mean unchanged at 1005.9 kN. Waves crossing the line broadside
   load its whole length with normal drag and inertia out of its plane, whereas head-on waves act
   partly along the line, most of all on the grounded and near-horizontal part.
3. **Spectrum.** Run the JONSWAP deck for 600 s and plot its tension spectrum as shown in
   :doc:`tutorial_python`; the peak sits at ``1/Tp = 0.125 Hz``.

Next: :doc:`tutorial_ropes`.
