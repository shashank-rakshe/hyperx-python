.. SPDX-License-Identifier: Apache-2.0

Post-processing with other tools' results
=========================================

The ``cabledyn`` package reads the output of the tools a CableDyn study is usually checked
against, and applies the same typed tables, statistics, fatigue, spectra, plots, and exports to
them (:doc:`python`). This page covers the readers, run-to-run comparison, resampling and
filtering, extreme-value statistics, line geometry, fatigue damage, range graphs, design checks,
touchdown histories, and parameter grids. All of them need NumPy only; plots need matplotlib.

Reading OpenFAST, MoorDyn, and coupled runs
-------------------------------------------

These readers accept the outputs of OpenFAST (maintained by NLR, the National Laboratory of the
Rockies, formerly NREL), of MoorDyn, and of an OpenFAST run with CableDyn as its mooring module.

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Function
     - Reads
   * - :func:`cabledyn.read_openfast_output`
     - An OpenFAST time series: the tab-separated text ``<root>.out`` (title lines, channel row,
       units row) or the binary ``<root>.outb`` written with ``OutFileFmt = 2`` or ``3``. All
       four binary format identifiers are decoded; compressed files carry the 16-bit
       quantization OpenFAST applied when writing. The file description becomes the title.
   * - :func:`cabledyn.read_moordyn_output`
     - A MoorDyn main output ``<root>.MD.out``. Channel names keep MoorDyn's spelling, such as
       ``FAIRTEN1``.
   * - :func:`cabledyn.read_moordyn_line`
     - A MoorDyn-F per-line file ``<root>.MD.Line<N>.out`` as a
       :class:`~cabledyn.MoorDynLineHistory`. Nodes are numbered from 0 (End A) to N, segments
       from 1 to N, as MoorDyn writes them.
   * - :func:`cabledyn.read_coupled_run`
     - The files of one OpenFAST run with CableDyn as its mooring module (``CompMooring = 5``):
       ``<root>.CD.out``, ``<root>.CD.static.out``, and ``<root>.out`` or ``<root>.outb``, as a
       :class:`~cabledyn.CoupledRun`. Pass the OpenFAST output root, or the ``.fst`` path.
   * - :func:`cabledyn.read_table`
     - Any of the above, chosen from the file name (``format="auto"``), or with an explicit
       ``format`` of ``"cabledyn"``, ``"openfast"``, ``"moordyn"``, or ``"moordyn-line"``.

.. code-block:: python

   from cabledyn import read_coupled_run, read_moordyn_line, read_openfast_output

   run = read_coupled_run("IEA-15-UMaine_CompMooring5_CableDyn.fst")
   print(run.cabledyn.statistics("FairTen1")[0])          # <root>.CD.out
   print(run.static.summary(1))                              # <root>.CD.static.out
   platform = run.openfast                                   # <root>.out or .outb

   glue = read_openfast_output("DLC11_seed1.outb")
   line = read_moordyn_line("moordyn_ref.MD.Line1.out")
   xyz = line.positions(600.0)                               # (N + 1, 3), metres
   tension = line.segment_tensions(600.0)                    # (N,), newtons

The readers are strict in the same way as :func:`cabledyn.read_output`. They raise
:class:`cabledyn.OutputFormatError` for a missing ``Time`` header, a units row of the wrong
width, a short or non-numeric row, a non-finite value, a repeated channel name in a MoorDyn file
or in a CableDyn static profile or per-line table (time histories keep repeated names, as
described below), non-increasing time, a truncated or over-long binary file, or MoorDyn line
channels that do not cover every node or segment. :func:`~cabledyn.read_coupled_run` refuses a
root that has both ``.out`` and ``.outb``, because either could be stale.

An OpenFAST OutList may request the same channel twice; the IEA-15MW ElastoDyn file of the
OpenFAST regression tests lists ``TwrBsFzt`` twice, and the coupled example inherits it. The
OpenFAST readers, and :func:`cabledyn.read_output` on any time history, keep every column: the
first occurrence keeps its name, so ``column("TwrBsFzt")`` returns it, and later ones become
``TwrBsFzt_2``, ``TwrBsFzt_3``, and so on (a suffix the file already uses is skipped). A
:class:`UserWarning` lists the renamed columns.

``cabledyn-post`` uses the same readers, so every subcommand accepts these files. Add
``--format`` to override the choice made from the file name:

