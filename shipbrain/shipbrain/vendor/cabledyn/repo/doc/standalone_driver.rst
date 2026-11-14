.. SPDX-License-Identifier: Apache-2.0

Standalone Windows driver
=========================

New users should work through :doc:`tutorial_standalone` and keep :doc:`options` open beside the
input deck. The runnable ``examples/cabledyn_options_reference.dat`` distinguishes active defaults
from commented mutually exclusive alternatives.

``CableDyn_driver.exe`` is the production command-line application for a complete CableDyn
deck. It parses the model, computes the static initial condition, optionally marches the
time-domain problem, and writes engineering output tables. The Windows release is one static
x64 executable: it does not need adjacent compiler, BLAS, OpenMP, MSVC, or Intel runtime DLLs.

Install and verify
------------------

Download ``CableDyn_driver.exe`` from a CableDyn Windows release and place it in a directory
of your choice. Either invoke it by full path or add that directory to ``PATH``.

.. code-block:: powershell

   C:\CableDyn\CableDyn_driver.exe --version
   C:\CableDyn\CableDyn_driver.exe --help

The banner identifies CableDyn and its version. Windows may display a SmartScreen warning for
an unsigned research executable; verify the release SHA-256 checksum before allowing it.

Run a case
----------

The interface has two positional arguments:

.. code-block:: text

   CableDyn_driver.exe <deck.dat> <output_root>

``output_root`` is a stem, not an output filename. Do not append ``.out``. For example:

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null
   C:\CableDyn\CableDyn_driver.exe examples\spread_3line_chain.dat results\spread3

The primary result is ``results\spread3.out``; its ``Time(s)`` column carries 17 significant
digits so time stamps stay exact on long records. The static configuration profile
``results\spread3.static.out`` is written by three routes: a static-only ``EI = 0`` deck (no
``dtM``/``TMax``), every production Hermite finite-EI deck (its initial configuration, together
with the element-extrema file ``spread3.elements.out``), and a mixed ``EI = 0`` plus finite-EI
deck. The independent ``EI = 0`` dynamic, point-system, rod, ``Rigid6`` and multibody routes write
no ``.static.out``. A deck
requesting per-line position or tension output can add ``spread3.Line<L>.p.out`` and
``spread3.Line<L>.t.out``; a dynamic rod deck can add ``spread3.Rod<R>.p.out``. See
:doc:`outputs` for channel names, units, and file layouts.

Before any solve, the driver checks its command line and output location. It exits with code
``1`` for an unknown dash-prefixed option, a wrong number of arguments, an empty argument or one
longer than 4096 characters, a deck or output root that cannot be opened exactly (for example a
reserved Windows device name), an output root one of whose result files would overwrite the deck
or a file the deck reads, an output directory that does not exist or cannot be written (checked
by creating and removing a ``<output_root>.write_check.tmp`` probe file), and an output root that
another running ``CableDyn_driver`` is writing. :doc:`cli` lists each check and its message.

Command-line options
~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Invocation
     - Effect
   * - ``CableDyn_driver.exe <deck.dat> <output_root>``
     - run the deck
   * - ``-v``, ``-V``, ``-version``, ``-VERSION``, ``--version``
     - print the banner to ``stdout`` and exit ``0``
   * - ``-h``, ``-H``, ``-help``, ``-HELP``, ``--help``, ``-?``, ``/?``
     - print the banner and usage to ``stdout`` and exit ``0``
   * - any other argument starting with ``-``
     - ``CableDyn_driver: unknown option "<arg>"`` and usage on ``stderr``; exit ``1``
   * - no arguments, or a number other than two
     - banner and usage on ``stderr``; exit ``1``

The version and help options are recognised only as the first argument.

Long-run progress
~~~~~~~~~~~~~~~~~

Every dynamic run prints a one-line progress record at approximately five-percent
intervals. The percentage is based only on committed CableDyn steps; elapsed wall time therefore
includes nonlinear iterations and guarded recovery work. ``ETA`` is the average committed-step
cost extrapolated over the remaining steps. The final record is always ``100.0%`` after the last
output row has been written. Static-only decks do not print a misleading progress estimate.

