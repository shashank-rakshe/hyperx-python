.. SPDX-License-Identifier: Apache-2.0

Command-line reference
======================

CableDyn ships one native solver executable and four Python console tools:

.. list-table::
   :header-rows: 1
   :widths: 28 72

   * - Command
     - Purpose
   * - ``CableDyn_driver``
     - the standalone solver: reads a deck, solves the static initial condition and, when the
       deck asks for it, the dynamic march, and writes the result tables. Released as
       ``CableDyn_driver.exe``; a source build produces the same program as ``build/cabledyn``
       (``build\bin\cabledyn.exe`` with the conda toolchain on Windows)
   * - ``cabledyn-run``
     - runs one deck through the native solver and validates its main output
   * - ``cabledyn-post``
     - summaries, exports, plots, fatigue, spectra and coherence of result files
   * - ``cabledyn-deck``
     - validates, inspects, edits and generates decks
   * - ``cabledyn-study``
     - runs a generated parameter study

Coupled runs in OpenFAST, maintained by NLR (National Laboratory of the Rockies, formerly NREL),
need no separate executable: CableDyn is compiled into ``openfast.exe``
and selected with ``CompMooring = 5`` (see :doc:`openfast`). CFD and scripting hosts use the
shared library through the :doc:`C API <capi>` or the :doc:`Python package <python>`.

``CableDyn_driver`` — the standalone solver
-------------------------------------------

Synopsis
~~~~~~~~

.. code-block:: text

   CableDyn_driver <deck.dat> <out_root>
   CableDyn_driver -v | -V | -version | -VERSION | --version
   CableDyn_driver -h | -H | -help | -HELP | --help | -? | /?

Arguments
~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 18 82

   * - Argument
     - Meaning
   * - ``<deck.dat>``
     - the input deck (:doc:`driver_format`). Relative paths are resolved against the current
       working directory; files the deck references (``motionFile``, bathymetry, WaterKin,
       Syrope tables) are resolved against the **deck's** directory (:doc:`file_formats`).
   * - ``<out_root>``
     - the output root: every result file is ``<out_root>`` plus a suffix (``.out``,
       ``.static.out``, …; see :doc:`outputs`). It may include a directory, which must already
       exist. Existing result files with the same names are replaced.

Exactly two positional arguments are required. Each argument may be at most 4096 characters.

Options
~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Option
     - Effect
   * - ``-v``, ``-V``, ``-version``, ``-VERSION``, ``--version``
     - print the identity banner (name, version, author, licence) to stdout and exit 0
   * - ``-h``, ``-H``, ``-help``, ``-HELP``, ``--help``, ``-?``, ``/?``
     - print the banner and the usage summary to stdout and exit 0

A version or help option is recognised only as the **first** argument; everything after it is
ignored. Any other argument that begins with ``-`` — anywhere on the command line — is an
unknown option: the driver prints ``CableDyn_driver: unknown option "<arg>"`` and the usage to
stderr and exits 1. A deck or output root whose name begins with ``-`` must therefore be given
with a directory prefix (``./-case.dat``).

Checks before the solve
~~~~~~~~~~~~~~~~~~~~~~~

Before the deck is solved, the driver rejects, with exit code 1 and a message on stderr:

* a wrong number of arguments (banner and usage are printed to stderr);
* an argument that is empty, cannot be read, or is longer than 4096 characters
  (``CableDyn_driver: argument <i> is longer than 4096 characters``);
* a deck path or output root that cannot be opened exactly: a reserved Windows device name
  (``CON``, ``NUL``, ``COM1``, …) or a path beyond the length limit with no shorter spelling
  (``CableDyn_driver: cannot read deck "<deck>": <reason>`` or ``cannot write output files at
  "<root>": <reason>``; see :doc:`driver_format`, *File names*). Arguments are read as Unicode,
  and the release ``CableDyn_driver.exe`` runs with UTF-8 as its Windows code page (Windows 10
  version 1903 or later), so accented, Hangul, emoji, and mixed-script names are accepted in the
  arguments and in the working folder alike. A driver built from source with the GNU toolchain
  opens a name outside the system ANSI code page through its 8.3 short name and refuses it on a
  volume without short names;
* an output root one of whose result files would be the deck, however spelled
  (``CableDyn_driver: output root "<root>" would overwrite the input deck``), or a file the
  deck reads (``… would overwrite the input file "<file>" that the deck reads``). The check
  covers every file a run writes: ``.out``, ``.static.out``, ``.elements.out``, the modal
  table ``.modes.out``, the per-line ``.Line<N>.p.out`` / ``.t.out`` / ``.V.out`` /
  ``.range.out`` and per-rod ``.Rod<N>.p.out`` files, the probe, and the lock;
* an output location that cannot be written — a missing directory or one without write
  permission (``CableDyn_driver: cannot write output files at "<root>" (check that the
  directory exists and is writable)``). The check creates and removes a probe file
  ``<out_root>.write_check.tmp``; an existing file of that name is left in place;
* an output root that another running ``CableDyn_driver`` is writing
  (``CableDyn_driver: another CableDyn run is writing output root "<root>" …``). A run holds
  the lock file ``<out_root>.cabledyn.lock`` from just before its first output until it ends;
  the operating system releases it even when the run is killed, so a stale lock never blocks
  a later run.

Standard streams
~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 16 84

   * - Stream
     - Content
   * - stderr
     - the identity banner (on a solve run); the initialisation report on static, ``EI = 0``
       and finite-EI decks; every diagnostic and error message
   * - stdout
     - the initialisation report on mixed ``EI = 0`` + finite-EI decks; dynamic progress
       (``Dynamic simulation: …`` and ``Progress: …% | t = … s | elapsed … | ETA …``, at 5 %
       intervals); ``Recovery audit: …`` and ``Tensile monitor: …`` summaries;
       ``CableDyn: FAILURE …`` event lines; the run-time profile when ``CABLEDYN_PROFILE`` is
       set (:ref:`cli-profile`); and, last, the success line

The formats of the report and progress records are shown in :doc:`outputs`. On success the
final stdout line is exactly::

   CableDyn_driver: converged run written to <out_root>.out