.. code-block:: text

   cabledyn-post summary run.MD.Line1.out
   cabledyn-post spectrum DLC11.outb PtfmSurge --segment-length 4096
   cabledyn-post summary results.dat --format moordyn

Comparing two runs
------------------

:func:`cabledyn.compare_histories` compares a candidate time history with a reference, channel
by channel, and returns a :class:`~cabledyn.HistoryComparison`. Both records are restricted to
the interval they share, optionally narrowed by ``start``/``stop``, and the candidate is
linearly interpolated onto the reference samples inside it (``grid="candidate"`` reverses
this). Nothing is extrapolated, and identical time vectors are compared sample by sample.

.. code-block:: python

   from cabledyn import compare_histories, read_moordyn_output, read_output

   cabledyn_run = read_output("results/dlc11.out")
   moordyn_run = read_moordyn_output("moordyn/dlc11.MD.out")
   comparison = compare_histories(
       moordyn_run, cabledyn_run,
       channels={"FAIRTEN1": "FairTen1", "FAIRTEN2": "FairTen2"},
       start=600.0, stop=4200.0, percentile=99.0,
   )
   for item in comparison.worst(2):
       print(item.channel, item.normalized_rms_difference, item.maximum_delta)
   comparison.export("results/dlc11_vs_moordyn.csv")

Each :class:`~cabledyn.ChannelComparison` reports, with ``difference = candidate - reference``:
the maximum absolute, mean, and RMS difference; the RMS difference divided by the reference
standard deviation; the maximum absolute difference divided by the largest absolute reference
value; the Pearson correlation; and the change of the maximum, minimum, mean, standard
deviation, and chosen percentile. A normalised metric or the correlation is ``nan`` when its
denominator is zero, for example for a constant channel. When both tables record units for a
pair, a mismatch raises ``ValueError`` unless ``check_units=False``.

From the command line:

.. code-block:: text

   cabledyn-post compare moordyn/dlc11.MD.out results/dlc11.out \
       --channel FAIRTEN1=FairTen1 --start 600 --stop 4200 --output compare.csv

``--channel`` takes ``NAME`` or ``REFERENCE=CANDIDATE`` and may be repeated; without it every
channel present in both files under the same name is compared.

Resampling and filtering
------------------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Function
     - Result
   * - :func:`cabledyn.resample`
     - Every channel linearly interpolated onto a uniform ``step`` (from ``start`` to ``stop``)
       or onto explicit ``times``, all inside the recorded interval.
   * - :func:`cabledyn.moving_average`
     - A centred moving mean over an odd number of samples. The first and last half-window are
       dropped, so every returned sample is a full-window mean; unselected channels are kept at
       the retained times.
   * - :func:`cabledyn.fft_filter`
     - An ideal zero-phase low-pass (``high``), high-pass (``low``), or band-pass (both) filter
       applied in the frequency domain.

The functions return a new table of the input's type and never modify the input. Filtering
requires uniform sampling; resample a variable-step record first. The FFT filter treats the
record as periodic: with the default ``detrend="linear"`` it removes the least-squares line
before the transform (restoring it for a low-pass filter), which reduces ringing at the record
ends of a drifting signal; ``detrend="none"`` is exact for a record holding whole periods of
every component. The pass band is rectangular, so judge filtered data away from the ends and
from sharp transients.

.. code-block:: python

   from cabledyn import fft_filter, resample

   uniform = resample(history, step=0.1)
   low_frequency = fft_filter(uniform, high=0.03, channels="FairTen1")   # slow drift
   wave_frequency = fft_filter(uniform, low=0.05, high=0.3)               # 3.3 to 20 s

Extreme values
--------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Function
     - Result
   * - :func:`cabledyn.block_maxima`
     - The maximum (``minima=True``: minimum) of each complete, non-overlapping block of
       ``block_duration`` seconds; a trailing partial block is discarded.
   * - :func:`cabledyn.upcrossing_maxima`
     - The largest value between successive up-crossings of a level (default: the mean), one
       peak per complete cycle.
   * - :func:`cabledyn.fit_gumbel`
     - A Gumbel (largest extreme value) fit, by maximum likelihood (default) or the method of
       moments, as a :class:`~cabledyn.GumbelFit` with ``cdf``, ``quantile``,
       ``most_probable_maximum``, and ``return_level``.
   * - :func:`cabledyn.fit_weibull`
     - A two-parameter Weibull fit by maximum likelihood, as a :class:`~cabledyn.WeibullFit`
       with ``cdf`` and ``quantile``.