Mixed mooring and power-cable decks
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The standalone driver accepts a deck containing separate ``EI = 0`` mooring lines and finite-EI
power cables between ``Fixed`` and ``Coupled``/``Vessel`` points. It uses the same aggregate that
backs ``CompMooring = 5`` in OpenFAST (maintained by NLR, the National Laboratory of the Rockies,
formerly NREL) and advances the objects atomically. Every ``Coupled``/``Vessel`` endpoint is held
at its initialised position, or follows the deck's ``motionFile`` or ``vesselMotion`` (a vessel
turns the end connection and torsion frames of the power cables on its points, and the
``motionFile`` roll column twists a cable restrained in torsion, as on the single-cable route).
A ``TURBINES`` deck (:doc:`driver_format`) places its ``Turbine<J>`` points from the section, and
its per-turbine ``motionFile`` records move them and turn the frames of the cable ends on them
with their turbine, so a FAST.Farm shared-mooring deck of power cables and chain legs runs here
as a whole.
A mixed deck that also has bodies, rods or ``Connect``/``Free`` points runs on the multibody
march instead (:doc:`driver_format`), which accepts deck waves and current. ``examples/iea15mw_umaine_mixed_cabledyn.dat`` is the maintained four-line
example; its ``TMax = 0`` setting writes the common static configuration. Give a positive ``TMax``
to march held-end dynamics. A static-only mixed deck with no dynamic-only option may instead omit
both ``dtM`` and ``TMax``; the time-step option becomes mandatory when a positive-duration march
is requested.

A mixed deck takes the deck current (a ``current`` OPTION, a WaterKin ``CurrentMod 1`` table or
MoorDyn-C ``Currents 1``/``2``/``5``) in its static start and its march, as the single-line
routes do. It rejects deck waves by name, and with them ``vesselRAO``, which needs deck waves.
A ``vesselMotion`` record moves every ``Coupled``/``Vessel`` point rigidly with the vessel
(translation and rotation of each hang-off); a ``motionFile`` gives the
rows of each point. Row 1 is installed before ``t = 0``, also with ``TMax = 0``, after the
``.static.out`` of the static solve is written. On the ``EI = 0`` lines that transfer re-derives
the interior accelerations, which the ``EI = 0``-only route does not, so with row 1 off the deck
pose their first steps differ from that route's. Mixed-deck LINE ``Outputs`` flags ``p`` and
``t`` are rejected as well; request the needed mixed-deck quantities through the main
``OUTPUTS`` section instead (the ``r`` range graph is available).

Initialisation report
~~~~~~~~~~~~~~~~~~~~~

After the static solve succeeds, the driver prints an engineering initialisation report. The
stream depends on the route: single-family decks (all ``EI = 0``, or all finite-EI) print the
full report below to ``stderr``; a mixed ``EI = 0`` plus finite-EI deck prints a shorter
summary (line counts, then per line the fairlead tension, tangent inclination, and force vector) to
``stdout``. The report is unconditional: it covers every line object even when the deck does
not request endpoint channels in ``OUTPUTS``. For each line it gives the fairlead effective
tension, the global force vector exerted by the line on the fairlead with its inclination, and
three orientation quantities of the line tangent::

     Parsing CableDyn input file: examples\spread_3line_chain.dat
      Created CableDyn model: 3 line object(s), 6 point(s), 3 section(s) [EI=0: 3, finite-EI: 0].
      Initial conditions: Newton static equilibrium with load continuation completed.
      Fairlead convention: force is on End A toward End B; inclinations are signed below horizontal.
      Line 1 fairlead effective tension:  2.43712E+006 N
         force [Fx, Fy, Fz]: [ 1.35070E+006,  0.00000E+000, -2.02858E+006] N, inclination=   56.343 deg
         line tangent: inclination=   55.685 deg, declination=  145.685 deg, azimuth=    0.000 deg
      ...
     CableDyn initialization completed.

The force and tangent point from public End A (fairlead) into the line toward End B (anchor).
``inclination`` is zero for a horizontal direction, positive downward, and negative upward. The
force inclination differs slightly from the tangent inclination because the end force also carries
the end node's share of the distributed load (and, on a finite-EI line, the end shear).
``declination`` is the angle from global ``+Z`` (the convention also used by OrcaFlex): 0 degrees
up, 90 degrees
horizontal, and 180 degrees down. ``azimuth`` is measured from global ``+X`` toward ``+Y``, in
``(-180, 180]`` on a line heading within 45 degrees of ``+X`` and in ``[0, 360)`` otherwise
(:ref:`outputs-azimuth-range`). Therefore ``inclination = declination - 90 degrees``; the two values are printed
together deliberately so the convention is auditable.