stdout is a human-readable log, not a machine-parseable stream: its records vary with the deck
and the route. Automation should rely on the **exit status** and read results from the output
files. To keep only the stdout records, discard stderr (``2>/dev/null`` or ``2>$null``).

.. _cli-profile:

Run-time profile
~~~~~~~~~~~~~~~~

Set the environment variable ``CABLEDYN_PROFILE`` to ``1`` to see where the wall time of a run
goes. The driver then prints ``Run-time profile armed by CABLEDYN_PROFILE.`` at the start and,
at the end of the run (before the success line, or before the closing line of a failed run), a
breakdown such as:

.. code-block:: text

     Run-time profile (CABLEDYN_PROFILE), wall-clock time:
       input parsing                             0.002 s    0.1 %
       initialisation and statics                0.238 s    8.7 %
       dynamic march                             2.496 s   91.2 %
         fluid sampled by the driver             0.051 s    1.9 %
         line, cable and object steps            2.430 s   88.8 %
         checks and line failures                0.002 s    0.1 %
         outputs                                 0.013 s    0.5 %
         progress and bookkeeping                0.000 s    0.0 %
       finalisation                              0.000 s    0.0 %
       total                                     2.736 s  100.0 %
       March: 600 committed step(s), 4.1596 ms per step.
       EI = 0 line steps: 3621 (substeps and retries included), Newton iterations: 4739 (1.309 per line step, at most 2).
       EI = 0 line step kernels: residual 6947 (0.040 s), residual and tangent 3322 (0.064 s), factorisation 3322 (0.013 s), back-substitution 5126 (0.009 s).
       Finite-EI cable steps: 1423, residual evaluations: 6140, tangent assemblies: 2914, factorisations: 2914, linear solves: 2914, force-blend corrections: 1423, intervals recovered by substeps: 0.
       Finite-EI cable step time (s): residual 0.420, tangent 0.913, effective matrix 0.039, factorisation 0.213, back-substitution 0.076, added mass 0.050, other 0.086.
       Finite-EI cable assembly time (s): band zeroing 0.033, tangent element kernels 0.809, tangent scatter 0.065, structural residual 0.173, weight 0.003, attachments 0.000, dry buoyancy 0.024, seabed contact 0.007, axial damping 0.147, drag 0.240, end connections 0.001, wave Froude-Krylov 0.000, held Froude-Krylov 0.126, torsion 0.000.

The phases add up to the total, which runs from the start of the deck parse to the report. If the
run stops with an error, the time up to the stop counts to the phase in which it stopped, and
finalisation stays at zero.

* **Input parsing** covers reading the deck and its auxiliary files.
* **Initialisation and statics** covers the synthesis of the deck's waves, building the models,
  the static equilibrium, any modal analysis, and the initial output rows. For a static deck it
  also covers writing the output
  files. On the mixed ``EI = 0`` + finite-EI route it includes the deck parse that builds the
  models.
* **Fluid sampled by the driver** is the deck wave and current field that the driver samples at
  the nodes before each step. A finite-EI cable evaluates the wave kinematics inside its
  element loads, and a ``motionFile`` Rigid6 or rod march samples the fluid within its step. On
  those routes, that work counts as **line, cable and object steps**.
* **Outputs** covers the output channels, the per-line files, and the range-graph samples.

The counts follow the march:

* **EI = 0 line steps** counts every step of every tension-only line, including recovery
  substeps, retries and, on the body marches, each re-step of a line within the body
  iterations. **Newton iterations** is their total.
* **EI = 0 line step kernels** splits the work inside those steps: the residual-only
  evaluations (predictor tests and line-search trials), the evaluations that also assemble the
  effective tangent, the LU factorisations of that tangent, and the back-substitutions with it
  (Newton updates, a reused factor and the end tangent of a body junction). Each count is
  followed by its time, summed over the lines: it can exceed the wall time when lines step
  concurrently, so set ``OMP_NUM_THREADS=1`` to compare it with the phase rows.
* **Finite-EI cable steps** counts the same for the cubic-Hermite cables. A cable clamped to a
  body is re-stepped in every body iteration, so the count can exceed the number of march
  steps. Its step time is split into the residual and tangent assemblies, the effective
  matrix, the factorisations, the back-substitutions (of the Newton solves and of the
  force-blend correction that ends each step), the added mass and the rest; the rarely used
  torsion and consistent-acceleration solves count to the rest.
* **Finite-EI cable assembly time** splits the residual and tangent assemblies into their
  sections. The tangent element kernels evaluate the structural, damping, drag and wave
  tangents of each element together. A residual evaluation that a tangent is expected to follow
  at the same state (the predictor of a step, and the full Newton step of an iteration the
  previous step went past) runs them with the element loads, so their time then counts to the
  residual assembly and the tangent assembly only scatters their blocks; the other sections
  are the element residuals, the weight
  and supports, the attachments, the dry-part buoyancy, the seabed contact, the axial damping,
  the drag, the end connections, the wave and held Froude-Krylov loads and the torsion. The
  sections also count the assemblies made outside the step (reactions, end moments and
  consistent accelerations), so they can add up to more than the residual and tangent times.

An unset or empty variable, or ``0``, leaves the profile off. The driver reads the variable once,
when it starts.

The profile only reads the clock and never changes a result: every output file is identical
with and without it. Its cost is a few clock reads per step.

On the mixed ``EI = 0`` + finite-EI route the cables step concurrently, so the profile does not
count the finite-EI cable steps there. It says so in their place, and leaves that route's
execution exactly as in an unprofiled run.

``openfast.exe`` reads the same variable for its own module profile (see :doc:`faq`).