.. code-block:: python

   from cabledyn import block_maxima, fit_gumbel

   maxima = block_maxima(history, "FairTen1", block_duration=3600.0)   # one per hour
   gumbel = fit_gumbel(maxima)
   print(gumbel.most_probable_maximum(3.0))    # mode of the 3-hour maximum
   print(gumbel.quantile(0.9))                 # 90 % non-exceedance of the 1-hour maximum

The maximum-likelihood estimates solve the likelihood equations exactly (bisection on a
bracket that provably contains the root) and agree with SciPy's ``gumbel_r.fit`` and
``weibull_min.fit(floc=0)``. The fits describe the sample they are given. They do not test
independence or stationarity, give no confidence interval, and
``most_probable_maximum(blocks)`` assumes independent, identically distributed blocks.

Line geometry
-------------

:func:`cabledyn.line_geometry` computes node-based geometry for one line from a static profile
(``line_id`` selects a line when there are several), a dynamic per-line position history or a
MoorDyn line file at a snapshot ``time``, or an ``(n, 3)`` coordinate array in End-A-to-End-B
order. The :class:`~cabledyn.LineGeometry` holds read-only per-node arrays of coordinates, chord
arc length from End A, inclination above the horizontal (positive when the line rises towards
End B), and discrete curvature (the inverse radius of the circle through each interior node and
its neighbours; ``nan`` at the two ends). It also provides the total length, horizontal and
vertical spans, the smallest discrete bend radius, and a CSV export.

:meth:`~cabledyn.LineGeometry.touchdown` locates where the line leaves a flat seabed at
``seabed_z``: a node is grounded when ``z <= seabed_z + tolerance``, and the grounded run must
start at one end. The :class:`~cabledyn.Touchdown` reports the last grounded node, its arc length
and coordinates, the grounded and suspended chord lengths, and the layback (horizontal distance
to the suspended end). The estimate is resolved to one output segment.

.. code-block:: python

   from cabledyn import line_geometry

   geometry = line_geometry(result.read_static(), line_id=1)
   touchdown = geometry.touchdown(seabed_z=-200.0, tolerance=0.05)
   if touchdown is not None:
       print(touchdown.arc_length, touchdown.layback)
   geometry.export("results/line1_geometry.csv")

These are post-processing estimates from the written nodes. The solver's own ``Curvature``,
``Tension``, and angle channels remain the authoritative values; the discrete curvature depends
on the output discretisation.

Fatigue damage
--------------

A :class:`~cabledyn.FatigueCurve` gives the cycles to failure ``N = a S^-m`` of a constant range
``S``, with an optional second segment ``(m2, log a2)`` below the range where the two meet. An
S--N curve takes stress ranges in MPa; a T--N curve takes the tension range divided by a reference
breaking strength. The built-in curves carry their source in ``curve.source``:

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Function
     - Curves
   * - :func:`cabledyn.dnv_rp_c203_curve`
     - DNV-RP-C203 steel curves B1 to W3 in air (Table 2-1), in seawater with cathodic protection
       (Table 2-2), and under free corrosion (Table 2-4), with the thickness exponent ``k`` and a
       25 mm reference thickness.
   * - :func:`cabledyn.dnv_os_e301_curve`
     - DNV-OS-E301 studlink and studless chain and stranded and spiral-strand wire rope (stress
       range in MPa), and polyester rope (tension range over MBS, DNVGL-OS-E301 2018).
   * - :func:`cabledyn.api_rp_2sk_curve`
     - API RP 2SK T--N curves for studlink and studless chain, Baldt and Kenter connecting links,
       and wire rope, whose intercept depends on the mean-load ratio ``Lm``.

Check the constants against the edition your design basis names, and build any other curve from
its published constants with :class:`~cabledyn.FatigueCurve`.