For the production Hermite finite-EI route, the reported vector is the complete fairlead reaction,
including bending and distributed-load effects, also on a line whose End B moves.

Input-record style
~~~~~~~~~~~~~~~~~~

CableDyn's maintained decks follow the same readable convention as OpenFAST input files:
``value key - Description (unit) {choices}``. Put a physical unit after the description, omit
an empty unit marker for dimensionless settings, and list discrete choices in braces. The text
after the spaced hyphen is explanatory commentary and is not parsed as part of the value.

.. code-block:: text

   9.80665              g       - Gravitational acceleration (m/s^2)
   1.0e5                kBot    - Seabed penalty stiffness base (Pa/m)
   airy 2.0 8.0 0.0     waves   - Wave model, height, period, and direction (m, s, deg)
   staggered            bodyScheme - Multibody step scheme {monolithic; staggered}

Boolean values use initial capitals (``True`` / ``False``); choice keywords are written in lower
case, as in :doc:`options`. In ``OUTPUTS``, put one
double-quoted channel on each row, for example ``"FairTen1"``. This matches OpenFAST's OutList
presentation while keeping the CableDyn channel spelling unchanged.

Working-directory and path rules
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The command does not change the working directory. Resolve the following before launching a
production sweep:

* the deck path is relative to the terminal's current directory;
* the output root is relative to the terminal's current directory;
* files named inside a deck (motion histories, WaterKin data, bathymetry, and constitutive
  tables) are resolved relative to the **deck's** directory, not the current directory
  (:doc:`file_formats`); the MoorDyn-C fixed-name kinematics files are read from the deck's
  directory too;
* the output directory must already exist when invoking the native executable directly; the
  driver checks that it is writable before the static solve starts.

Running from the case directory is the least surprising convention:

.. code-block:: powershell

   Set-Location D:\cases\my_mooring
   New-Item -ItemType Directory -Force results | Out-Null
   C:\CableDyn\CableDyn_driver.exe .\model.dat .\results\baseline
   if ($LASTEXITCODE -ne 0) { throw "CableDyn failed with $LASTEXITCODE" }

Exit status and automation
--------------------------

.. list-table::
   :header-rows: 1
   :widths: 15 85

   * - Code
     - Meaning
   * - ``0``
     - the requested analysis completed with every nonlinear step converged, and the completion
       line was printed
   * - ``1``
     - the run was refused or its input could not be used: an unknown ``-`` option; a wrong
       number of arguments; an empty argument or one longer than 4096 characters; an output root
       whose result files would overwrite the deck or a file it reads; an output directory that is
       missing or not writable; an output root another run is writing; a deck or auxiliary file that
       cannot be opened or parsed; a value out of
       range; an unsupported feature combination; or an output file that cannot be opened during
       the run
   * - ``2``
     - the solve failed: an ``EI = 0`` static line did not converge; a finite-EI static
       initialisation did not converge or was rejected (the folded-branch ``max(h*kappa)`` check
       or the tensile-safety check); a dynamic step did not converge (including after recovery
       substeps); a converged dynamic step failed the ``maxStrain`` plausibility guard (an
       ``EI = 0`` element stretched beyond the bound, i.e. a numerically unstable march); a
       result became non-finite; or, in a Windows GNU build, ``openblas.dll`` could not be
       loaded at start-up. The ``.out`` keeps the converged prefix for inspection only

The reason is always in the stderr message, and the last stderr line of every such exit is the
closing line ``CableDyn_driver: ended with exit code <n>``. See :doc:`troubleshooting` for the
message-by-message fixes.

.. _run-ended-early:

When a run ends early
~~~~~~~~~~~~~~~~~~~~~

A run can also end without the driver choosing to. The output files then hold every row written
before the end, and their last time is below ``TMax``.

