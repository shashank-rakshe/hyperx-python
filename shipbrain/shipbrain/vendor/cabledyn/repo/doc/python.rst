.. SPDX-License-Identifier: Apache-2.0

Python package
==============

The ``cabledyn`` package exposes two intentionally separate workflows:

.. list-table::
   :header-rows: 1
   :widths: 28 72

   * - API
     - Use it when
   * - :class:`cabledyn.CableDynDriver`
     - Python should launch a complete standalone deck through the static
       ``CableDyn_driver.exe`` and read its files
   * - ``CableDyn``
     - a host program needs in-process, step-by-step kinematics-in / loads-out coupling through
       the shared-library C ABI

The first API is the recommended interface for parameter studies, batch execution, notebooks,
and post-processing. It needs the release executable but no CableDyn DLL. The second is for CFD
and custom time integrators and additionally needs a compatible shared library.

Package status and installation
-------------------------------

The source tree is structured as a standards-based Python package with declared metadata,
console entry points, tests, and independently buildable wheel/sdist artifacts. The package is
**not published on PyPI or conda-forge**; install the wheel of a release (:doc:`installation`) or
the current checkout:

.. code-block:: powershell

   py -m pip install .\python

For package development:

.. code-block:: powershell

   py -m pip install -e ".\python[dev]"
   py -m pytest python\tests

NumPy is the only required runtime Python dependency. Native executables are distributed as release
assets rather than embedded in the platform-independent Python wheel. This keeps package
installation predictable and lets a laboratory qualify one exact solver binary separately.
Install optional table and plotting integrations with:

.. code-block:: powershell

   py -m pip install -e ".\python[post]"

Standalone-driver quickstart
----------------------------

Pass the executable explicitly for the most reproducible setup:

.. code-block:: python

   from cabledyn import CableDynDriver

   driver = CableDynDriver(r"C:\CableDyn\CableDyn_driver.exe")
   print(driver.version())

   result = driver.run(
       r"D:\cases\spread_3line_chain.dat",
       r"results\baseline",
       timeout=600,
   )

   history = result.read_main()       # TimeHistory
   static = result.read_static()      # StaticProfile
   time = history.time
   fairlead_tension = history.column("FairTen1")  # N

``result`` retains the executable, absolute deck and output paths, captured ``stdout`` and
``stderr``, return code, the optional static profile, finite-EI element table
(``elements_output``) and modal table (``modes_output``, read with ``result.read_modes()``), and
all requested per-line and per-rod outputs. A result is returned only
for a fully converged analysis: the driver exits non-zero whenever a nonlinear step fails.
Arrays returned by the parser are read-only so post-processing cannot accidentally mutate the
recorded result.

Executable discovery
~~~~~~~~~~~~~~~~~~~~

When no path is passed, discovery follows this fixed order:

#. ``CABLEDYN_DRIVER`` environment variable (full executable path);
#. ``CableDyn_driver.exe`` / ``CableDyn_driver`` on ``PATH``;
#. the development executable ``cabledyn`` on ``PATH``.

For example:

.. code-block:: powershell

   $env:CABLEDYN_DRIVER = "C:\CableDyn\CableDyn_driver.exe"
   py -c "from cabledyn import CableDynDriver; print(CableDynDriver().version())"

Run semantics and safety
~~~~~~~~~~~~~~~~~~~~~~~~

By default, :meth:`cabledyn.CableDynDriver.run` uses the deck directory as the process working
directory. That preserves relative references to WaterKin, motion, bathymetry, and constitutive
files. A
relative output root is also resolved there, and its parent directory is created.

Existing results are protected. If any file for the output root already exists, ``run`` raises
``FileExistsError``. Replace a known result set only by saying so explicitly:

.. code-block:: python

   result = driver.run("model.dat", "results/case01", overwrite=True)

With ``overwrite=True`` the previous files are moved aside (into a temporary
``.<stem>.previous-*`` directory beside them) while the solver runs and deleted only after the
new run succeeds. If the rerun fails for any reason, including an interruption, the partial new
files are removed and the previous results are restored. ``timeout`` must be ``None`` or a
finite, positive number of seconds; anything else raises ``ValueError`` before the solver starts.

The wrapper invokes the executable without a shell, checks exit status, requires the primary
``.out``, and parses it before returning. It raises:

* :class:`cabledyn.DriverNotFoundError` when executable discovery fails; and
* :class:`cabledyn.DriverExecutionError` on timeout, a native exit code of 1 (invalid input) or 2
  (initialisation or solution failure), or a missing or malformed main output (a native exit
  code of 0 with an ``.out`` that does not parse).

:class:`cabledyn.OutputFormatError`, for missing headers, short rows, overflow markers,
non-finite values, or otherwise malformed tables, is raised by :func:`cabledyn.read_output` and
by the ``read_*`` methods of the returned result, not by ``run`` itself.

``DriverExecutionError`` carries ``returncode``, ``stdout``, and ``stderr`` so a batch system can
archive the native diagnostic.

Typed result objects
--------------------

:func:`cabledyn.read_output` accepts main histories, static profiles, per-line tables, and modal
tables. It
recognises both current main output (title + channel row) and tables with a units row in the
style of OpenFAST (maintained by NLR, the National Laboratory of the Rockies, formerly NREL):

.. code-block:: python

   from cabledyn import read_output

   history = read_output("results/baseline.out")
   profile = read_output("results/baseline.static.out")

   line_1 = profile.line(1)
   print(profile.line_ids)
   print(profile.summary(1))

Channel lookup is exact and case-sensitive. Tensions are N, positions are m, and time is s; see
:doc:`outputs` for the full contract.

The reader returns a :class:`cabledyn.TimeHistory` for a ``Time``/``Time(s)`` table,
a :class:`cabledyn.StaticProfile` for the full ``LineID``/``Node``/``ArcLength`` static table,
and a generic :class:`cabledyn.OutputTable` for static per-line node or segment tables. Dynamic
``Line<L>.p.out`` and ``Line<L>.t.out`` files become :class:`cabledyn.LineNodeHistory` and
:class:`cabledyn.LineSegmentHistory`, respectively. Arrays are read-only. Time must be finite and
strictly increasing; line and node identifiers must be positive integers; and arc length must be
monotonic within each line.