Exit codes
~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 10 90

   * - Code
     - Meaning
   * - ``0``
     - success: the static solve converged and, for a dynamic deck, every step of the march
       converged; all output files were written. Also returned by ``--version`` and ``--help``.
   * - ``1``
     - invalid invocation or input: argument errors, unknown options, the pre-solve checks above,
       any deck parse or validation error (unknown keyword, bad value, unresolved id, unsupported
       feature combination, unreadable auxiliary file), and failure to create an output file
   * - ``2``
     - the solve failed: a static line did not converge (``<out_root>.out`` is still written
       with ``converged=F`` for inspection), a finite-EI static initialisation did not converge
       or was rejected by the ``max(h*kappa)`` folded-branch check or the tensile-safety check, a
       dynamic step did not converge or its linear solve failed (the output holds the committed
       steps only), or a result became non-finite. Also returned before the deck is read when
       a Windows GNU source build cannot load its LAPACK runtime (``openblas.dll``); the
       message names the library, each location tried and the Windows load error. The release
       ``CableDyn_driver.exe`` is statically linked and has no such dependency

Every non-zero exit the driver makes itself writes its message on stderr and ends stderr with
the closing line ``CableDyn_driver: ended with exit code <n>``. An interrupt or a fatal fault is
reported with the simulated time reached; a process ended from outside (``taskkill /F``,
``kill -9``) cannot report anything. See :ref:`run-ended-early` for how to recognise each case,
and :doc:`troubleshooting` for the messages and their remedies.

Examples
~~~~~~~~

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null
   .\CableDyn_driver.exe examples\wd0050_chain.dat results\wd0050
   if ($LASTEXITCODE -ne 0) { Write-Error "CableDyn failed ($LASTEXITCODE)" }

.. code-block:: bash

   mkdir -p out
   if ./build/cabledyn examples/wd0050_chain.dat out/wd0050 2>err.log; then
       echo "converged"
   else
       echo "failed ($?)"; cat err.log
   fi

For installation of the distributable Windows executable and working-directory rules, see
:doc:`standalone_driver`.

Python command-line tools
-------------------------

Installing the Python package adds four console commands. They are thin wrappers around the
package API described in :doc:`python` and :doc:`api_python`; they do not replace the native
``CableDyn_driver`` executable, which ``cabledyn-run`` and ``cabledyn-study`` launch as a
subprocess.

.. list-table::
   :header-rows: 1
   :widths: 20 30 50

   * - Command
     - Entry point
     - Purpose
   * - ``cabledyn-run``
     - ``cabledyn.cli:main``
     - Run one standalone deck through the native driver and validate its main output.
   * - ``cabledyn-post``
     - ``cabledyn.post_cli:main``
     - Summarise, export, plot, rainflow-count, or spectrally analyse a result table.
   * - ``cabledyn-deck``
     - ``cabledyn.deck_cli:main``
     - Validate, inspect, edit, or generate variants of an input deck.
   * - ``cabledyn-study``
     - ``cabledyn.study_cli:main``
     - Run every case of a generated ``cases.json`` study and write a study record.

Conventions shared by all four tools:

* Options of ``cabledyn-post`` and ``cabledyn-deck`` belong to the subcommand and are written
  after it (``cabledyn-deck validate deck.dat --caller-driven``).
* ``-h``/``--help`` prints help to stdout and exits with code 0. A usage error (missing
  argument, unknown option, invalid choice, a value that does not convert to the declared type,
  a missing required option) prints the usage line and the error to stderr and exits with
  code 2.
* Handled errors are printed to stderr as a single line ``<prog>: <message>``. Results and
  written file paths go to stdout.
* Output paths are expanded (``~``) and resolved to absolute paths, and missing parent
  directories are created. Decks, CSV tables, and JSON records are written through a temporary
  file in the target directory and then renamed, so an interrupted write never leaves a
  partial file under the requested name. Figures are saved directly by matplotlib.
* An existing output file is never replaced unless ``--overwrite`` is given.
* An unexpected exception outside the handled classes listed for each tool ends the process
  with a Python traceback and exit code 1.

Locating the native driver
~~~~~~~~~~~~~~~~~~~~~~~~~~

``cabledyn-run`` and ``cabledyn-study`` find the native executable as follows:

1. If ``--executable PATH`` is given, that file is used and nothing else is tried.
2. Otherwise, if the ``CABLEDYN_DRIVER`` environment variable is set, the file it names is
   used when it exists.
3. Otherwise ``PATH`` is searched for ``CableDyn_driver.exe``, ``CableDyn_driver``, and
   ``cabledyn``, in that order.

On Linux and macOS a direct path (1 or 2) must also be executable. If no candidate is found,
the command fails with ``could not locate CableDyn_driver using ... Tried: ...``, listing every
candidate that was checked.

cabledyn-run
~~~~~~~~~~~~

Runs one complete standalone deck (:doc:`driver_format`) and checks that the solver produced a
readable main output table.

.. code-block:: text

   cabledyn-run [-h] [--executable EXECUTABLE] [--timeout TIMEOUT] [--overwrite]
                deck output_root

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Argument
     - Type
     - Default
     - Meaning
   * - ``deck``
     - path
     - required
     - The sectioned ``.dat`` deck. It must exist. The native process runs with the deck's
       directory as its working directory, so relative ancillary-file references in the deck
       resolve as they do when the driver is run by hand from that directory.
   * - ``output_root``
     - path stem
     - required
     - Output stem without ``.out``; the solver appends the suffixes. A relative stem is
       resolved against the deck's directory, not the current directory. A stem ending in
       ``.out`` or with no file name (``.``, ``..``) is rejected. Missing parent directories
       are created.
   * - ``--executable``
     - path
     - see above
     - Native driver to run (see *Locating the native driver*).
   * - ``--timeout``
     - float, s
     - none
     - Maximum wall-clock time for the solver process; finite and positive (``0``, negative,
       ``inf``, and ``nan`` are rejected before the solver starts). When exceeded the process
       is killed and the command fails. With no value the run is not time-limited.
   * - ``--overwrite``
     - flag
     - off
     - Allow a run whose output files already exist. The previous files are kept aside until
       the new run succeeds (see *Files written*).

**Files written.** The native driver writes ``<root>.out`` and, depending on the deck,
``<root>.static.out``, ``<root>.elements.out``, ``<root>.Line<N>.p.out``,
``<root>.Line<N>.t.out``, ``<root>.Line<N>.V.out``, ``<root>.Line<N>.range.out``,
``<root>.Rod<N>.p.out`` and ``<root>.modes.out`` (see :doc:`outputs`). If any of these files of
that root already exists, the run is refused unless ``--overwrite`` is given. With
``--overwrite`` the previous files are moved into a temporary directory
``.<stem>.previous-<random>`` beside them while the solver runs. They are deleted once the new
run has succeeded; if the rerun fails for any reason (non-zero exit, timeout, missing or
malformed main output, or an interruption), the partial new files are removed and the previous
results are restored unchanged.