.. list-table::
   :header-rows: 1
   :widths: 24 76

   * - How it ended
     - What you see
   * - interrupted: Ctrl+C or Ctrl+Break, closing the console window, logging off or shutting
       down, ``SIGINT``, ``SIGTERM`` or ``SIGHUP``
     - ``CableDyn_driver: stopped by <cause> after the step at simulated time t = <t> s`` on
       stderr, followed by the Fortran runtime's own lines where it has them (the release
       Windows executable adds ``forrtl: error (200)`` and a traceback, and exits with a non-zero
       code, ``1`` or, when the traceback meets output in progress, ``152`` after ``forrtl:
       severe (152)``; a GNU build exits with ``0xC000013A`` on Windows and with the signal on
       Linux and macOS). Rows written while
       the process was stopping may extend slightly past the reported time
   * - a fatal fault, such as an access violation or a stack overflow
     - ``CableDyn_driver: fatal error: <cause> after the step at simulated time t = <t> s`` on
       stderr (on Windows the cause also names the exception code, the module and offset and,
       for an access violation, the address), possibly followed by the runtime's own report (``forrtl:
       severe (157)`` or ``(170)`` in the release Windows executable, which then exits with that
       number). Otherwise the exit status is the exception code (Windows) or the signal. Please
       report it, with the deck (see SUPPORT.md)
   * - ended from outside: *End task* in Task Manager, ``taskkill /F`` or ``kill -9``
     - nothing. These end a process without running any of its code, so no program can report
       them. ``taskkill /F`` leaves exit code ``1``, the code of a refused input, but without the
       closing line; ``kill -9`` leaves ``SIGKILL``

To tell a completed run from one that ended early, check the exit status, the closing line, and
that the last time in ``<output_root>.out`` reaches ``TMax``; the Python wrapper below reports
such an end. The driver states this contract at start, after the banner, with the line
``Exit status: every non-zero exit the driver makes itself ends stderr with
"CableDyn_driver: ended with exit code <n>".``;
a missing closing line means an outside end only when that line is present, since drivers of
version 0.1.0 and earlier write neither. ``taskkill /IM CableDyn_driver.exe /F`` ends *every*
CableDyn run on the computer, not one; to stop a single run, end it by its process id
(``taskkill /PID <pid> /F``).

Output streams
~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 15 85

   * - Stream
     - Content
   * - ``stderr``
     - the identity banner of a normal run and the ``Exit status:`` line after it; every error
       message; the initialisation report of a
       single-family (all ``EI = 0`` or all finite-EI) deck; the report of an interrupt or a
       fatal fault; and, last on a failed run, the closing line
       ``CableDyn_driver: ended with exit code <n>``
   * - ``stdout``
     - ``--version``/``--help`` output; the mixed-deck initialisation summary; the
       ``Dynamic simulation:`` header and ``Progress:`` records with elapsed time and ETA;
       ``Recovery audit:`` lines (dynamic ``EI = 0`` line and finite-EI routes, when recovery
       substeps were used); ``Tensile monitor:`` lines (finite-EI ``tensile_safety warn``);
       ``CableDyn: FAILURE ...`` event lines; and, last, the completion line
       ``CableDyn_driver: converged run written to <output_root>.out``

stdout is a human-readable log, not a machine-parseable stream. Scripts must check the process
exit status as well as the existence of the output; never assume stdout contains only the
completion line, and never infer success from a partially written file
left by an interrupted run. If a dynamic step does not converge, the driver returns code ``2``,
stops, and retains only the converged prefix of the ``.out`` history for diagnosis. That prefix
is not a completed result.

Python automation
-----------------

The :class:`cabledyn.CableDynDriver` wrapper applies these rules automatically: it finds the
executable, defaults the working directory to the deck directory, captures diagnostics, checks
the exit code, rejects stale output unless overwrite is explicit, and validates every numeric
row. A run that ended early raises :class:`cabledyn.DriverExecutionError` with a message that
says so and gives the time the output reached. See :doc:`python`.

Choosing the standalone driver or OpenFAST
-------------------------------------------

Use ``CableDyn_driver.exe`` when prescribed endpoints, a motion file, or a held-end model owns
the structural run. Use the CableDyn-enabled ``openfast.exe`` when turbine/platform motion and
SeaState kinematics must be exchanged with OpenFAST at every coupling step. The latter selects
CableDyn with ``CompMooring = 5`` and is covered in :doc:`openfast`.

``examples/iea15mw_umaine_openfast_cabledyn.dat`` is the caller-driven, mooring-only OpenFAST
``MooringFile`` deck; ``examples/iea15mw_volturnus_mooring.dat`` is a standalone static
calculation of one line of the same VolturnUS-S spread. In contrast,
``examples/iea15mw_umaine_mixed_cabledyn.dat`` is intentionally dual-use: OpenFAST consumes it
as a ``CompMooring = 5`` deck, while ``CableDyn_driver.exe`` accepts its held-end static or
positive-``TMax`` mixed standalone workflow described above.