Natural modes
~~~~~~~~~~~~~

A deck that sets ``nModes`` writes ``<root>.modes.out``, which holds two tables (see
:doc:`outputs`). :func:`cabledyn.read_output` reads both into one
:class:`cabledyn.NaturalModes`: the object is the frequency table, and its ``shapes`` attribute is
the mode-shape table, a :class:`cabledyn.ModeShapes`. Each table is an
:class:`cabledyn.OutputTable`, so ``column``, ``unit`` and ``to_dataframe`` work on either; an
export of the object writes the frequency table only.

.. code-block:: python

   from cabledyn import read_output

   modes = read_output("results/baseline.modes.out")   # or result.read_modes()

   print(modes.line_ids)
   print(modes.periods(1))                 # s, by mode
   print(modes.frequencies(1))             # Hz, by mode

   xyz = modes.shapes.positions(1)         # static node positions, (n_nodes, 3), m
   shape = modes.shapes.displacements(1, 2)    # mode 2, (n_nodes, 3), largest node 1
   line_2 = modes.line(2)                  # both tables of one line

A file with a line restrained in torsion has the columns ``PolarShare`` and ``dTwist`` for every
line, and ``has_twist`` is true. ``modes.polar_shares(1)`` and ``modes.shapes.twist(1, mode)``
return them, and ``modes.torsional_modes(1)`` the modes above a polar share of 0.5, which are
scaled to a unit largest twist instead of a unit largest displacement. On a file without the
columns these return zeros and no modes, as on a line without torsion.

A negative eigenvalue has a negative ``Frequency`` and ``Omega`` and a ``Period`` of 0. A line
without free nodes has no modes and no rows, so it is absent from ``line_ids``. The reader refuses
a file without a mode-shape table, and one whose two tables do not hold the same modes of the same
lines.

Statistics, range graphs, and geometry
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Select an inclusive physical-time interval and compute auditable population statistics:

.. code-block:: python

   window = history.period(start=600.0, stop=4200.0)
   fair = window.statistics("FairTen1")[0]
   print(fair.minimum, fair.maximum, fair.mean, fair.standard_deviation, fair.rms)

``statistics()`` accepts one channel, an iterable of channels, or no argument for every non-time
channel. Each result records the unit and sample count. Ordinary summary statistics are not
presented as fatigue results.

The static profile is CableDyn's range-graph source and remains keyed by ``LineID``
so different physical lines cannot be joined accidentally:

.. code-block:: python

   engineering = profile.summary(4)
   print(engineering.maximum_tension)
   print(engineering.maximum_curvature)
   print(engineering.minimum_bend_radius)
   print(engineering.maximum_bend_moment)

   profile.plot("Curvature", line_id=4)
   profile.plot_geometry(plane="xz", line_id=4)
   history.plot("FairTen1", start=600.0)

Plotting requires the ``plot`` or ``post`` optional dependency. Methods return a matplotlib axes
object, leaving plot styling and file export under user control.

Rainflow cycles and damage-equivalent ranges
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CableDyn implements the one-pass Downing--Socie rainflow convention used by ASTM E1049 and
`NREL MLife <https://www.nrel.gov/docs/libraries/wind-docs/mlife-theory.pdf>`_. A cycle records its
load **range**, mean, zero-based start/end indices in the analysed window, physical start/end
times, and weight. Closed cycles have weight 1.0; unclosed record-residual cycles have weight 0.5.
Consecutive equal samples are collapsed before endpoint-inclusive reversal extraction.

Compute an uncorrected short-term damage-equivalent load range (DEL) with explicit assumptions:

.. code-block:: python

   fatigue = history.fatigue(
       "FairTen1",
       start=600.0,
       stop=4200.0,
       wohler_exponent=3.0,
       reference_frequency=1.0,
       bins=32,
   )
   print(fatigue.damage_equivalent_range, fatigue.unit)
   print(fatigue.cycle_count, fatigue.reference_cycles)
   fatigue.plot_histogram()
   fatigue.export_cycles("results/fairten1_exact_cycles.csv")
   fatigue.export_histogram("results/fairten1_cycles.csv")

For cycle ranges :math:`R_i`, weights :math:`n_i`, Woehler exponent :math:`m`, and explicit
reference count :math:`N_\mathrm{ref}`, the reported value is

.. math::

   R_\mathrm{DEL} =
   \left(\frac{\sum_i n_i R_i^m}{N_\mathrm{ref}}\right)^{1/m}.

Supply exactly one of ``reference_cycles`` or ``reference_frequency``; frequency is multiplied by
the selected record duration. The integer/edge ``bins`` input affects only the optional weighted
histogram. DEL always uses every exact, unbinned rainflow range. Cycle/histogram exports are atomic
and cannot replace their native source result, even when overwrite permission is explicit.

The DEL applies **no mean-stress correction** and is not a Miner damage or a fatigue life.
Absolute damage needs a component S--N or T--N curve, and :doc:`python_postprocessing` describes
it: built-in DNV and API curves, Palmgren--Miner damage with an optional Goodman correction,
damage along the arc, and lifetime damage over the sea states of a study. Record length, transient
removal, sampling rate, output decimation, and reference-cycle selection remain part of the
engineering assessment.

Power spectra, moments, and coherence
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The spectral layer uses a one-sided Welch power spectral density (PSD) for real, uniformly
sampled histories. Configuration is explicit: ``segment_length`` is mandatory; the default
window is the periodic (DFT-even) Hann window, overlap is 0.5, detrending removes each segment's
constant mean, and the FFT length equals the segment length unless requested otherwise. CableDyn
does not silently interpolate, resample, shorten a segment, or choose a record window.

.. code-block:: python

   spectrum = history.spectrum(
       "FairTen1", start=600.0, stop=4200.0,
       segment_length=4096, overlap=0.5,
   )
   print(spectrum.frequency_resolution)       # Hz, bin spacing
   print(spectrum.moment(0), spectrum.moment_unit(0))  # integrated power and unit
   print(spectrum.dominant_peaks(3))          # bin-centred peaks, no interpolation
   spectrum.export("results/fairten1_psd.csv")
   spectrum.plot(logarithmic=True)