**Streams.** On success, stdout receives exactly one line: the absolute path of ``<root>.out``.
The solver's own stdout and stderr are captured and not echoed. On failure, stderr receives
``cabledyn-run: <message>``; when the native process fails, the message contains its exit code
and its captured stderr (or stdout, if stderr is empty).

**Exit codes.**

.. list-table::
   :header-rows: 1
   :widths: 10 90

   * - Code
     - Meaning
   * - 0
     - The native driver exited with code 0 (the driver reserves 0 for a fully converged
       analysis), ``<root>.out`` exists, and it parsed as a valid table.
   * - 1
     - Handled failure: executable not found; deck missing; invalid output stem; outputs exist
       without ``--overwrite``; the native process exited non-zero; the timeout expired; the
       process exited 0 but ``<root>.out`` is missing or malformed; or another operating-system
       error.
   * - 2
     - Command-line usage error (argparse).

Example:

.. code-block:: text

   cabledyn-run lazy_wave.dat results/lw_dlc11 --timeout 3600 --overwrite

This writes ``results/lw_dlc11.out`` (and any auxiliary files) next to ``lazy_wave.dat`` and
prints the absolute path of the main output.

cabledyn-post
~~~~~~~~~~~~~

Reads one CableDyn result table (:doc:`outputs`) and summarises, exports, plots, or analyses it,
or compares two time histories. The file type is detected from its header: a table whose first
column is ``Time`` or ``Time(s)`` is a time history (a ``.Line<N>.p.out`` or ``.Line<N>.t.out``
time history is a dynamic per-line node-position or segment-tension history); a table with
``LineID``, ``Node``, and ``ArcLength`` columns is a static profile; anything else is a generic
table.

Results of other tools are read with the readers described in :doc:`python_postprocessing`,
chosen from the file name: ``*.outb`` is an OpenFAST binary file, ``*.MD.Line<N>.out`` a
MoorDyn line file, ``*.MD.out`` a MoorDyn main file, and anything else (including OpenFAST text
``.out`` and coupled ``*.CD.out`` files) the CableDyn reader. Every subcommand accepts
``--format {auto,cabledyn,openfast,moordyn,moordyn-line}`` to override that choice.

.. code-block:: text

   cabledyn-post [-h] {summary,export,plot,fatigue,spectrum,coherence,compare} ...

   cabledyn-post summary  file [--line LINE] [--start START] [--stop STOP]
   cabledyn-post export   file output [--line LINE] [--overwrite]
   cabledyn-post plot     file channel [--line LINE] [--x X] [--plane {xy,xz,yz,3d}]
                          [--start START] [--stop STOP] [--time TIME] [--output OUTPUT]
                          [--overwrite]
   cabledyn-post fatigue  file channel --m M
                          (--reference-cycles N | --reference-frequency F)
                          [--start START] [--stop STOP] [--bins BINS]
                          [--cycles-output PATH] [--histogram-output PATH]
                          [--plot-output PATH] [--overwrite]
   cabledyn-post spectrum file channel --segment-length N [spectral options]
                          [--moment ORDER]... [--min-frequency F] [--max-frequency F]
                          [--peaks K] [--logarithmic]
   cabledyn-post coherence file channel_x channel_y --segment-length N [spectral options]
                          [--power-floor-ratio R]
   cabledyn-post compare  reference candidate [--channel NAME | --channel REF=CAND]...
                          [--start START] [--stop STOP] [--grid {reference,candidate}]
                          [--percentile P] [--no-unit-check] [--output CSV] [--overwrite]

A subcommand is required. Channel names are matched exactly (case-sensitive) against the table
header, for example ``FairTen1`` or ``Tension``. Period limits ``--start``/``--stop`` select the
closed interval ``[start, stop]`` in seconds; they must be finite, ``start`` must not exceed
``stop``, and the interval must contain at least one sample.

Plotting (``plot``, and ``--plot-output`` of ``fatigue``, ``spectrum``, ``coherence``) needs
matplotlib (``pip install "cabledyn[plot]"``). Figures are saved with the format implied by the
file suffix (``.png``, ``.pdf``, ``.svg``, ...).

summary
^^^^^^^

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Argument
     - Type
     - Default
     - Meaning
   * - ``file``
     - path
     - required
     - Result table.
   * - ``--line``
     - int
     - every line
     - Static profile only: summarise one ``LineID``. Ignored for other tables.
   * - ``--start``, ``--stop``
     - float, s
     - whole record
     - Time history only: statistics period. Ignored for other tables.

Output on stdout, as ``key: value`` lines:

* **Static profile**: per line, ``line_id``, ``node_count``, ``deformed_length`` (final
  ``ArcLength``), ``minimum_tension``, ``maximum_tension``, ``maximum_curvature``,
  ``minimum_bend_radius`` (``1/maximum_curvature``; ``inf`` for zero curvature), and
  ``maximum_bend_moment`` (largest absolute ``BendMoment``), in the units of the source columns.
  A quantity whose column is absent prints ``None``. Lines are separated by a blank line.
* **Time history**: ``samples``, ``time_start``, ``time_stop``, then for every non-time channel
  a blank line and ``channel``, ``unit``, ``count``, ``minimum``, ``maximum``, ``mean``,
  ``standard_deviation`` (population), and ``rms``.
* **Generic table**: ``rows`` and a comma-separated ``channels`` list.

export
^^^^^^

Writes a table that pyDatView reads directly: one header row of ``Name_[unit]`` labels followed
by the values with 17 significant digits. A ``.csv`` suffix produces comma-separated text; any
other suffix produces tab-separated text.

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Argument
     - Type
     - Default
     - Meaning
   * - ``file``
     - path
     - required
     - Result table (any type).
   * - ``output``
     - path
     - required
     - Export target. Must not be the source file.
   * - ``--line``
     - int
     - all rows
     - Export one ``LineID``. Valid only for a static profile; an error otherwise.
   * - ``--overwrite``
     - flag
     - off
     - Replace an existing ``output``.