:func:`cabledyn.channel_damage` rainflow-counts one channel and sums ``n_i / N(S_i)``
(Palmgren--Miner). ``scale`` converts the channel unit to the curve unit:
:meth:`~cabledyn.FatigueCurve.tension_scale` gives it from the nominal area (S--N) or the
breaking strength (T--N), and :func:`cabledyn.chain_nominal_area` is the DNV two-leg chain area.
Passing ``ultimate_strength`` (in the curve unit) applies the Goodman correction
``S / (1 - S_mean / S_u)`` to cycles with a tensile mean. It is off by default.

.. code-block:: python

   from cabledyn import channel_damage, chain_nominal_area, dnv_os_e301_curve

   curve = dnv_os_e301_curve("studless_chain")
   scale = curve.tension_scale(area=chain_nominal_area(0.185))    # N -> MPa
   damage = channel_damage(history, "FairTen1", curve, scale=scale, start=600.0)
   print(damage.damage, damage.fatigue_life)                       # over the record; years

:func:`cabledyn.damage_along_arc` evaluates every output node of a line from its ``Ten<L>N<J>``
channels. With ``quantity="stress"`` it uses :func:`cabledyn.cable_stress` to recover the stress
``T/A +/- E kappa r`` at the two extreme fibres of a cable component from ``Ten<L>N<J>`` and
``Curv<L>N<J>``, and keeps the larger damage. The curvature is a magnitude, so the recovery does
not follow the rotation of the bending plane.

.. code-block:: python

   from cabledyn import damage_along_arc, dnv_rp_c203_curve

   armour = dnv_rp_c203_curve("B1", "seawater_cp")
   profile = damage_along_arc(
       history, 1, armour, quantity="stress",
       area=2.4e-3, modulus=2.07e11, radius=0.09, arc_length=result.read_static(),
   )
   print(profile.critical_node, profile.maximum_damage)
   profile.plot()

Lifetime damage over sea states
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

:func:`cabledyn.study_sea_state_damage` reads the main output of each named case of a
:func:`cabledyn.run_study` batch, trims it, and evaluates its damage.
:func:`cabledyn.lifetime_fatigue` then weights the cases by their probability of occurrence
``p_i``. The annual damage is ``DFF * sum(p_i * D_i * year / T_i)`` for short-term damage ``D_i``
over a record of ``T_i`` seconds; the lifetime damage is the annual damage times the design life,
and the fatigue life is its inverse.

.. code-block:: python

   from cabledyn import damage_along_arc, lifetime_fatigue, study_sea_state_damage

   # study: the StudyResult of cabledyn.run_study; armour: the curve of the previous example
   states = study_sea_state_damage(
       study, {"hs2_tp8": 0.45, "hs4_tp10": 0.40, "hs6_tp12": 0.15},
       lambda h: damage_along_arc(h, 1, armour, quantity="stress", area=2.4e-3,
                                  modulus=2.07e11, radius=0.09),
       start=600.0,                                  # drop the start-up transient
   )
   life = lifetime_fatigue(states, design_life=25.0, design_factor=10.0)
   print(life.minimum_fatigue_life, life.passed)
   life.export("results/fatigue_by_sea_state.csv")

``design_factor`` defaults to 1: take the design fatigue factor from the governing standard.

Range graphs
------------

A :class:`~cabledyn.RangeGraph` holds the minimum, maximum, and mean of tension, curvature, or bend
moment along a line, with ``plot()`` and ``export()``:

* :func:`cabledyn.read_range_graphs` and :func:`cabledyn.read_range_graph` read the solver-side
  range file ``<root>.Line<L>.range.out`` that the ``LINES`` ``Outputs`` flag ``r`` writes: every
  node of the line over the whole range window, for tension, curvature, bend moment,
  declination, and seabed clearance (see :doc:`outputs`). This is the complete envelope; the
  functions below rebuild envelopes from other files.
* :func:`cabledyn.node_range_graph` builds it from the ``Ten<L>N<J>``, ``Curv<L>N<J>``, or
  ``BendMom<L>N<J>`` channels of a main output over a time window. Node positions come from a
  static profile of the run, a ``{node: arc}`` mapping, or the node numbers. The channels name
  deck nodes; on a line whose mesh the static solve refined, the profile's ``DeckNode`` column
  places them (:ref:`outputs-refined-nodes`).
* :func:`cabledyn.static_range_graph` builds it from a ``.static.out`` profile.
* :func:`cabledyn.element_range_graph` builds it from a cubic-Hermite ``.elements.out`` table:
  the peak curvature or bend moment of each element, where it occurs between the nodes, or the
  element's minimum and maximum axial resultant (``"axial_resultant"``).