For window samples :math:`w_j`, sample frequency :math:`f_s`, and unnormalised real FFT
:math:`X_k`, each segment density is scaled by
:math:`|X_k|^2/(f_s\sum_j w_j^2)`. Interior positive-frequency bins are doubled; DC and, for an
even FFT, Nyquist are not. Segment periodograms are arithmetically averaged. If the source
channel unit is N, the density unit is ``N^2/Hz``. A spectral moment over the selected bins is

.. math::

   m_n = \int_{f_\mathrm{min}}^{f_\mathrm{max}} f^n S(f)\,df,

evaluated as a discrete full-bin density sum. DC and Nyquist receive full bin weight, preserving
mean-square power; this is not trapezoidal interpolation between bin centres. Negative-order
moments fail if their band contains DC.
Zero-padding refines bin spacing but does not add physical resolution. Reported dominant
frequencies are positive-density local-maximum FFT-bin centres; flat/zero spectra have no peak,
and CableDyn does not invent sub-bin precision.

Magnitude-squared coherence uses the same segments, window, overlap, FFT, and detrending for both
channels:

.. math::

   C_{xy}(f) = \frac{|P_{xy}(f)|^2}{P_{xx}(f)P_{yy}(f)}.

.. code-block:: python

   coherence = history.coherence(
       "FairTen1", "FairTen2", start=600.0, stop=4200.0,
       segment_length=4096,
   )
   coherence.export("results/fairlead_coherence.csv")

At least two complete segments are required: a single-segment estimate is identically coherent
and is not useful evidence. Bins where either auto-spectrum is below the documented relative
power floor are ``NaN`` with ``valid=False`` in memory and blank with ``valid_[-] = 0`` in the
CSV, rather than being reported as zero or one. Coherence is an estimator, not causality.
Segment length, overlap, record duration, stationarity, confidence limits, and multiple-comparison
effects remain engineering decisions.
The current API does not calculate confidence intervals.

Dynamic line range graphs
~~~~~~~~~~~~~~~~~~~~~~~~~

Request ``p`` and/or ``t`` in a LINE's ``Outputs`` field to retain its dynamic node positions and
segment tensions. A completed :class:`cabledyn.DriverResult` discovers those files by line id:

.. code-block:: python

   print(result.line_ids)
   positions = result.read_line_positions(4)  # LineNodeHistory for a dynamic run
   tensions = result.read_line_tensions(4)    # LineSegmentHistory for a dynamic run

   xyz = positions.coordinates(725.125)       # shape (n_nodes, 3), metres
   s = positions.arc_length(725.125)           # deformed chord coordinate from End A
   tension = tensions.tensions(725.125)        # one value per segment, N

   envelope = tensions.spatial_statistics(start=600.0, stop=4200.0)
   print(envelope.minimum, envelope.maximum, envelope.mean)

Snapshots use linear interpolation between recorded output rows and reject extrapolation. Period
statistics use the recorded samples in the inclusive requested interval; they do not invent
samples at the interval limits. ``SpatialStatistics`` also carries per-segment population standard
deviation and RMS arrays, the sample count, unit, and one-based segment ids. This makes the mapping
auditable and prevents values from adjacent segments being collapsed into one global extreme.

The matching range-graph views are:

.. code-block:: python

   positions.plot_geometry(725.125, plane="xz")
   tensions.plot_range(725.125)
   tensions.plot_envelope(600.0, 4200.0)

The solver's own range file (``<root>.Line<L>.range.out``, LINES flag ``r``) is read by
:func:`cabledyn.read_range_graphs`; on a line restrained in torsion it also returns the
``"torque"`` (N·m) and ``"twist"`` (deg, from End A) envelopes, and :func:`cabledyn.read_output`
attaches those units to the ``Torq<L>N<J>``, ``Twist<L>N<J>`` and ``Twist<L>`` channels.

DataFrame and pyDatView interoperability
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``table.to_dataframe()`` returns a pandas DataFrame with unit-labelled columns. Native
``.static.out`` files retain CableDyn's multi-line engineering schema; not every generic plotting
program recognises that schema automatically. Create a single-header, unit-labelled CSV or
tab-separated file without changing the scientific data:

.. code-block:: python

   profile.line(4).export_pydatview("results/line4_static.csv")
   history.export_pydatview("results/history.csv")

Exports are atomic and refuse to overwrite an existing file unless ``overwrite=True``. Static
exports do not invent a time axis. CSV is selected by the ``.csv`` suffix; other suffixes are
tab-separated by default.

Command-line wrapper
--------------------

Installing the package adds four commands — ``cabledyn-run``, ``cabledyn-post``,
``cabledyn-deck``, and ``cabledyn-study`` — whose complete options and exit codes are in
:doc:`cli`. ``cabledyn-run`` is useful in portable Python environments while retaining the
wrapper's validation and path handling:

.. code-block:: powershell

   cabledyn-run model.dat results\case01 --executable C:\CableDyn\CableDyn_driver.exe

Use ``--overwrite`` only when the existing result set is intentionally replaceable.

The command prints the absolute main-output path on success and returns a nonzero status with a
diagnostic on failure. The native interface remains available directly; see
:doc:`standalone_driver`.

Use ``cabledyn-post`` for shell-based inspection and conversion:

.. code-block:: powershell

   cabledyn-post summary results\baseline.out --start 600 --stop 4200
   cabledyn-post summary results\baseline.static.out --line 4
   cabledyn-post export results\baseline.static.out line4.csv --line 4
   cabledyn-post plot results\baseline.static.out Curvature --line 4 --output curvature.png
   cabledyn-post plot results\baseline.static.out geometry --line 4 --plane xz
   cabledyn-post plot results\case.Line4.p.out geometry --time 725.125 --plane xz
   cabledyn-post plot results\case.Line4.t.out Tension --time 725.125
   cabledyn-post plot results\case.Line4.t.out Tension --start 600 --stop 4200 --output envelope.png
   cabledyn-post fatigue results\baseline.out FairTen1 --m 3 `
     --reference-frequency 1 --start 600 --stop 4200 --bins 32 `
     --cycles-output results\fairten1_exact_cycles.csv `
     --histogram-output results\fairten1_cycles.csv

Programmatic deck construction
------------------------------

``DeckWriter`` creates a sectioned CableDyn deck without copying MoorDyn's Python object model.
It follows CableDyn's FEM line/section vocabulary: lines own ordered material/mesh sections, while
boundary points describe attachment conditions.

.. code-block:: python

   from cabledyn import CableDynDriver, DeckWriter

   deck = DeckWriter(title="single chain")
   deck.add_line_type(
       "chain", diam=0.252, mass=390.0, ea=1.674e9,
       ba=0.0, ei=0.0, cdn=2.0, cdt=0.4, can=0.8, cat=0.25,
   )
   deck.add_point(1, "Coupled", 0.0, 0.0, -14.0)
   deck.add_point(2, "Fixed", 400.0, 0.0, -50.0)
   deck.add_line(1, node_a=1, node_b=2, outputs="pt")
   deck.add_section(line_id=1, line_type="chain", length=410.0, num_segs=41)
   deck.set_option("50.0", "WtrDpth", "Water depth (m)")
   deck.set_option(False, "adaptive_mesh", "Enable adaptive mesh refinement {True, False}")
   deck.add_output("FairTen1")
   path = deck.write("generated.dat")

   result = CableDynDriver().run(path, "results/generated")

``DeckWriter`` supplies the standard CableDyn banner, capitalises Python Boolean values, and
writes each output channel on its own double-quoted row. ``set_option(value, keyword,
description)`` follows the deck's ``value keyword`` column order and accepts only native scalar
option keywords, so a call with value and keyword swapped raises instead of writing a wrong row.
The description is optional; giving meaning, units, and choices keeps generated decks
self-documenting. Names and channels must be single plain tokens, and the title and descriptions
must not contain ``---``, ``#``, or ``!`` (they would start a section or a comment). ``text()`` and
``write()`` validate the complete deck with ``DeckFile`` (pass ``caller_driven=True`` for an
OpenFAST deck) and raise ``DeckFormatError`` before anything is written; the native solver remains
the authority on physics that needs a solve.

For a finite-EI line, ``add_end_connection`` writes a pinned end, a finite rotational spring, or
an exact rigid tangent-direction connection. The direction uses CableDyn's End-A-to-End-B
convention and is normalised before writing:

.. code-block:: python

   deck.add_end_connection(
       line_id=1, end="EndA", stiffness=2.0e5, direction=(-0.25, 0.0, -0.97),
   )

The referenced line and finite-EI topology are checked when ``text()`` or ``write()`` validates
the completed deck.

Build and edit decks as objects
-------------------------------

:class:`cabledyn.DeckModel` holds a deck as linked Python objects: line types, rod types,
bodies, rods, turbines, points, lines with their ordered sections, the ``END CONNECTIONS``,
``EQUIVALENT BUOYANCY``, ``ATTACHMENTS``, ``SYROPE IC``, ``FAILURE``, ``CONTROL`` and
``EXTERNAL LOADS`` rows, options, and output channels. Rows refer to other objects by reference,
so renaming a point, line, body, rod, or type keeps every row that uses it consistent, and output
channels that name the object by id (``FairTen<L>``, ``Point<P>pz``, ``Body<N>Px``, ...) are
renamed with it.

.. code-block:: python

   from cabledyn import DeckModel

   model = DeckModel.new(title="single chain")
   chain = model.add_line_type("chain", diam=0.252, mass=390.0, ea=1.674e9,
                               ba=-1.0, cdn=1.37, cdt=0.64, can=1.0)
   fairlead = model.add_point(1, "Coupled", 0.0, 0.0, 0.0)
   anchor = model.add_point(2, "Fixed", 400.0, 0.0, -50.0)
   line = model.add_line(1, fairlead, anchor, chain, length=410.0, num_segs=41)
   model.add_section(line, "chain", 20.0, 2)          # a second section at End B
   model.options.set("WtrDpth", 50.0, description="Water depth (m)")
   model.outputs.add("FairTen1", "AnchTen1")
   model.save("chain.dat")

   model = DeckModel.load("examples/lazy_wave_vessel_motion.dat")
   model.lines[1].sections[0].length += 5.0
   model.rename(model.points[1], 10)
   model.set_vessel_motion("motion.txt", reference=(0.0, 0.0, 0.0))
   model.save("variant/deck.dat")                      # relative paths are rebased (see below)

Objects are plain dataclasses whose fields can be edited in place. Structural edits go through the
model: ``add_*`` methods accept an object or its id or name, ``rename`` changes an id or a type
name, and ``remove`` refuses to delete an object that is still in use and raises
:class:`cabledyn.DeckReferenceError`, which lists what still uses it. Pass ``cascade=True`` to
remove those as well: the lines on a removed point, the rows of a removed line, and the output
channels that name it. ``references(obj)`` lists them without removing anything. ``options`` is
alias-aware (``dt`` and ``dtM`` are one option; ``set`` replaces, ``add`` appends a ``wavetrain``
row), and ``set_motion_file``, ``set_vessel_motion``, and ``set_vessel_rao`` keep the three
prescribed-motion sources exclusive.

The model neither parses nor validates text itself. ``load`` reads through
:class:`cabledyn.DeckFile`, and ``validate``, ``to_text``, ``to_deck_file``, and ``save`` render
canonical deck text and check it with the same rules (pass ``caller_driven=True`` for an OpenFAST
deck). Line numbers in validation errors refer to the text from ``to_text``. The canonical text
drops comments and alignment; it writes LINE TYPES in CableDyn column order, 9-column POINTS, and
4-column LINES plus SECTIONS (a line loaded from a 7-column MoorDyn row keeps that form while it
has one section). Every example deck round-trips through the model with its meaning unchanged.
``save`` leaves the model unchanged and, by default, rewrites relative ancillary paths so they
resolve from the target folder.

:class:`cabledyn.DeckFile` remains the tool for small edits that must keep the source text byte
for byte, and :class:`cabledyn.DeckWriter` the minimal append-only writer for simple line decks.
All three validate through ``DeckFile``.

Read, edit, and generate existing decks
---------------------------------------

:class:`cabledyn.DeckFile` is the loss-aware counterpart to ``DeckWriter``. It reads an existing
production deck with the native reader's rules and preserves untouched rows, comments, bytes that
are not valid UTF-8, recognised native optional sections, ordering, and quoted tokens
byte-for-byte:

* Records end at ``\r\n``, ``\n``, or ``\r``; ``#``, ``!``, and a whitespace-led ``--`` start a
  comment. A record longer than 512 characters fails unless the excess is comment or blanks.
* Unknown dashed section headings fail closed; native aliases are accepted, and a repeated heading
  continues its section. A table row with no token that reads as a number is a column-name or
  units row; every other row is data, whatever its first word.
* Rows split on spaces and tabs (a quoted value is one token even when it contains spaces) and
  are read like the native list-directed ``READ``: text columns (names, point types, EA/BA
  strings, output flags) may be quoted and must be quoted when they contain ``/``, ``,``, or
  ``;``. The LINE TYPES EA column is read whole, so an unquoted ``SYROPE:<path>|alpha|beta`` may
  contain ``/``; every other table token is at most 64 characters. Numeric columns must be
  unquoted Fortran numbers (``1.5E3``, ``1.5D3``, and ``1.5+3`` are accepted; ``1_500``, repeat
  counts such as ``2*0.0``, and integers beyond 32 bits are rejected). OUTPUTS rows split on
  spaces, tabs, and commas with quotes removed; channel names are at most 64 characters, and
  ``Con<P>p{x,y,z}`` is an alias of ``Point<P>p{x,y,z}``. A channel requested twice is
  rejected, including through a case, zero-padded id, or alias spelling of the same quantity
  (``FairTen01``/``fairten1``, ``FairAngle1``/``FairDecl1``, ``Con2pz``/``Point2pz``). An option
  row is read as ``value keyword``; any commentary after the keyword and a description after a
  whitespace-delimited ``-`` are ignored.

Validation also repeats the deterministic native finaliser checks that need no solve:
cross-option dependencies and ranges; constitutive ranges (viscoelastic and Syrope EA/BA,
finite-EI section properties); positive Diam/EA and non-negative EI of used line types; the
net-buoyancy check that
requires a dynamic finite-EI line type for a section whose dry mass does not exceed its displaced
water mass (after equivalent-buoyancy conversion); point-type vocabulary, with FAST.Farm
``Turbine<J>``/``T<J>`` points accepted only on the caller-driven route; finite-EI line-end
connection syntax and supported topology; BODY and ROD vocabulary, inertia, geometry, and
attachment cardinality; equivalent-buoyancy uniqueness; FAILURE/CONTROL references; Syrope
initial-state ownership; OUTPUT channel syntax, object ids, and node bounds; and, on the
standalone route, that no Fixed point lies below a flat ``WtrDpth`` seabed (to within
``1e-6*max(1 m, WtrDpth)``). Ancillary files (motion, WaterKin, bathymetry, Syrope curves) and
nonlinear-solve requirements are checked by the native initialisation path, as is the anchor
check against a ``bathymetryFile`` seabed or a host-supplied depth. A deck without ``WtrDpth`` or
``bathymetryFile`` is valid and solves suspended.

Validation defaults to the standalone-driver route. Consequently, a dynamic standalone deck must
declare both ``dtM`` and ``TMax``, and active friction, bodies, rods, Connect/Free points, and
finite-EI sections require that marching clock. OpenFAST owns the march instead. Select the native
caller-driven contract explicitly when editing or generating an OpenFAST deck:

.. code-block:: python

   coupled = DeckFile.read("CableDyn_UMaine.dat", caller_driven=True)
   cases = generate_deck_cases(
       "CableDyn_UMaine.dat",
       "generated/openfast",
       {"baseline": {"option.dtM": 0.025}},
       caller_driven=True,
   )

The command-line equivalent is ``cabledyn-deck validate CableDyn_UMaine.dat --caller-driven``;
the same flag is available on ``show``, ``set``, and ``generate``. Generated ``cases.json`` files
record this route choice. The flag does not relax route-independent requirements: motion files,
deck-owned currents, and deck-owned waves still require ``dtM`` exactly as in the native finaliser.

.. code-block:: python

   from cabledyn import DeckFile

   deck = DeckFile.read("examples/chain_catenary_r3_100m.dat")
   deck.set_option("WtrDpth", 120.0)
   deck.set_point(2, z=-5.0)
   deck.set_line_type("chainR3", ea=1.70e9)
   deck.set_section(1, occurrence=1, numsegs=70)
   deck.write("cases/deeper_finer.dat")

Edits are transactional: if a new value breaks any of the checks above, the in-memory document is
restored to its preceding valid state and ``DeckFormatError`` reports the problem as
``edited copy of <deck>:<line>``. An edited row is rendered with single spaces between its data
tokens; its indentation and everything after its last data token (option commentary,
description, inline comment) are kept. The error contract is:

* ``DeckFormatError`` (a ``ValueError``): the deck, as read or as it would be after the edit,
  violates the native contract.
* ``KeyError``: a selector or editor names a record, field, or option the deck does not contain,
  including a column that the addressed row does not have.
* ``ValueError``: a malformed selector (for example a non-integer id), two selectors in one batch
  that address the same field or option, or a value that cannot be written as one native token
  (``None``, whitespace, quotes, ``#``, ``!``, ``---``, containers).
* ``TypeError``: an argument of the wrong type, such as a non-Boolean ``caller_driven``.

Use stable selectors to generate traceable studies:

.. code-block:: python

   from cabledyn import generate_deck_cases

   cases = generate_deck_cases(
       "examples/chain_catenary_r3_100m.dat",
       "generated/catenary-study",
       {
           "depth_150": {"option.WtrDpth": 150.0},
           "mesh_70": {"section.1.1.NumSegs": 70},
       },
   )

Selectors are ``option.KEY``, ``point.ID.FIELD``, ``line_type.NAME.FIELD``,
``section.LINE_ID.OCCURRENCE.FIELD``, and ``end_connection.LINE_ID.END.FIELD``. Field names and
option keywords are case-insensitive (option aliases such as ``g``/``gravity`` name the same
option), and the last row of a repeated option is the one edited, as the native reader uses the
last row. A line-type name may itself contain periods; for ``line_type.chain.R3.ea``, the final
period separates the field and ``chain.R3`` remains the name. Section occurrences count a line's
sections from End A to End B in file order. A line described by a stock 7-column LINES row has
that row as its only section (combining it with SECTIONS rows is rejected, as natively), edited
with the fields ``linetype``, ``nodea``, ``nodeb``, ``length``, ``numsegs``, and ``outputs``.
Supply a JSON array (or a Python tuple/list) for a multi-value option such as the keyword-first
``dynamic_solver rel_tol abs_tol max_iter backtracks [rho_inf]`` row.

A case mapping is applied as one transaction: every selector is resolved against the source deck,
so coordinated renames of an identifier and its references work, and the final deck is validated
once. The generated ``cases.json`` records the source deck and its SHA-256, source directory,
route (``caller_driven``), exact changes, generated paths, working directories, and generated
SHA-256 hashes. Known relative ancillary references (Syrope constitutive data, WaterKin, motion,
and bathymetry files) are rewritten relative to each generated deck, honouring native
last-row-wins semantics (a later ``0``/``none`` row keeps a path option disabled). Pass
``GeneratedCase.working_directory`` as ``cwd`` when launching a case. OPTIONS paths must not
contain spaces after rebasing (a Syrope settings path may; it is written quoted), and every
rebased row must fit the native 512-character record; otherwise generation fails before writing
anything. A case that would replace the source deck (also
through a hard link) is refused. Decks and manifests are replaced atomically and receive
the default permissions of a newly created file.

The MoorDyn-C kinematics files are read by fixed name from the folder of the deck being run:
``3 WaveKin`` reads ``wave_elevation.txt``, ``7 WaveKin`` reads ``wave_frequencies.txt`` and
``1 Currents`` reads ``current_profile.txt``, ``2 Currents`` ``current_profile_dynamic.txt`` and
``5 Currents`` ``current_profile_4d.txt``. ``generate_deck_cases`` copies these files next to
the generated decks, and ``cases.json`` records their SHA-256 under ``companion_files``;
``DeckModel.save(rebase=True)`` copies them too.

``caller_driven=True`` checks a deck against the rules of the OpenFAST coupling route
(``CompMooring = 5``); the C API uses the standalone rules. On that route a deck ``waves`` or
``wavetrain`` row is rejected, and so is a deck ``current`` on a deck with finite-EI lines,
Rigid6 bodies, rods or ``Turbine<J>`` points. Whether any other deck ``current`` is kept depends
on the host: OpenFAST keeps it as a steady current when SeaState carries no waves or current and
rejects it otherwise, at initialisation.

On the command line, ``cabledyn-deck set DECK OUTPUT SELECTOR VALUE`` parses ``VALUE`` as JSON
(number, string, Boolean, or list) and otherwise as a plain string; negative numbers such as
``-1e-3`` are taken as values, and JSON ``null`` or objects are rejected. ``cabledyn-deck
generate`` rejects case specs with duplicate keys.

Batch execution and study records
---------------------------------

Run the generated ``cases.json`` directly after case generation:

.. code-block:: python

   from cabledyn import run_study

   study = run_study(
       "generated/catenary-study/cases.json",
       executable=r"C:\CableDyn\CableDyn_driver.exe",
       output_directory="generated/catenary-study/results",
       jobs=4,
       channels=["FairTen1", "AnchTen1"],
       start=600.0,
       stop=4200.0,
       timeout=1800.0,
   )
   if not study.passed:
       for case in study.failed_cases:
           print(case.name, case.status, case.error)

``run_study`` verifies the source-deck hash, every generated-deck hash, safe unique case names,
the executable hash, argument ranges, and output-directory policy before dispatch. Independent
cases may run as separate native processes with ``jobs > 1``. Results are always returned and
written in the original manifest order, not completion order. This is process-level concurrency;
it does not change CableDyn's numerical settings or make one solver instance multithreaded.

One failed case does not cancel the remaining cases. The final status distinguishes:

* ``completed`` — native exit zero, which the driver reserves for a converged analysis;
* ``failed`` — the driver did not complete, could not be launched, or the wrapper failed; and
* ``postprocess_failed`` — native execution completed but its selected result window/channel could
  not be summarised safely.

The output directory contains ``study.json``, ``summary.csv``, native result files, and separate
``.stdout.log`` / ``.stderr.log`` files for every case. ``study.json`` records the case-manifest
hash, solver path/version/hash, UTC start and finish, run controls, artifacts, elapsed wall time,
return code, convergence disposition, and diagnostic. ``summary.csv`` has one row per selected
main-output channel and case with sample count, minimum, maximum, mean, population standard
deviation, and RMS. Failed cases retain a status row even though no statistics exist. Existing
study directories are protected unless ``overwrite=True`` is explicit.

The command-line form has the same contract:

.. code-block:: powershell

   cabledyn-study generated\catenary-study\cases.json `
     --executable C:\CableDyn\CableDyn_driver.exe `
     --output-directory generated\catenary-study\results `
     --jobs 4 --channel FairTen1 --channel AnchTen1 `
     --start 600 --stop 4200 --timeout 1800

Exit code ``0`` means every case completed and converged. Exit code ``1`` means the complete study
record was written but at least one case failed. Exit code ``2`` means configuration or
provenance preflight failed. Exit code ``3`` means the cases ran but ``summary.csv`` or
``study.json`` could not be written (:class:`cabledyn.StudyOutputError` in the Python API). This
follows the useful unattended-batch principle that one numerical
failure should not erase evidence from the other cases.

In-process coupling API
-----------------------

Build ``cabledyn_shared`` before using the in-process API. The library is located in this order:

1. ``CABLEDYN_LIBRARY``, an exact path to the DLL or shared object;
2. the installed package directory, for a distribution that bundles the library; and
3. the CMake build tree of a source checkout: ``build/bin`` and ``build`` for a
   single-configuration generator, or ``build/bin/<Config>`` and ``build/<Config>`` for the
   ``Release``, ``RelWithDebInfo``, ``MinSizeRel``, and ``Debug`` configurations.

When more than one configuration contains a library, set ``CABLEDYN_BUILD_CONFIG`` to the intended
configuration; discovery fails closed rather than selecting a possibly stale binary. The
self-contained ``build/runtime`` bundle is a copy and is loaded only through ``CABLEDYN_LIBRARY``.
Only the current platform's library names are considered, and two library names in one directory
(for example GNU ``libcabledyn.dll`` beside IFX ``cabledyn.dll``) are rejected as ambiguous. On
Windows the loader registers the library's directory and the build tree's staged runtime
directories so the GNU and OpenBLAS runtime DLLs resolve without changing ``PATH``.

Only accessing ``CableDyn`` (or ``abi_version``, ``abi_minor``, ``library_path``,
``version_string``) loads the
library, so standalone-driver users are unaffected if it is absent. The exception classes,
including :class:`cabledyn.CableDynError` and :class:`cabledyn.ConvergenceError`, are always
importable. Deck paths are passed to the Fortran runtime, which on Windows opens files through the
active ANSI code page; a path that code page cannot represent is rejected with ``ValueError``.

.. code-block:: python

   import numpy as np
   from cabledyn import CableDyn

   with CableDyn("mooring.dat") as model:
       q, v, a = model.get_coupled_motion()
       for _ in range(100):
           model.step(0.1, q, np.zeros_like(v), np.zeros_like(a))
           loads = model.calc_output()

``step`` returns the Newton iteration count. A step that fails outright raises
:class:`cabledyn.CableDynError` and leaves the model at the start of the step. A step that ends
without meeting the Newton tolerance raises :class:`cabledyn.ConvergenceError`, which carries
``n_iter`` and ``stalled``; the model has then already advanced to ``t + dt`` with its best
iterate, so retrying the same step would advance time twice. ``dt`` must be a finite real number
of at least ``1e-100``, and array arguments must be real-valued: a string, complex, or boolean ``dt`` and a
complex or non-numeric array raise ``TypeError`` before the library is called. Calls on one
``CableDyn`` instance are serialised by an internal lock; separate instances may run on separate
threads. Deck initialisation is serialised inside the library, so instances created from many
threads at once (even from the same deck) are initialised one after another, while their
``step`` calls run concurrently. The library runs OpenBLAS with one thread by default; the
environment variable ``CABLEDYN_BLAS_THREADS`` changes that (:doc:`capi`).

Array ordering is defined in :ref:`capi:Calling conventions`; frames, fluid fields, and
lifecycle rules are defined in :doc:`coupling_boundary`. Use this API only when the Python
process owns time integration; use ``CompMooring = 5`` for OpenFAST (:doc:`openfast`). The Python
class covers deck initialisation, raw-array lines, the coupled step/output cycle and the load
Jacobians (see `Raw-array lines and load Jacobians`_).

A deck with finite-EI lines, ``BODIES`` or ``RODS`` runs on the coupled aggregate and needs
``dtM``; other decks run on the point route. Decks with deck waves, a ``motionFile`` or vessel
motion are rejected in-process (they run in the standalone driver): motion enters through the
coupled kinematics of every step. A steady deck current is marched in-process, in the static
start and in every step. Other moving water comes from the host, at the nodes of every line:

.. code-block:: python

   model = cabledyn.CableDyn()
   model.set_host_fluid()                  # before the initialization
   model.init_deck_rotating(deck)

   def field(t):
       xyz = model.fluid_node_positions()  # (3, n), the committed positions
       velocity, acceleration, elevation = my_sea(xyz, t)
       model.update_fluid_fields(velocity, acceleration, elevation)

   field(0.0)                              # the start acceleration
   for i in range(1, steps + 1):
       t = i * dt
       field(t)                            # held over the step
       model.step(dt, q(t), v(t), a(t))

``examples/python/step_in_moving_water.py`` is a complete script of this loop.

``velocity`` is the whole ambient velocity, current and waves together. The field of a step to
``t + dt`` is evaluated at ``t + dt`` at the step-start positions and held over the step, as in
the standalone march and in OpenFAST; :meth:`~cabledyn.CableDyn.save_state` carries it. A steady
deck current then sets the static start only; the rules are in :doc:`capi`. On a deck of the
point route, :meth:`~cabledyn.CableDyn.update_point_fluid_fields` sets the field at the points.

A host that moves the ``Coupled`` points from its own body solver starts the model at its
positions and rewinds it between the passes of an iterated time step. The save is keyed on the
start time of the pass, so a pass retried with a smaller ``dt`` restores as well
(:ref:`capi-host-coupling` explains each call and how it differs from MoorDyn):

.. code-block:: python

   import math

   from cabledyn import CableDyn


   class Mooring:
       def __init__(self, deck, fairleads):
           # fairleads: the Coupled points in layout order, flat or (3, n) with n != 3
           self.model = CableDyn()
           self.model.init_deck_at(deck, fairleads)
           self.q, self.v, self.a = self.model.get_coupled_motion()
           self.host = self.model.host_dofs()  # the "coupled" blocks of coupled_layout()
           self.t_saved = -math.inf  # nothing saved yet

       def solve(self, t, dt, x_end, v_end, a_end):
           """One pass of the host time step from t - dt to t (flat host motion at t)."""
           t_prev = t - dt
           if t_prev - self.t_saved >= 1e-3 * dt:  # a new step: the model is at t_prev
               self.model.save_state()
               self.t_saved = t_prev
           else:  # a repeated pass from the same start time, whatever its dt
               self.model.restore_state()
           self.q[self.host], self.v[self.host], self.a[self.host] = x_end, v_end, a_end
           self.model.step(dt, self.q, self.v, self.a)
           return self.model.calc_output()[self.host].reshape(3, -1, order="F")

Raw-array lines and load Jacobians
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

:meth:`~cabledyn.CableDyn.init_line` and :meth:`~cabledyn.CableDyn.init_lines` build a model from
lines the caller has meshed, without a deck. These lines are **structural only**: two-node
``EI = 0`` axial elements with a consistent mass matrix, without gravity, buoyancy, seabed,
hydrodynamics or structural damping, and without a static solve, so the state starts at ``q0``,
``v0`` exactly. Use a deck for anything else. As in the C API, ``elem_conn``, ``fixed_dofs`` and
``coupled_map`` are **1-based**, and the order of ``fixed_dofs`` is the order of the coupled
vector:

.. code-block:: python

   import numpy as np
   from cabledyn import CableDyn

   n_elem = 10
   nodes = np.linspace(0.0, 1.0, n_elem + 1)[:, None] * [100.5, 0.0, 0.0]
   first = np.arange(1, n_elem + 1)

   with CableDyn() as model:
       model.init_line(
           q0=nodes.reshape(-1),
           v0=np.zeros(nodes.size),
           elem_conn=np.column_stack([first, first + 1]),   # 1-based node pairs
           l0=np.full(n_elem, 10.0),                        # m
           ea=np.full(n_elem, 1.0e7),                       # N
           rho_a=np.full(n_elem, 50.0),                     # kg/m
           fixed_dofs=[1, 2, 3, 31, 32, 33],                # both end nodes, 1-based
           tension_only=True,
           rho_inf=0.8,
       )
       q, v, a = model.get_coupled_motion()
       loads, dload_dq, dload_dv, dload_da, added_mass = model.calc_output_derivatives(q, v, a)

:meth:`~cabledyn.CableDyn.init_lines` takes the counts of each line, then the same arrays
concatenated in line order, with connectivity and ``fixed_dofs`` local to each line. Its optional
``coupled_map`` connects lines at shared points; see ``CableDyn_InitLines`` in :doc:`capi`.
Shapes, non-finite values and non-integer indices raise ``ValueError`` or ``TypeError`` before the
library is called, which changes nothing. The library judges the values (an index out of range, a
repeated fixed DOF, a non-positive length) and raises :class:`cabledyn.CableDynError`; the handle
must then be initialised again, unless it held a model on the coupled aggregate, which stays live.

:meth:`~cabledyn.CableDyn.calc_output_derivatives` returns the loads at an operating point and
their analytic Jacobians, ``J[i, j]`` being the derivative of load ``i`` with respect to coupled
DOF ``j``, and works on raw lines and on decks of the point route. A model on the coupled aggregate
has no load derivatives and raises :class:`cabledyn.CableDynError`. Each line's interior DOFs are
condensed out: interior positions and velocities are held and interior accelerations eliminated
through the mass matrix, so the blocks are those of ``update_states`` followed by ``calc_output``,
the instantaneous response of the end loads to the end motion. ``added_mass`` is ``-dload_da``.

.. warning::

   ``calc_output_derivatives`` **sets the model state**: on return the model is at the operating
   point, as after ``update_states``, and the previous state is not restored. Call
   ``update_states`` with the previous kinematics to return to them.

Objects and output channels
~~~~~~~~~~~~~~~~~~~~~~~~~~~

An initialised model exposes its objects as :attr:`~cabledyn.CableDyn.lines`,
:attr:`~cabledyn.CableDyn.points`, :attr:`~cabledyn.CableDyn.bodies` and
:attr:`~cabledyn.CableDyn.rods` (:class:`cabledyn.objects.Line`, ``Point``, ``Body``, ``Rod``),
and :meth:`~cabledyn.CableDyn.line` etc. look one up by deck id. Their getters read the committed
state at the time of the call through the same evaluator as the deck ``OUTPUTS`` channels and the
``.Line<L>.p.out``/``.t.out`` files, so a value equals what the driver writes for that state:

.. code-block:: python

   with CableDyn("mooring.dat") as model:
       line = model.line(1)
       xyz = line.node_positions()          # (n_nodes, 3), End A first
       seg = line.segment_tensions()        # (n_segments,)
       axes = line.section_curvature()      # (n_nodes, 2): CurvX, CurvY of a finite-EI line
       kappa = line.curvature()             # (n_nodes,); bend_moment() on finite-EI lines
       buf = np.empty_like(xyz)
       for _ in range(100):
           model.step_held(0.05)            # coupled points held in place
           line.node_positions(out=buf)     # fills buf, no allocation
       print(model.time, model.channel("FairTen1"), model.point(1).force())

``Line`` also gives velocities, accelerations, node tensions, declination, azimuth, deformed arc
length and the end tensions; ``Point`` its position, velocity and the resultant line force;
``Body`` its pose, velocity, acceleration and net wrench about the reference point; ``Rod`` its
node positions, End A pose, velocity and wrench. :meth:`~cabledyn.CableDyn.channel` evaluates
any ``OUTPUTS`` token (``L2N5px``, ``Curv1N3``, ``Point4Fz``, ``AnchFz1``, ``Body1Pz``,
``Rod2TenA``, ...).
Views are cheap and hold no state; re-initialising or closing the model makes them stale, and a
stale view raises :class:`cabledyn.CableDynError`.

Snapshots and animation
~~~~~~~~~~~~~~~~~~~~~~~

:class:`cabledyn.Snapshots` holds the geometry of every line, point, body and rod at a common
set of times, with the seabed (flat ``WtrDpth`` or the deck's bathymetry grid) and the free
surface (a deck's regular Airy wave with its start-up ramp). :func:`cabledyn.animation.record`
and :class:`cabledyn.Recorder` sample an in-process model every ``N`` steps under held or
caller-supplied coupled motion; :meth:`~cabledyn.Snapshots.from_files` collects a driver run's
per-line and per-rod files and the ``Point``/``Body`` channels of its main output, and
:meth:`~cabledyn.Snapshots.from_static` reads a ``.static.out`` profile.
:meth:`~cabledyn.Snapshots.save_npz` writes one archive with one array per object for a viewer
to load, and :func:`cabledyn.animate` plays the snapshots in a Matplotlib 3D axes. The tutorial
:doc:`tutorial_python` records and animates a surged chain.

API reference
-------------

Every public class, function, and exception is documented in :doc:`api_python`.