stdout receives the absolute path of the written file.

plot
^^^^

Draws one figure and saves it with ``--output``, or opens an interactive window when
``--output`` is omitted (the command returns when the window is closed).

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Argument
     - Type
     - Default
     - Meaning
   * - ``file``
     - path
     - required
     - Result table.
   * - ``channel``
     - string
     - required
     - Channel to plot, or ``geometry`` (case-insensitive) for a centreline. See the table
       below for what each file type accepts.
   * - ``--line``
     - int
     - every line
     - Static profile: plot one ``LineID``. Rejected for dynamic per-line files.
   * - ``--x``
     - string
     - ``ArcLength``
     - Static profile: abscissa channel for a non-geometry plot.
   * - ``--plane``
     - ``xy``, ``xz``, ``yz``, ``3d``
     - ``xz``
     - Projection for ``geometry`` plots (axes in m).
   * - ``--start``, ``--stop``
     - float, s
     - whole record
     - Time window for a time-history channel or a segment-tension envelope.
   * - ``--time``
     - float, s
     - none
     - Snapshot time for dynamic per-line files; values are linearly interpolated and the time
       must lie within the record.
   * - ``--output``
     - path
     - show window
     - Save the figure to this file instead of showing it. Must not be the source file.
   * - ``--overwrite``
     - flag
     - off
     - Replace an existing ``--output`` file.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - File type
     - Accepted ``channel`` and options
   * - Static profile
     - ``geometry`` (uses ``X``, ``Y``, ``Z``; ``--plane``, ``--line``) or any column plotted
       against ``--x`` (``--line``). ``--time`` is rejected.
   * - Dynamic node positions (``.Line<N>.p.out``)
     - ``geometry`` only; ``--time`` is required; ``--start``, ``--stop``, ``--line`` are
       rejected.
   * - Dynamic segment tensions (``.Line<N>.t.out``)
     - ``Tension`` or ``range`` (case-insensitive). With ``--time``: tension along the line at
       that instant (``--start``/``--stop`` rejected). Without ``--time``: min-max band and mean
       per segment over ``[--start, --stop]``. ``--line`` is rejected.
   * - Other time history
     - Any channel against time over ``[--start, --stop]``. ``--time`` is rejected.
   * - Generic table
     - Not plottable (error).

When saving, stdout receives the absolute path of the figure.

fatigue
^^^^^^^

Rainflow-counts one time-history channel (cycle ranges, not amplitudes) and computes the
uncorrected damage-equivalent range

.. math::

   S_\mathrm{eq} = \left(\frac{\sum_i n_i S_i^{m}}{N_\mathrm{eq}}\right)^{1/m},

where :math:`n_i` is the cycle weight (0.5 or 1), :math:`S_i` the cycle range, and
:math:`N_\mathrm{eq}` the reference cycle count. No mean-stress or other correction is applied.

.. list-table::
   :header-rows: 1
   :widths: 24 16 15 45

   * - Argument
     - Type
     - Default
     - Meaning
   * - ``file``
     - path
     - required
     - Time-history table (an error for other types).
   * - ``channel``
     - string
     - required
     - Channel to count; must not be the time channel.
   * - ``--m``
     - float
     - required
     - Woehler (S-N) exponent; finite and positive.
   * - ``--reference-cycles``
     - float
     - one of the two is required
     - :math:`N_\mathrm{eq}`, finite and positive. Mutually exclusive with
       ``--reference-frequency``.
   * - ``--reference-frequency``
     - float, Hz
     - one of the two is required
     - Equivalent-cycle frequency; :math:`N_\mathrm{eq}` = frequency x selected record
       duration. Finite and positive.
   * - ``--start``, ``--stop``
     - float, s
     - whole record
     - Analysis period; at least two samples are required.
   * - ``--bins``
     - int
     - 32 when a histogram or plot is requested
     - Number of equal-width range bins spanning 0 to the largest cycle range; must be
       positive.
   * - ``--cycles-output``
     - path
     - none
     - Write every rainflow cycle as CSV: ``count_[-]``, ``range_[unit]``, ``mean_[unit]``,
       ``start_index_[-]``, ``end_index_[-]``, ``start_time_[s]``, ``end_time_[s]``.
   * - ``--histogram-output``
     - path
     - none
     - Write the range histogram as CSV: ``range_lower``, ``range_upper``, ``range_center``
       (channel unit) and ``count_[-]`` (weighted cycles).
   * - ``--plot-output``
     - path
     - none
     - Save a histogram bar chart.
   * - ``--overwrite``
     - flag
     - off
     - Replace existing output files.

All requested output paths are checked before any calculation: each must differ from the source
file and, without ``--overwrite``, must not exist. stdout then receives ``channel``,
``source``, ``unit``, ``sample_count``, ``start_time``, ``end_time``, ``duration``,
``wohler_exponent``, ``reference_cycles``, ``equivalent_frequency``, ``cycle_count``, and
``damage_equivalent_range``, followed by the path of each file written. A record with no load
cycles yields a ``damage_equivalent_range`` of 0, still writes ``--cycles-output`` (header
only), and prints ``histogram: not written (the selected record contains no load cycles)``
instead of writing the histogram or plot.

spectrum
^^^^^^^^

Computes a one-sided Welch power spectral density of one channel. The record must be uniformly
sampled (time-step deviation within a relative tolerance of 1e-6 of the median step); it is
never resampled.

Spectral options shared with ``coherence``:

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Option
     - Type
     - Default
     - Meaning
   * - ``--segment-length``
     - int
     - required
     - Samples per Welch segment; at least 2 and no more than the selected sample count. It is
       never shortened automatically.
   * - ``--overlap``
     - float
     - ``0.5``
     - Overlap fraction in [0, 1); overlap samples = floor(overlap x segment length).
   * - ``--fft-length``
     - int
     - segment length
     - FFT length (zero padding); at least the segment length.
   * - ``--window``
     - ``hann``, ``boxcar``
     - ``hann``
     - Segment window.
   * - ``--detrend``
     - ``constant``, ``none``
     - ``constant``
     - ``constant`` removes each segment's mean.
   * - ``--start``, ``--stop``
     - float, s
     - whole record
     - Analysis period.
   * - ``--output``
     - path
     - none
     - Write a CSV of the result.
   * - ``--plot-output``
     - path
     - none
     - Save a figure.
   * - ``--overwrite``
     - flag
     - off
     - Replace existing ``--output``/``--plot-output`` files.