.. code-block:: python

   from cabledyn import node_range_graph, static_range_graph

   static = result.read_static()
   dynamic = node_range_graph(history, 1, "curvature", arc_length=static, start=600.0)
   ax = dynamic.plot()
   static_range_graph(static, 1, "curvature").plot(ax=ax, label="static")
   dynamic.export("results/line1_curvature_range.csv")

   from cabledyn import read_range_graph

   envelope = read_range_graph("results/case.Line1.range.out", "tension")
   print(envelope.peak, envelope.peak_location, envelope.time_window)

Design checks
-------------

:func:`cabledyn.bend_check` compares curvature with a cable's minimum bend radius (MBR), in the
style of the DNV-ST-0359 bend requirement: the utilisation ``kappa * MBR`` must not exceed one.
:class:`~cabledyn.BendLimits` holds the manufacturer's storage and dynamic MBRs, and
``condition`` selects which one applies. The source is a main output (``Curv<L>N<J>``, with the
time of the governing curvature), a static profile, or an element table. The resulting
:class:`~cabledyn.BendCheck` reports pass or fail, the location, and the time.

:func:`cabledyn.tension_check` compares line tension with the minimum breaking load (MBL):

* ``standard="API RP 2SK"`` checks ``T_max <= MBL / SF`` with the factors of safety of
  :data:`cabledyn.API_RP_2SK_SAFETY_FACTORS` (for dynamic analysis: intact 1.67, damaged 1.25,
  transient 1.05);
* ``standard="DNV-OS-E301"`` checks ``gamma_mean T_mean + gamma_dyn T_dyn <= 0.95 MBS`` with the
  partial factors of :data:`cabledyn.DNV_OS_E301_PARTIAL_FACTORS` (ULS for intact, ALS for
  damaged, consequence class 1 or 2);
* ``standard="custom"`` takes a ``safety_factor``.

Run the check once on the intact and once on the damaged simulation.

.. code-block:: python

   from cabledyn import BendLimits, bend_check, tension_check

   limits = BendLimits(storage_mbr=2.0, dynamic_mbr=4.0)
   print(bend_check(history, limits, condition="dynamic", line_id=1, arc_length=static).report())
   print(bend_check(static, limits, condition="storage", line_id=1).report())

   intact = tension_check(history, ["FairTen1", "FairTen2", "FairTen3"],
                          breaking_strength=22.3e6)
   damaged = tension_check(damaged_history, ["FairTen2", "FairTen3"],
                           breaking_strength=22.3e6, condition="damaged")
   print(intact.report(), damaged.passed)

The checks use the recorded extremes of the window. A check on the most probable maximum of a
longer exposure needs that extreme first, for example from :func:`cabledyn.fit_gumbel`.

Touchdown time histories
------------------------

:func:`cabledyn.touchdown_history` tracks the touchdown point (TDP) of a line on a flat seabed at
every output time, from a CableDyn ``.Line<L>.p.out`` file, a MoorDyn-F line file, or the
``L<L>N<J>px``/``py``/``pz`` channels of a main output. A node is grounded as in
:meth:`~cabledyn.LineGeometry.touchdown`. Between the last grounded node and the next, the TDP is
placed where the parabola through the last grounded node and the next two nodes, its curvature
limited so that it rises monotonically over the element, crosses ``seabed_z + tolerance`` (the
chord crossing when there is none), so it moves continuously as nodes ground and lift off. The :class:`~cabledyn.TouchdownHistory`
holds the TDP arc length from End A, its coordinates, the layback, and two excursions from a
reference TDP (a static profile, or the first sample): the horizontal excursion, positive towards
the suspended end, and the arc-length excursion. Samples without a touchdown are ``nan``.
The driver computes the same quantities during the run as the ``TDP<L>s``/``x``/``y``/``z``/
``Lay``/``Exc`` channels (see :doc:`outputs`), with ``tolerance`` equal to the contact-onset
height of 1e-6 m. Its ``TDP<L>Grd`` channel adds the grounded length from the grounded end to the
TDP (with End B grounded, the deformed line length less the TDP arc length). It varies continuously
with the TDP and is 0 only when the grounded end node itself is off the seabed or the TDP sits at
that node, for the anchor uplift check.

