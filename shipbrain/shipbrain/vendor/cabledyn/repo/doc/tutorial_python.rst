.. SPDX-License-Identifier: Apache-2.0

Tutorial 8 — Python studies and post-processing
===============================================

**Goal:** generate and run a parameter study with full provenance, then reduce a dynamic tension
history to statistics, a rainflow damage-equivalent load, and a power spectrum.

**Decks:** ``examples/chain_catenary_r3_100m.dat``, ``examples/dynamic_chain_waves.dat``,
``examples/chain_range_tdp.dat``, ``examples/dynamic_chain_held.dat`` ·
**Needs:** the ``cabledyn`` wheel and ``CableDyn_driver.exe`` (:doc:`installation`) ·
**Run time:** seconds

Setup
-----

Work in an empty folder that holds copies of the four decks and of the motion history the
range-graph deck reads. The package finds the solver through ``CABLEDYN_DRIVER`` or ``PATH``;
for this session (with the release unpacked in ``C:\CableDyn``):

.. code-block:: powershell

   $env:CABLEDYN_DRIVER = 'C:\CableDyn\CableDyn_driver.exe'
   $ex = 'C:\CableDyn\examples'
   Copy-Item "$ex\chain_catenary_r3_100m.dat", "$ex\dynamic_chain_waves.dat", `
       "$ex\chain_range_tdp.dat", "$ex\dynamic_chain_held.dat" .
   New-Item -ItemType Directory -Force data | Out-Null
   Copy-Item -Recurse "$ex\data\range_tdp" data

(From a source build, point ``CABLEDYN_DRIVER`` at the built driver, ``build\bin\cabledyn.exe``
with the conda GNU toolchain or ``build\cabledyn.exe`` with Intel Fortran and MSVC, and put the
repository's ``python`` folder on ``PYTHONPATH`` or ``pip install ./python``.) The Python calls
below create the ``results`` and ``study`` folders they write to.

A water-depth study
-------------------

``generate_deck_cases`` writes one validated deck per case and a ``cases.json`` manifest;
``CableDynDriver.run`` executes one deck, checks the exit code, and returns a result object.

.. code-block:: python

   from pathlib import Path
   from cabledyn import CableDynDriver, generate_deck_cases

   driver = CableDynDriver()          # CABLEDYN_DRIVER, then PATH
   cases = generate_deck_cases(
       "chain_catenary_r3_100m.dat",
       "study/depth",
       {
           f"depth_{d}": {"option.WtrDpth": float(d), "point.1.z": -float(d)}
           for d in (80, 100, 120)
       },
   )

   for case in cases:
       root = (Path("results") / case.name).resolve()
       result = driver.run(case.deck, root, cwd=case.working_directory)
       table = result.read_main()
       print(f"{case.name:10s} FairTen1 = {table.column('FairTen1')[-1] / 1e3:8.1f} kN"
             f"   FairIncl1 = {table.column('FairIncl1')[-1]:6.2f} deg")

.. code-block:: text

   depth_80   FairTen1 =    328.2 kN   FairIncl1 =  76.32 deg
   depth_100  FairTen1 =    509.9 kN   FairIncl1 =  67.24 deg
   depth_120  FairTen1 =    758.6 kN   FairIncl1 =  59.64 deg

.. important::

   Change **everything** a physical change implies. The seabed follows ``WtrDpth``, but the
   anchor is a point with its own ``z``. Changing only ``option.WtrDpth`` to 80 would leave the
   anchor at ``z = -100``, 20 m below the seabed; the deck is then rejected before any solve
   with exit code ``1`` ("POINT 1 (Fixed) lies below the seabed"). ``generate_deck_cases``
   validates each edited deck and raises ``DeckFormatError`` with the same diagnostic before
   any deck is written. The selector ``point.1.z`` moves the
   anchor with the seabed.

Selectors address one field each:

.. list-table::
   :header-rows: 1
   :widths: 38 62

   * - Selector
     - Addresses
   * - ``option.<keyword>``
     - an ``OPTIONS`` value, e.g. ``option.TMax``; ``waves``/``current`` take a tuple such as
       ``("jonswap", 2.0, 8.0, 3.3, 0.0)``
   * - ``point.<id>.<field>``
     - a ``POINTS`` column: ``x``, ``y``, ``z``, ``mass``, ``vol``, ``cda``, ``ca``, ``type``
   * - ``line_type.<name>.<field>``
     - a ``LINE TYPES`` column: ``diam``, ``mass``, ``ea``, ``ba``, ``ei``, ``cdn``, ``cdt``,
       ``can``, ``cat``
   * - ``section.<line>.<occurrence>.<field>``
     - the n-th ``SECTIONS`` row of a line: ``linetype``, ``length``, ``numsegs``
   * - ``end_connection.<line>.<end>.<field>``
     - an ``END CONNECTIONS`` row

All changes of one case are applied together and the edited deck is re-validated before it is
written. ``study/depth/cases.json`` records, per case, the changes, the deck path, and its
SHA-256 — keep it with the results. ``driver.run`` refuses to overwrite an existing result unless
``overwrite=True``. The ``cabledyn-study`` command runs every case of a ``cases.json`` manifest
(written by ``generate_deck_cases`` or ``cabledyn-deck generate``) with the same checks; see
:doc:`python`.

A dynamic record: statistics, fatigue, spectrum
-----------------------------------------------

Make a 600 s JONSWAP variant of the wave deck and reduce it:

.. code-block:: python

   from pathlib import Path
   from cabledyn import CableDynDriver, generate_deck_cases

   driver = CableDynDriver()
   (case,) = generate_deck_cases(
       "dynamic_chain_waves.dat",
       "study/sea",
       {"jonswap_600s": {"option.waves": ("jonswap", 2.0, 8.0, 3.3, 0.0),
                         "option.TMax": 600.0}},
   )
   history = driver.run(case.deck, Path("results/jonswap_600s").resolve(),
                        cwd=case.working_directory).read_main()

   settled = history.period(start=100.0)          # discard the start-up transient

   fat = settled.fatigue("FairTen1", wohler_exponent=3.0, reference_frequency=1.0)
   print(f"cycles {fat.cycle_count:.1f}  DEL(1 Hz, m=3) = {fat.damage_equivalent_range / 1e3:.2f} kN")

   psd = settled.spectrum("FairTen1", segment_length=2048, overlap=0.5)
   print(f"df = {psd.frequency_resolution:.4f} Hz, m0 = {psd.moment(0):.4g} {psd.moment_unit(0)}")
   for peak in psd.dominant_peaks(3):
       print(f"peak at {peak.frequency:.4f} Hz")

.. code-block:: text

   cycles 374.0  DEL(1 Hz, m=3) = 1.92 kN
   df = 0.0098 Hz, m0 = 8.099e+05 N^2
   peak at 0.1270 Hz
   peak at 0.3906 Hz
   peak at 0.7422 Hz

How to read these:

* **Statistics.** ``history.statistics("FairTen1")`` returns count, minimum, maximum, mean,
  standard deviation, and RMS; ``settled.statistics(...)`` restricts them to the window.
* **Fatigue.** ``fatigue`` rainflow-counts the tension ranges (ASTM-style full and half cycles)
  and returns the damage-equivalent range for Wöhler exponent ``m`` at a reference frequency.
  It is an **uncorrected** short-term DEL for like-for-like comparison — not a fatigue life. No
  S–N intercept, detail class, corrosion factor, safety factor, or mean-stress correction is
  applied. For Miner damage and fatigue life against an S–N or T–N curve, see
  :doc:`python_postprocessing`.
* **Spectrum.** A one-sided Welch power spectral density in N²/Hz; ``m0`` is its integral (the
  variance, 900² N² here). The main peak at 0.127 Hz is the wave peak ``1/Tp = 0.125 Hz``
  resolved to the 0.0098 Hz bin spacing; the higher peaks are wave–line interaction harmonics.
  Choose the segment length from the frequency resolution and number of averages you need.

The tension varies by only about ±4 kN here because the fairlead is held: the waves act only on the
chain. Apply the same reduction to a coupled record of OpenFAST, maintained by NLR (National
Laboratory of the Rockies, formerly NREL) (:doc:`tutorial_openfast`), or a
prescribed-motion run (:doc:`tutorial_motion`) for design-relevant numbers, after the time-step
and mesh checks of :doc:`tutorial_dynamics`.

The same from the command line
------------------------------

.. code-block:: powershell

   cabledyn-post summary  results\jonswap_600s.out --start 100
   cabledyn-post fatigue  results\jonswap_600s.out FairTen1 --start 100 --m 3 `
       --reference-frequency 1 --bins 16 --cycles-output results\FairTen1_cycles.csv
   cabledyn-post spectrum results\jonswap_600s.out FairTen1 --start 100 `
       --segment-length 2048 --moment 0 --moment 2 --peaks 3 --output results\FairTen1_psd.csv

``--plot-output file.png`` adds a figure when matplotlib is installed (the ``plot`` extra,
``pip install "cabledyn[plot]"``). The exact-cycle CSV is the auditable record; histograms and plots
are views of it.
``cabledyn-post coherence`` computes the magnitude-squared coherence between two channels with
the same Welch partition.

Range graphs and the touchdown point
------------------------------------

``chain_range_tdp.dat`` surges the fairlead of a 410 m chain in 50 m of water by 5 m, with a
30 s period, under a 6 m, 10 s Airy wave. The ``LINES`` ``Outputs`` flag ``r`` and
``30.0 RangeStart`` make the solver write ``<root>.Line1.range.out``: the minimum, maximum and mean
over t = 30–120 s
(1801 samples) of the tension, curvature, bend moment, declination and seabed clearance at every
node. The fairlead tension ranges from 524 to 2815 kN (mean 1332 kN, static 1006 kN).

.. code-block:: python

   from pathlib import Path
   from cabledyn import CableDynDriver, read_range_graphs

   CableDynDriver().run("chain_range_tdp.dat", Path("results/range").resolve())
   tension = read_range_graphs("results/range.Line1.range.out")["tension"]
   print(tension.maximum.max(), tension.location[tension.maximum.argmax()], tension.time_window)

``python C:\CableDyn\examples\plot_range_envelope.py results\range --save range.png`` plots the
band and the mean against arc length. The ``TDP1s``, ``TDP1Lay`` and ``TDP1Exc`` channels track the
touchdown
point: at rest it lies 159.7 m of arc from the fairlead with a 149.5 m layback, and during the
surge it moves between 109.7 and 285.4 m of arc, an excursion of −125.2 to +49.9 m.

Python API for GUIs and scripting
---------------------------------

The in-process API runs a deck inside Python and reads any object at any step, which is what a
pre- and post-processing GUI needs. It needs the shared library (set ``CABLEDYN_LIBRARY``, see
:doc:`python`). This run surges the fairlead of ``dynamic_chain_held.dat`` 2 m at a 10 s period
for 20 s, records the geometry every fourth step and writes an animation:

.. code-block:: python

   import math
   import numpy as np
   import cabledyn
   from cabledyn.animation import record

   with cabledyn.CableDyn("dynamic_chain_held.dat") as model:
       line, fairlead = model.line(1), model.point(2)
       print(line.name, line.n_nodes, fairlead.kind,
             f"FairTen1 = {line.fairlead_tension() / 1e3:.1f} kN")

       q0, _, _ = model.get_coupled_motion()
       # the coupled block that holds the fairlead
       block = int(np.flatnonzero(np.all(np.isclose(q0.reshape(-1, 3), fairlead.position()),
                                         axis=1))[0])
       w = 2.0 * math.pi / 10.0

       def surge(t):
           q, v, a = q0.copy(), np.zeros_like(q0), np.zeros_like(q0)
           q[3 * block] += 2.0 * math.sin(w * t)
           v[3 * block] = 2.0 * w * math.cos(w * t)
           a[3 * block] = -2.0 * w * w * math.sin(w * t)
           return q, v, a

       snaps = record(model, 0.05, 400, every=4, motion=surge)

   ten = snaps.tensions[1][:, 0]                    # End A segment
   print(snaps.n_frames, f"{ten.max() / 1e3:.1f} {snaps.times[ten.argmax()]:.1f}"
         f" {ten.min() / 1e3:.1f}")
   positions = cabledyn.line_positions(snaps.lines[1], time=snaps.times)
   clearance = cabledyn.seabed_clearance(positions, -50.0)
   print(f"{clearance.minimum:.3f} {clearance.minimum_arc_length:.1f}"
         f" {clearance.minimum_time:.1f}")
   snaps.save_npz("chain_surge.npz")
   cabledyn.animate(snaps, stride=2).save("chain_surge.gif", writer="pillow", fps=10)

.. code-block:: text

   Line1 42 coupled FairTen1 = 1005.6 kN
   101 1457.1 6.2 281.7
   -0.163 150.1 1.0

The static fairlead tension is 1005.6 kN with 26 of the 42 nodes on the seabed. Over the 101
recorded frames the End A segment tension ranges from 281.7 kN to 1457.1 kN, the peak at
t = 6.2 s. The lowest node sits 0.163 m into the penalty seabed at 150.1 m of arc. The
``.npz`` archive holds one array per object (91 kB here); a viewer reads only the arrays it
draws. ``Snapshots.from_files(root, deck=...)`` builds the same object from a driver run's
``.Line<L>.p.out``/``.t.out`` files, so recorded and file-based results play through the same
viewer.

Exercises
---------

1. **Two-parameter study.** Sweep ``section.1.1.length`` (540, 550, 560 m) at each of the three
   depths — nine cases in one ``generate_deck_cases`` call — and tabulate ``FairTen1``.
2. **pandas.** With the ``post`` extra installed, ``history.to_dataframe()`` returns a
   DataFrame with unit-labelled columns; plot ``FairTen1`` against time.
3. **Segment length.** Recompute the spectrum with ``segment_length=1024`` and ``4096``. The
   frequency resolution halves with each doubling (0.0195, 0.0098, 0.0049 Hz). ``m0`` is
   8.162e+05, 8.099e+05, and 9.788e+05 N² for 1024, 2048, and 4096 samples: within 2 % of the
   record variance (8.258e+05 N²) for the two shorter segments, but about 21 % higher for 4096.
   Finer resolution does not change the integral. The cause is averaging: only three
   4096-sample segments fit into the 500 s window, and they leave its last 90 s unused, so the
   estimate rests on three Hann-weighted segments and carries a large random error. What happens
   to the peak height, and how many segments would you need for a stable ``m0``?

Next: :doc:`tutorial_openfast`.