Options specific to ``spectrum``:

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Option
     - Type
     - Default
     - Meaning
   * - ``channel``
     - string
     - required
     - Channel to analyse; must not be the time channel.
   * - ``--moment``
     - float, repeatable
     - none
     - Spectral-moment order :math:`k`; integrates :math:`f^k S(f)` over the band. The band
       must contain at least two bins.
   * - ``--min-frequency``
     - float, Hz
     - first bin
     - Lower band limit for moments and peaks. When omitted and any requested order is
       negative, the first non-zero bin is used (a negative order cannot include 0 Hz).
   * - ``--max-frequency``
     - float, Hz
     - last bin
     - Upper band limit for moments and peaks.
   * - ``--peaks``
     - int
     - ``1``
     - Number of strongest local-maximum bins to report (at least 1). The 0 Hz bin is never
       reported as a peak; fewer lines are printed if fewer maxima exist.
   * - ``--logarithmic``
     - flag
     - off
     - Logarithmic PSD axis in ``--plot-output``.

Every requested quantity is evaluated before anything is printed, so an invalid request fails
without partial output. stdout receives ``channel``, ``source``, ``unit``, ``density_unit``,
``start_time``, ``end_time``, ``sample_interval``, ``sample_count``, ``segment_length``,
``overlap_samples``, ``fft_length``, ``segment_count``, ``window``, ``detrend``,
``uniform_rtol``, ``uniform_atol``, ``frequency_resolution``; then ``moment_<k>`` and
``moment_<k>_unit`` per requested order; then ``peak_<r>_frequency`` and ``peak_<r>_density``
per peak; then the paths of written files. The CSV has the columns ``frequency_[Hz]`` and
``PSD_[<density unit>]``, where the density unit is the channel unit squared per hertz (plain
``PSD`` when the channel has no unit).

coherence
^^^^^^^^^

Computes the magnitude-squared Welch coherence of two channels, using the spectral options
above. At least two complete Welch segments are required. A frequency bin is *valid* only where
both auto-spectra exceed ``--power-floor-ratio`` times their own maximum; invalid bins carry no
coherence value.

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Option
     - Type
     - Default
     - Meaning
   * - ``channel_x``, ``channel_y``
     - string
     - required
     - Two distinct non-time channels.
   * - ``--power-floor-ratio``
     - float
     - 100 x machine epsilon (about 2.2e-14)
     - Relative auto-spectrum floor, in [0, 1).

stdout receives ``channel_x``, ``channel_y``, ``source``, ``start_time``, ``end_time``,
``sample_interval``, ``sample_count``, ``segment_length``, ``overlap_samples``,
``fft_length``, ``segment_count``, ``window``, ``detrend``, ``uniform_rtol``,
``uniform_atol``, ``power_floor_ratio``, ``valid_bins``, ``invalid_bins``, then the paths of
written files. The CSV has the columns ``frequency_[Hz]``, ``coherence_[-]`` (empty for invalid
bins), and ``valid_[-]`` (1 or 0).

``compare``
^^^^^^^^^^^

Compares a candidate time history with a reference channel by channel on the interval both
cover, interpolating linearly onto one of the two time grids and never extrapolating
(:func:`cabledyn.compare_histories`).

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Option
     - Type
     - Default
     - Meaning
   * - ``reference``, ``candidate``
     - path
     - required
     - Two time-history files, read with the same ``--format``.
   * - ``--channel``
     - ``NAME`` or ``REF=CAND``, repeatable
     - every shared name
     - Channel pairs to compare; ``FAIRTEN1=FairTen1`` pairs differently named channels.
   * - ``--start``, ``--stop``
     - float, s
     - shared interval
     - Narrow the compared period.
   * - ``--grid``
     - ``reference`` or ``candidate``
     - ``reference``
     - Time grid the other record is interpolated onto.
   * - ``--percentile``
     - float in [0, 100]
     - 95
     - Percentile whose change is reported.
   * - ``--no-unit-check``
     - flag
     - off
     - Compare channels whose recorded units differ.
   * - ``--output``
     - path
     - none
     - Write one CSV row of metrics per channel (refused if it names either input).
   * - ``--overwrite``
     - flag
     - off
     - Replace an existing ``--output`` file.

stdout receives ``reference``, ``candidate``, ``time_start``, ``time_stop``, ``samples``, and
``percentile``, then one block per channel with ``channel``, ``candidate_channel``, ``unit``,
``count``, ``max_abs_difference``, ``mean_difference``, ``rms_difference``,
``normalized_rms_difference``, ``relative_max_difference``, ``correlation``,
``reference_maximum``, ``candidate_maximum``, ``maximum_delta``, ``minimum_delta``,
``mean_delta``, ``standard_deviation_delta``, and ``percentile_delta``
(``difference = candidate - reference``), then the path of the CSV when written.

Exit codes
^^^^^^^^^^

.. list-table::
   :header-rows: 1
   :widths: 10 90

   * - Code
     - Meaning
   * - 0
     - The subcommand completed.
   * - 1
     - Handled failure: unreadable or malformed result file; unknown channel or ``LineID``;
       option not valid for the file type; invalid analysis parameter; output exists without
       ``--overwrite`` or equals the source; matplotlib not installed; or another
       operating-system error. For ``fatigue``, ``spectrum``, and ``coherence``, a failure while
       writing a later output (for example a missing matplotlib for ``--plot-output``) happens
       after the results were printed and earlier files were written.
   * - 2
     - Command-line usage error (argparse), including a missing subcommand, a missing
       ``--m`` or ``--segment-length``, or both or neither of ``--reference-cycles`` and
       ``--reference-frequency``.

Example:

.. code-block:: text

   cabledyn-post fatigue results/lw_dlc11.out FairTen1 --m 3 --reference-frequency 1 \
       --start 600 --stop 4200 --histogram-output fairten1_hist.csv \
       --plot-output fairten1_hist.png

cabledyn-deck
~~~~~~~~~~~~~

Validates, inspects, edits, and generates variants of a CableDyn input deck
(:doc:`driver_format`). Editing preserves every untouched row, comment, and byte of the source;
an edited row is re-rendered with single spaces between its data tokens while its indentation
and trailing commentary are kept. Every deck read and every result is validated against the
native reader's rules.

.. code-block:: text

   cabledyn-deck [-h] {validate,show,set,generate} ...

   cabledyn-deck validate deck [--caller-driven]
   cabledyn-deck show     deck [--caller-driven]
   cabledyn-deck set      deck output selector value [--overwrite] [--caller-driven]
   cabledyn-deck generate deck spec output_directory [--overwrite] [--caller-driven]

.. list-table::
   :header-rows: 1
   :widths: 22 18 15 45

   * - Argument
     - Type
     - Default
     - Meaning
   * - ``deck``
     - path
     - required
     - Source deck (all subcommands).
   * - ``--caller-driven``
     - flag
     - off
     - Validate against the host-driven (OpenFAST) marching-clock contract instead of the
       standalone one (all subcommands).
   * - ``output``
     - path
     - required (``set``)
     - Edited deck to write. It must not be the source deck itself (also checked through
       hard links and case-insensitive paths), even with ``--overwrite``.
   * - ``selector``
     - string
     - required (``set``)
     - Field to change; see the selector table.
   * - ``value``
     - JSON or text
     - required (``set``)
     - New value. Parsed as JSON when possible (number, string, ``true``/``false``, or list);
       otherwise used as a plain string. JSON ``null`` and objects are rejected. Negative
       numbers such as ``-1e-3`` are accepted as values rather than options.
   * - ``spec``
     - path
     - required (``generate``)
     - JSON file: an object mapping each case name to an object of ``selector: value`` pairs.
       Duplicate keys are rejected.
   * - ``output_directory``
     - path
     - required (``generate``)
     - Directory for the generated decks and ``cases.json``; created if missing.
   * - ``--overwrite``
     - flag
     - off
     - ``set``/``generate``: replace existing output files.

**Selectors.** Selector keywords, field names, and line-type names are case-insensitive.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Selector
     - Addresses
   * - ``option.KEY``
     - The effective (last) row of an existing ``OPTIONS`` keyword, including native aliases.
       A list value sets several values (``dynamic_solver`` and the positional ``waves`` and
       ``current`` forms); other options take one value. A missing option is an error; the
       editor does not add rows.
   * - ``point.ID.FIELD``
     - ``POINTS`` row ``ID``; fields ``id``, ``type``, ``x``, ``y``, ``z``, ``mass``, ``vol``,
       ``cda``, ``ca``.
   * - ``line_type.NAME.FIELD``
     - ``LINE TYPES`` row ``NAME``; fields ``name``, ``diam``, ``mass``, ``ea``, ``ba``,
       ``ei`` followed by ``cdn``, ``cdt``, ``can``, ``cat`` (CableDyn columns), ``cd``,
       ``ca``, ``cdax``, ``caax`` (MoorDyn-style columns), or ``gas``, ``gj``, ``irt``,
       ``irn``, ``cdn``, ``cdt``, ``can``, ``cat`` (14-column rows); an 11- or 13-column row
       adds ``cl`` or ``cl``, ``df``, ``cf`` (VIV).
   * - ``section.LINE.OCCURRENCE.FIELD``
     - The ``OCCURRENCE``-th section (1-based, End A to End B) of line ``LINE``; fields
       ``lineid``, ``linetype``, ``length``, ``numsegs``. A 7-column ``LINES`` row counts as a
       section at its position and takes ``lineid``, ``linetype``, ``nodea``, ``nodeb``,
       ``length``, ``numsegs``, ``outputs``.
   * - ``end_connection.LINE.END.FIELD``
     - ``END CONNECTIONS`` row for line ``LINE`` and end ``A``/``B`` (also ``EndA``,
       ``End_A``, ...); fields ``lineid``, ``end``, ``stiffness``, ``ezx``, ``ezy``, ``ezz``.

Values are written as single native tokens: integers as given, floating-point numbers with 17
significant digits (``0.1`` is written ``0.10000000000000001`` and ``1.0`` as ``1``), and
Booleans as ``True``/``False``. To write a number exactly as typed, pass it as a JSON string,
for example ``'"0.1"'``. Values containing whitespace, quotes, or comment markers are rejected.
An edit that would make the deck invalid is rejected and nothing is written.

**Subcommand behaviour and output.**

* ``validate`` prints ``valid: <absolute deck path>``.
* ``show`` prints ``deck``, then the counts ``line_types``, ``points``, ``lines``,
  ``sections``, ``end_connections``, ``options`` (option rows, including repeated keywords),
  and ``outputs`` (output channels).
* ``set`` applies one selector and prints the absolute path of ``output``. An ``output`` that is
  the source deck (by path, hard link, or case-insensitive alias) is refused with exit code 1,
  even with ``--overwrite``.
* ``generate`` builds and validates every case before writing any file, then writes
  ``<output_directory>/<case>.dat`` per case and ``<output_directory>/cases.json``, and prints
  each generated deck path. Case names must match ``[A-Za-z0-9][A-Za-z0-9_.-]*`` and be unique
  ignoring case, and the mapping must not be empty. Relative references to ancillary files
  (``SYROPE:`` working-curve files and the bathymetry/seafloor, motion, and wave-kinematics
  file options) are rewritten so they still resolve from the output directory. Without
  ``--overwrite``, the command fails if any target ``.dat`` or ``cases.json`` exists; other
  files in the directory are left alone. A target that is the source deck is always refused.

``cases.json`` (schema ``cabledyn-deck-cases-v1``) records the absolute source path, its
SHA-256, ``caller_driven``, and for each case its name, absolute deck path, deck SHA-256,
working directory, and the applied changes. ``cabledyn-study`` checks these digests, so a study
directory must not be moved or edited after generation.