.. code-block:: python

   from cabledyn import touchdown_history

   tdp = touchdown_history(result.read_line_positions(1), seabed_z=-200.0,
                           tolerance=0.05, reference=static.line(1))
   print(tdp.statistics("excursion"))          # minimum, maximum, mean, metres
   tdp.plot("arc_length")
   tdp.export("results/line1_tdp.csv")

Parameter grids
---------------

:func:`cabledyn.parameter_grid` builds the case mapping that :func:`cabledyn.generate_deck_cases`
and ``cabledyn-deck generate`` take. ``mode="product"`` forms every combination (the last
selector varies fastest); ``mode="zip"`` pairs equally long lists. Cases are named
``<prefix>000``, ``<prefix>001``, and so on.

.. code-block:: python

   from cabledyn import generate_deck_cases, parameter_grid, run_study

   cases = parameter_grid({"option.kBot": [1.0e5, 3.0e5], "section.1.1.length": [540, 550]})
   generate_deck_cases("base.dat", "study/cases", cases)
   result = run_study("study/cases/cases.json", jobs=4, channels=["FairTen1"])

Results at a time
-----------------

:func:`cabledyn.line_positions` returns the node positions of one line as a
:class:`~cabledyn.LinePositions` (``(n_samples, n_nodes, 3)``, in metres) from a per-line position
file, a MoorDyn-F line file, the ``L<L>N<J>p[xyz]`` channels of a main output, a static profile,
or an array. :func:`cabledyn.line_field` returns any per-node or per-segment variable of one line
over time as a :class:`~cabledyn.LineField`; :func:`cabledyn.available_quantities` lists the
names a source records (for example ``tension``, ``curvature``, ``bend_moment``, ``x``, ``z``).

:func:`cabledyn.profile_at` evaluates one variable at a time ``t``, linearly interpolated between
samples or from the nearest sample, and returns an :class:`~cabledyn.ArcProfile` against the
deformed arc length from End A. Node values sit at the node arc lengths and segment values at the
segment mid-arc. A source without positions is placed with ``positions=``: a position source
(evaluated at the same time), a static profile, or a node-to-arc mapping.
:func:`cabledyn.profiles_at` returns several variables at once:

.. code-block:: python

   import cabledyn

   nodes = cabledyn.read_output("run.Line1.p.out")
   tensions = cabledyn.read_output("run.Line1.t.out")
   profile = cabledyn.profile_at(tensions, "tension", 42.0, positions=nodes)
   graph = cabledyn.line_range_graph(tensions, "tension", positions=nodes, start=30.0)

:func:`cabledyn.line_range_graph` builds a :class:`~cabledyn.RangeGraph` of any such variable; a
position history places each node at its window-mean arc length.

Clearance
---------

:func:`cabledyn.seabed_clearance` returns the vertical clearance ``z - z_floor(x, y)`` of every
node at every sample, less an optional ``radius``, above a flat seabed (pass its elevation,
``-WtrDpth``) or a :class:`~cabledyn.Bathymetry` read with :func:`cabledyn.read_bathymetry` from
the deck's ``x y depth`` file (bilinear with its creases rounded, clamped at the grid edges, as
in the solver). It
reproduces the solver's ``Clearance`` range graph. The :class:`~cabledyn.SeabedClearance`
reports the minimum with its time, node, and arc length, a profile at any time, and a range
graph.

:func:`cabledyn.line_clearance` returns the minimum distance between two lines at every sample,
measured segment to segment between their node polylines, with the closest points, their arc
lengths, and the minimum over time. A static line is compared with every sample of the other; two
histories must share their sample times. :func:`cabledyn.clearance_matrix` does this for every
pair of a set of lines. Lines that share an end point have zero distance there.

Summary tables
--------------

:func:`cabledyn.channel_summary` gives per-channel statistics with the time of each extreme.
:func:`cabledyn.line_summary` gives the tension extremes of a line (value, time, and arc length),
its largest curvature and smallest bend radius, and its smallest seabed clearance. Both return
plain frozen dataclasses; :class:`~cabledyn.SummaryTable` collects them (or the records of
:meth:`~cabledyn.StaticProfile.summaries`) and converts to dictionaries, a pandas DataFrame
(``to_dataframe()``, needs pandas), or CSV (``export()``).