**Exit codes.**

.. list-table::
   :header-rows: 1
   :widths: 10 90

   * - Code
     - Meaning
   * - 0
     - The subcommand completed.
   * - 1
     - Handled failure: the deck is unreadable or invalid; unknown or malformed selector;
       unknown record, field, or option; value that cannot be written as a native token or
       that makes the deck invalid; unreadable or malformed spec (invalid JSON, duplicate
       keys, wrong structure, invalid case name); output exists without ``--overwrite``; or
       another operating-system error.
   * - 2
     - Command-line usage error (argparse), including a missing subcommand or argument.

Example, with ``spec.json``:

.. code-block:: json

   {
     "shallow": {"point.1.z": -180},
     "deep": {"point.1.z": -220, "option.dtM": 0.0005}
   }

.. code-block:: text

   cabledyn-deck generate lazy_wave.dat spec.json studies/anchor_depth

cabledyn-study
~~~~~~~~~~~~~~

Runs every case of a ``cases.json`` written by ``cabledyn-deck generate`` through the native
driver, summarises each main output, and writes a study record. A failed case does not stop the
remaining cases.

.. code-block:: text

   cabledyn-study [-h] [--executable EXECUTABLE] [--output-directory OUTPUT_DIRECTORY]
                  [--jobs JOBS] [--timeout TIMEOUT] [--channel CHANNELS] [--start START]
                  [--stop STOP] [--overwrite]
                  manifest

.. list-table::
   :header-rows: 1
   :widths: 22 18 18 42

   * - Argument
     - Type
     - Default
     - Meaning
   * - ``manifest``
     - path
     - required
     - ``cases.json`` from ``cabledyn-deck generate``.
   * - ``--executable``
     - path
     - see *Locating the native driver*
     - Native driver to run.
   * - ``--output-directory``
     - path
     - ``<manifest directory>/study-results``
     - Destination for all results; created if missing.
   * - ``--jobs``
     - int
     - ``1``
     - Number of native processes run concurrently; must be positive.
   * - ``--timeout``
     - float, s
     - none
     - Per-case wall-clock limit; finite and positive. A case that exceeds it is killed and
       recorded as failed.
   * - ``--channel``
     - string, repeatable
     - every non-time channel
     - Main-output channel to summarise. Names must be non-empty and unique.
   * - ``--start``, ``--stop``
     - float, s
     - whole record
     - Statistics period; finite, with ``start`` not exceeding ``stop``.
   * - ``--overwrite``
     - flag
     - off
     - Allow a non-empty output directory. Existing result files of a case are replaced only
       when that case succeeds; a failed case restores them (as for ``cabledyn-run
       --overwrite``). Other files are left alone.

**Preflight.** Before any solver process starts, the command verifies the manifest schema, that
the source deck and every generated deck exist and match their recorded SHA-256, that case names
are safe and unique and deck paths distinct, that no case name collides with the output files
of another case (for example ``base`` and ``base.static``, ``base.modes``, ``base.Line1.V`` or
``base.Line1.range``), and the option values above. It
refuses a non-empty output directory without ``--overwrite``, locates the driver, records its
SHA-256, and queries its ``--version`` banner (10 s limit).

**Files written** in the output directory:

.. list-table::
   :header-rows: 1
   :widths: 35 65

   * - File
     - Content
   * - ``<case>.out`` and auxiliary files
     - Native results for each case, with output root ``<case>`` (see :doc:`outputs`).
   * - ``<case>.stdout.log``, ``<case>.stderr.log``
     - The complete captured native streams, written for every case, including failures.
   * - ``summary.csv``
     - One row per case and summarised channel with the columns ``case``, ``status``,
       ``elapsed_seconds``, ``channel``, ``unit``, ``count``, ``minimum``, ``maximum``,
       ``mean``, ``standard_deviation`` (population), ``rms``, ``error``. A case with no
       statistics keeps one row with empty statistic columns.
   * - ``study.json``
     - Schema ``cabledyn-study-results-v1``: manifest path and SHA-256, executable path and
       SHA-256, solver version banner, UTC start and finish times, ``jobs``, ``timeout``,
       ``period``, ``channels``, and per case its status, deck and digest, output paths, log
       paths, elapsed time, native return code, and error.

Each case ends with one of three statuses: ``completed`` (native exit 0 and statistics
computed), ``failed`` (the native process exited non-zero, timed out, or could not be started),
or ``postprocess_failed`` (the solver finished but its main output was missing or invalid, the
statistics failed, for example for an unknown ``--channel`` or an empty period, or the case
otherwise completed but one of its log files could not be written).

**Streams.** stdout receives one line per case in manifest order, ``<case>: <status>``
followed by ``: <diagnostic>`` for any case that recorded an error, then ``study_manifest: <path>``
and
``summary_csv: <path>``. Errors that stop the study go to stderr as
``cabledyn-study: <message>``.

**Exit codes.**

.. list-table::
   :header-rows: 1
   :widths: 10 90

   * - Code
     - Meaning
   * - 0
     - Every case completed; ``summary.csv`` and ``study.json`` were written.
   * - 1
     - The study ran and both records were written, but at least one case is ``failed`` or
       ``postprocess_failed``.
   * - 2
     - Command-line usage error (argparse), or the study could not be started: a preflight
       failure (manifest, digest, option, output-directory, or executable problem, or a failed
       ``--version`` query). No case has run.
   * - 3
     - The cases ran, but ``summary.csv`` or ``study.json`` could not be written (an
       operating-system error such as a full disk or a locked file). Per-case native outputs
       and logs already written are kept; the stderr message names the file that failed.
       The Python API raises ``StudyOutputError`` (an ``OSError`` subclass) in this case.

Interrupting the command (Ctrl+C) cancels cases that have not started, waits for running cases,
and exits with a Python traceback without writing ``summary.csv`` or ``study.json``.

Example:

.. code-block:: text

   cabledyn-study studies/anchor_depth/cases.json --jobs 2 --channel FairTen1 \
       --channel AnchTen1 --start 600 --stop 4200 --timeout 3600
