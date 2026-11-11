.. SPDX-License-Identifier: Apache-2.0

Troubleshooting
===============

CableDyn is designed to **fail closed with a clear message** rather than return a quiet wrong
answer. This page maps the messages you will actually see — a rejected deck, a solve that will
not converge, a combination outside the coupled boundary of OpenFAST (maintained by NLR, the
National Laboratory of the Rockies, formerly NREL) — to the reason and the supported path
forward. Questions about results and settings are answered in :doc:`faq`.

Exit codes at a glance
----------------------

.. list-table::
   :header-rows: 1
   :widths: 12 40 48

   * - Code
     - Meaning
     - First thing to check
   * - ``0``
     - completed; the completion line
       ``CableDyn_driver: converged run written to <out_root>.out`` is on stdout
     - —
   * - ``1``
     - the run was refused or its input could not be used: unknown option, wrong argument
       count, empty or over-long argument, output root equal to the deck, unwritable output
       directory, unreadable or unparseable deck or auxiliary file, out-of-range value,
       unsupported feature, or an output file that cannot be opened during the run
     - the stderr message names the file, line, keyword, or feature — see below
   * - ``2``
     - an ``EI = 0`` static line or a dynamic step did not converge, a finite-EI static
       initialisation failed or was rejected, or a result became non-finite. A message
       starting ``plausibility guard:`` means a converged dynamic step produced an element
       strain beyond ``maxStrain`` (default 50 %) — a numerically unstable march, not a
       physical load. A Windows GNU source build also stops with code 2 when it cannot load
       its LAPACK library (``openblas.dll``)
     - geometry, mesh, time step, and continuation — see :ref:`Non-convergence <non-convergence>`;
       for the plausibility guard, reduce ``dtM`` first; for a missing library, see the last
       section of this page

The complete stream and exit-code contract is in :doc:`standalone_driver`. Error messages are on
**stderr**. If you redirected it away (``2>/dev/null``), rerun without the redirect.

A run that stops before ``TMax`` with no error message and without the closing line
``CableDyn_driver: ended with exit code <n>`` was ended from outside the driver, for example by
``taskkill /F`` (which leaves exit code ``1``) or *End task*; ``taskkill /IM CableDyn_driver.exe``
ends every CableDyn run on the computer at once. An interrupt or a fatal fault is reported on
stderr with the simulated time reached. See :ref:`run-ended-early`.

Reading an error message
------------------------

A row-level parse error names the file and line and quotes the offending row::

   CableDyn_DeckDriver: deck line 42: column 3 value "500/2" contains "/", ",", ";" or a repeat count "n*"; ... [row: 1 chain 500/2 ...]

Auxiliary files use their own label in place of ``deck`` (for example ``motionFile line 7`` or
``bathymetry file line 3``). Validation errors that are not tied to one row name the object
instead: a duplicate or undefined id is quoted in the message (``duplicate POINT id 4``,
``LINE 2 references undefined POINT id 9``).

A solver failure message is not cut off by a fixed-size buffer: it can run to several hundred characters (the tensile
qualification failure of a dynamic step names the element, the force, its limit, and the remedy),
the driver prints it whole, and the C API retains up to 4096 characters per handle.

.. _deck-rejected:

A deck is rejected (exit 1)
---------------------------

Fail-closed at parse is a *feature*: it means the deck named something CableDyn will not
silently reinterpret. The tables below are grouped by message class.

Command line and files
~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 42 58

   * - Message
     - Cause and fix
   * - ``unknown option "--x"``
     - only ``-h``/``--help`` and ``-v``/``--version`` (as the first argument) are options; any
       other argument starting with ``-`` is refused before the deck is read.
   * - usage printed on stderr, no other message
     - the driver needs exactly two arguments: ``<deck.dat> <out_root>``.
   * - ``argument N is longer than 4096 characters`` / ``command-line argument N is empty``
     - shorten the path (run from the case directory and use relative paths) or supply the
       missing argument.
   * - ``would overwrite the input deck``
     - the output root is the deck's own stem, so ``<out_root>.out`` or ``<out_root>.static.out``
       would be the deck. Choose a different root; do not append ``.out`` to it.
   * - ``cannot write output files at "<root>"``
     - the output directory does not exist or is not writable. Create it first; the driver does
       not create directories.
   * - ``the name has characters the Windows ANSI code page cannot represent``
     - only a driver built from source with the GNU toolchain gives this: the name is outside
       the system code page and the volume has no 8.3 short name for it. Use the release
       ``CableDyn_driver.exe``, which accepts names in any script, or rename the folder.
   * - a file in a folder with accented or non-Latin characters is not found, with an older
       or self-built executable
     - the release executables run with UTF-8 as their Windows code page and open such folders
       (Windows 10 version 1903 or later). An executable built without
       ``app/utf8_code_page.manifest`` uses the system ANSI code page; run it from a folder whose
       name that code page can spell.
   * - ``cannot open deck`` / ``cannot open motionFile`` / ``cannot open bathymetry file`` /
       ``cannot open the WaterKin file`` / ``cannot open Syrope settings file`` /
       ``cannot open Syrope OWC table``
     - a referenced file is missing or unreadable. Paths inside a deck are resolved relative to
       the deck's directory (the OWC table relative to the Syrope settings file), not to the
       terminal's current directory. A ``#`` or ``!`` in a path starts a comment and truncates
       it.
   * - ``cannot open output file`` (during the run)
     - an output file became unwritable after the start-up check (for example, it is open and
       locked in another program). Close it and rerun.

Records, tokens, and sections
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 42 58

   * - Message
     - Cause and fix
   * - ``deck line N: column C value "500/2" contains "/", ",", ";" or a repeat count``
     - a table value that is not one plain number. CableDyn never reads ``500/2`` as ``500``,
       ``400,0`` as ``400``, or ``2*200`` as two values. Write the number with a ``.`` decimal
       point; quote a text value (for example a type name) that must contain such a character.
       The same rule applies to numeric ``OPTIONS`` values (``1/20 dtM`` is rejected as
       ``malformed numeric OPTION value``) and to ``motionFile``, bathymetry, WaterKin, and
       Syrope table rows.
   * - ``deck line N is longer than 512 characters``
     - a record whose text outside a ``#``/``!``/``--`` comment does not fit the record buffer.
       Split a long ``OUTPUTS`` list over several rows or move commentary behind ``#``. Long
       comment lines are accepted. Auxiliary files report the same error with their own label.
   * - ``unknown deck section "<NAME>"``
     - a record containing ``---`` is always read as a section header. Use one of the header
       names listed in :doc:`driver_format`, and keep ``---`` out of data rows and descriptions.
   * - ``LINE TYPES row needs 10 cols ...`` / ``POINTS row needs 5 ... or 9 ...`` /
       ``LINES row needs 3 ..., 4 ..., or the stock 7 cols ...`` /
       ``SECTIONS row needs 4 cols``
     - a row with the wrong number of columns. A stray comment without ``#``/``!`` or an
       unquoted name with a space adds a column.
   * - ``malformed LINES row: attachment X must be an unquoted point id or rod end (R<N>A,
       R<N>B)``
     - a LINES attachment is neither a point id nor a rod end. Rod ends can be named directly
       (``R1A``, ``Rod1B``); CableDyn creates the end point. A body attachment needs a POINT of
       type ``Body<N>``; attach the line to that point id.
   * - ``OUTPUTS channel name "..." is longer than 64 characters``
     - shorten the channel; valid channel names are far shorter than the limit.
   * - ``unknown OPTION keyword "..."``
     - a typo in an ``OPTIONS`` keyword, or a keyword that does not exist (for example
       ``staticRelTol``: static tolerances are built in; dynamic Newton controls use
       ``dynamic_solver``). Check the spelling against :doc:`options`.
   * - ``unknown OPTION keyword "2.0"`` on a ``current``/``waves`` row
     - text after the terminal ``waves``/``current`` keyword that is not introduced by a spaced
       ``-`` adds tokens and hides the positional form. Write ``airy 2.0 8.0 0.0 waves -
       description`` or move the text behind ``#``.
   * - ``malformed logical OPTION value`` / ``malformed tensile_safety value``
     - use one of the spellings listed in :doc:`options` (``True``/``False``; ``warn`` for
       ``tensile_safety``).
   * - ``ICmode is not an option``
     - CableDyn always solves the static equilibrium directly; delete the ``ICmode`` row.
   * - a channel like ``Point2px_raw`` is rejected
     - an ``OUTPUTS`` channel that does not match a supported form, names an unknown id, or has
       trailing text. See the exact channel grammar in :doc:`outputs`.

Clock, motion, and environment
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 42 58

   * - Message
     - Cause and fix
   * - ``dynamic run requires both dtM and TMax options``
     - the standalone driver needs both or neither. Add the missing one; ``TMax = 0``, a check of
       the static start, needs no ``dtM``.
   * - ``OPTIONS TMax must be an integer multiple of dtM``
     - choose ``TMax = n·dtM`` exactly (for example ``dtM = 0.05``, ``TMax = 600``).
   * - ``standalone OPTION current requires dtM and TMax`` (likewise ``waves``, ``motionFile``,
       ``frictionMu``, ``RODS``, ``Rigid6 BODY``, ``Point3 BODY``, ``Connect``/``Free`` points,
       ``finite-EI section (EI>0)``)
     - these features act only in a dynamic march. Add ``dtM``/``TMax``, ``TMax = 0`` to check the
       static start, or remove the feature for a static calculation. A mixed ``EI = 0`` + finite-EI deck may run static without them. A
       coupled (caller-driven) deck takes its clock from the host, so ``current`` and ``frictionMu``
       need no ``dtM`` there.
   * - ``OPTION waves requires WtrDpth``
     - waves need a flat depth; a ``bathymetryFile`` alone does not satisfy the wave model.
   * - ``seabed friction is not supported on decks with Connect/Free points, bodies or rods on
       this route (coupled Rigid6/ROD decks, point decks and the staggered body scheme)``
     - these routes have no seabed friction. Remove ``frictionMu``, or run a standalone body or
       rod deck on the default ``monolithic`` body scheme.
   * - ``OPTION nModes is not supported for mixed EI=0/finite-EI decks; remove it or set it to 0``
     - a deck that mixes ``EI = 0`` and finite-EI lines writes no modal files. Run the modal
       analysis on a deck whose lines are all ``EI = 0`` or all finite-EI.
   * - motionFile ``time is outside the dtM/TMax grid``
     - every row time must be ``k·dtM`` with ``k ≥ 0`` (rows after ``TMax`` are not used).
       Resample the history onto the ``dtM`` grid.
   * - ``... requires dtM and TMax; to check a dynamic deck's static start only, give dtM with
       TMax = 0``
     - the deck asks for the march (motion, current, waves, bodies, rods, finite-EI sections,
       ``RangeStart`` ...) without ``TMax``. Keep the deck and set ``TMax = 0``: the run solves
       the static start and writes the ``t = 0`` row.
   * - ``motionFile must provide every Coupled/Vessel point at every dtM time`` (or ``every
       eligible prescribed point``)
     - the file is missing at least one (point, time) pair. Every prescribed point needs a row at
       every grid time, including ``t = 0`` and ``t = TMax``.
   * - motionFile ``rows must be: time point_id x y z vx vy vz ax ay az``
     - a row has fewer than eleven plain numbers, or a header line is not commented. Comment
       header lines with ``#``.
   * - motionFile ``... which is not Coupled/Vessel`` / ``duplicate row for point``
     - the ``point_id`` is not a prescribed point, or a (point, time) pair appears twice.
   * - ``Connect/Free dynamic-point deck does not support motionFile coupling``
     - this route holds its coupled endpoints. Remove ``motionFile`` or separate the model.
   * - ``bathymetry file must define one complete rectangular grid`` / ``grid is incomplete`` /
       ``duplicate x/y entries`` / ``needs at least a 2x2 grid`` / ``depths must be positive``
     - the ``x y depth`` rows must cover every combination of the distinct ``x`` and ``y``
       values exactly once (any order), with at least two of each and positive depths.
   * - ``OPTIONS WtrDpth and bathymetryFile are mutually exclusive``
     - keep one seabed definition.
   * - ``Wheeler stretching is undefined: the wave trough reaches the seabed``
     - the wave trough is at or below the seabed (``depth + eta <= 0``). Reduce the wave height or
       increase ``WtrDpth``; the model is not valid in that sea state.
   * - ``WaterKin WaveKinMod 2/SEASTATE is coupled-only``
     - ``SEASTATE``, ``WaveKinMod 2``, and ``CurrentMod 2`` take kinematics from the OpenFAST
       SeaState field. In the standalone driver use ``WaveKinMod 0``/``1`` and ``CurrentMod 0``/
       ``1``, or native ``waves``/``current`` rows.
   * - ``WaterKin WaveKinMod 1 is supported only by the standalone driver``
     - an elevation-history file cannot drive a coupled run or a mixed standalone deck. Put the
       sea state in SeaState (coupled) or use a single-family standalone deck.
   * - ``WaterKin WaveKinMod 1 requires ...`` / ``WaveKinFile ...``
     - ``WaveKinMod 1`` needs a ``WaveKinFile`` of at least four finite ``time elevation`` rows
       starting at ``t = 0`` with increasing times, a positive ``dtWave``, and a positive
       ``TMax``; it cannot be combined with a ``waves`` OPTION or ``CurrentMod 2``.
   * - ``... BOTH a current OPTION and a WaterKin current (double-counting)``
     - keep either the ``current`` row or the WaterKin ``CurrentMod 1`` table.
   * - a WaterKin wave/current combination is rejected
     - the requested host and file sources cannot be separated by the nodewise fluid sampler
       without double counting. Use independent sources that :doc:`capabilities` lists, or move
       the complete environment into OpenFAST SeaState.

Model data
~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 42 58

   * - Message
     - Cause and fix
   * - ``has a non-finite property`` / ``POINT has non-finite position or load data`` /
       ``BODY has non-finite data`` / ``motionFile contains a non-finite value``
     - a ``NaN`` or ``Inf`` reached the deck, usually from a generating script. Fix the source
       value; CableDyn does not substitute defaults.
   * - ``LINE End A fairlead (NodeA) must not be below End B anchor (NodeB)``
     - End A is the fairlead/upper end. A stock anchor-first row (``Fixed`` NodeA, fairlead NodeB)
       is swapped automatically; this message means the fairlead point itself lies below the
       anchor. Check the point coordinates.
   * - ``LINE End A (NodeA) must be Coupled/Vessel/Body<N> ...`` / ``LINE <L> End B (NodeB, POINT
       <n>, <type>) must be a Fixed (anchor) point``
     - in a deck without dynamic points every ``EI = 0`` line runs from a fairlead to an anchor. An
       ``EI = 0`` line between two Coupled points (a shared line) is supported only between two
       ``Turbine<J>`` fairleads of a FAST.Farm deck; it can also be split into two lines that meet
       at a ``Connect`` point in the middle (each line then ends on one Coupled point, and the deck
       becomes dynamic and needs ``dtM`` and ``TMax``). A finite-EI line may join two
       ``Coupled``/``Vessel`` points (both ends driven); its End B on any other moving point is
       refused (``finite-EI LINE <L> End B ... must be a Fixed (anchor), Coupled or Vessel
       point``), and it cannot be split at a ``Connect`` point (beside ``Connect`` points a
       finite-EI cable needs a Fixed End B): anchor it, or end it on a ``Coupled``/``Vessel`` point.
   * - ``finite-EI LINE <L> in a mixed-topology deck: End B is POINT <n> (<type>); a cable end on a
       Free/Connect point or a Point3 buoy ... is not supported``
     - a deck with ``Connect``/``Free`` points, bodies or rods that also has finite-EI cables
       drives each cable by the objects at its ends: End B must be a ``Fixed`` point, a Rigid6
       ``Body<N>`` point or a rod end. A cable that ends on a ``Connect``/``Free`` point or a
       ``Point3`` buoy (a junction with other lines, a buoy, a pliant-wave hang-off) is not
       supported in a deck marched as one multibody system. End the cable on a Fixed point, a
       body or a rod end, or run the cable and the lines it joins as separate decks.
   * - ``static body/rod equilibrium with the bending end loads of finite-EI LINE <L> (its End A|B,
       on a body or rod) did not converge after 60 passes (relative end-load change ...,
       tolerance ...)``
     - the static passes that balance a finite-EI line between two objects on its cubic-Hermite
       end loads (Anderson-accelerated) did not settle; the line's bending couples the objects
       more strongly than their own restoring holds them. The passes stop at a change of 1e-7 of
       the end-load scale (1e-10 with torsion), or at the resolution each pass's balance of the
       objects leaves (four times its residual load) where that is larger, so a change above the
       reported tolerance is not round-off. Restrain the object more stiffly (its moorings or
       ``C44``/``C55``) or soften the connection (a finite ``Stiffness``, a ``Pinned`` end or a
       finite ``TorsStiffness``); ``OPTION bodyIC deck`` skips the balance and starts the objects
       out of equilibrium at their deck poses.
   * - ``finite-EI LINE <L>: a Coupled/Vessel End B (POINT <n>) would need motionFile coupling to
       drive it``
     - the multibody march takes no ``motionFile``, so it has nothing to drive a ``Coupled``/
       ``Vessel`` end with. End the cable on a Fixed point, a Rigid6 body point or a rod end.
   * - ``finite-EI LINE <L>: a Coupled/Vessel End A (POINT <n>) would need motionFile coupling
       to drive it``
     - a mixed-topology deck that has ``Connect``/``Free`` points or bodies is marched as one
       multibody system, which does not take ``motionFile`` coupling, so nothing would drive a
       finite-EI cable on a Coupled End A. Attach the cable to a Rigid6 body, a rod end or a
       Fixed point. Or remove the ``Connect``/``Free`` points so the deck becomes a coupled mixed
       deck (the ``EI = 0`` lines on the Coupled point directly): a host (OpenFAST
       ``CompMooring = 5`` or the C API) drives its Coupled points, and the standalone driver
       runs it with them held still (that route takes no ``motionFile`` either).
   * - ``the deck waves OPTION is not supported for a standalone mixed EI=0/finite-EI deck`` /
       ``the MoorDyn-C WaveKin <n> waves are not supported for a standalone mixed EI=0/finite-EI
       deck``
     - the standalone driver marches the deck current of a mixed ``EI = 0``/finite-EI deck but no
       deck waves. Remove the ``waves`` OPTION (or ``WaveKin``), run a deck whose lines are all
       ``EI = 0`` or all finite-EI (those standalone routes evaluate the deck waves), or couple
       the deck to OpenFAST (``CompMooring = 5``) with SeaState, which supplies them.
   * - ``the deck current OPTION is not supported in FAST.Farm`` / ``the deck waves OPTION ...``
     - the shared mooring of a FAST.Farm farm runs in still water (no fluid field spans the
       farm). Remove the ``waves``/``current`` OPTION.
   * - ``POINT <n> (Fixed) lies below the seabed ... by <d> m, more than the <tol> m seabed
       tolerance``
     - a Fixed anchor within ``max(1 mm, 1e-5 |z_seabed|)`` of the seabed (``-WtrDpth``, or the
       bathymetry surface) rests on it and is placed on it. A deeper anchor is never moved
       silently: set its ``Z`` to the seabed elevation named in the message, or higher.
   * - ``finite-EI section (EI>0) requires a dynamic deck with dtM and TMax``
     - a single-family finite-EI deck is solved by the dynamic finite-EI workflow. Add
       ``dtM``/``TMax`` (``TMax = 0`` gives the static configuration only).
   * - ``is net-buoyant (dry mass <= displaced water mass)``
     - an ``EI = 0`` section whose dry mass ≤ displaced mass (a buoyant arch) is outside the EI = 0
       route — a lazy-wave arch needs the finite-EI path. Give the buoyant section an ``EI > 0``
       line type, or specify it by target submerged weight (the ``EQUIVALENT BUOYANCY`` block in
       :doc:`driver_format`).
   * - ``is neutrally buoyant (its dry mass equals the displaced water mass to within a
       relative 1e-6)``
     - the net-buoyant rejection above (dry mass ≤ displaced mass, unchanged) of an ``EI = 0``
       line type whose dry mass lies less than a relative 1e-6 (the precision of a typed mass)
       below the displaced water mass: it has no net weight, so a slack line of it is
       weightless and its static shape is indeterminate (every slack shape balances). Give the
       line type weight (a larger ``MassDenInAir``), or use a finite ``EI`` with a tension that
       holds the line taut.
   * - ``the viscoelastic dynamic stiffness Ed (EA = Es|Ed) must be finite and exceed the static
       Es``
     - ``Ed`` must be strictly greater than ``Es``; equal values make the series spring infinite.
       For ``Es|alphaMBL|vbeta`` both extra values must be positive. Viscoelastic types need
       ``EI = 0``.
   * - ``a LINE TYPES BA entry cannot have more bar-separated values than its EA entry``
     - write ``BA`` as one value for a plain EA and at most ``Bs|Bd`` for a viscoelastic EA.
   * - ``a Syrope line does not support finite-EI bending`` / ``a Syrope line must be a single
       section`` / ``must be taut at init`` / ``has no static output``
     - a Syrope line is one ``EI = 0`` section, taut at initialisation, marched with
       ``dtM``/``TMax``; it takes the seabed, Morison loads, current, waves and host fluid of any
       ``EI = 0`` line. Adjust the model accordingly.
   * - ``Syrope alpha and beta ... must be positive`` / ``the Syrope BA column needs two parts`` /
       ``the Syrope settings file needs OWC, WCType, k1, and k2 rows``
     - see the Syrope column rules in :doc:`driver_format`: ``EA = SYROPE:<file>|alpha|beta``
       with positive ``alpha``/``beta``, ``BA = BA_s|BA_d`` non-negative with a positive sum.
   * - ``SYROPE IC references undefined LINE id``
     - the ``SYROPE IC`` section must come after ``LINES``; also check the line id.
   * - ``Point3 BODY requires Mass > 0 ...`` / ``Point3 BODY currently supports exactly one
       Body<N> attachment point``
     - a ``Point3`` body needs positive mass, non-negative ``Vol``/``CdA``/``Ca``, and exactly
       one ``Body<N>`` point.
   * - ``Rigid6 BODY requires Mass/Ixx/Iyy/Izz > 0 ...`` / ``BODIES row needs 15 cols plus
       optional Ixx Iyy Izz``
     - a ``Rigid6`` row needs the three trailing inertias (18 columns), all positive.
   * - ``Rigid6 dynamic deck cannot mix ...`` / ``Rod dynamic deck cannot mix ...``
     - each standalone route owns one object family. Split the model or use the combinations
       listed in :doc:`capabilities`.
   * - ``a ROD may have at most one Rod<N>A point and one Rod<N>B point`` /
       ``Coupled/Vessel ROD requires a motionFile (or a coupled host)`` / ``ROD endpoints must
       define a positive length``
     - remove the duplicate rod-end POINT row (the end points are created automatically when a
       line names the rod end), supply ``motionFile`` rows for both ends of a prescribed rod, and
       give the rod distinct end coordinates.
   * - ``FAST.Farm Turbine<J> decks are consumed by the CompMooring=5 aggregate path only``
     - ``Turbine<J>`` points use turbine-local coordinates. Run the deck through FAST.Farm, or
       replace them with ``Coupled`` points in global coordinates for a standalone run.
   * - ``END CONNECTIONS requires a finite-EI line`` / ``non-pinned END CONNECTIONS need End B on
       a Fixed, Coupled or Vessel point``
     - bending end connections apply only to ``EI > 0`` lines whose End B is an anchor or a
       ``Coupled``/``Vessel`` point (a second driven end), not a ``Connect``/``Free`` point.
   * - ``a clamped or elastic END CONNECTION on a body or rod needs bodyScheme monolithic`` /
       ``a torsional END CONNECTION on a body or rod needs bodyScheme monolithic`` /
       ``the END CONNECTION direction on a rod end must be parallel to the rod axis``
     - remove ``staggered bodyScheme``; on a rod end give the direction along the rod axis
       (either sense).

Torsion
~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 42 58

   * - Message
     - Cause and fix
   * - ``END CONNECTIONS row needs 6 columns ..., or 10 or 11 with the torsion columns``
     - a torsion row is ``LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ
       [Pretwist]``; see :doc:`driver_format`.
   * - ``END CONNECTIONS torsional stiffness must be finite and non-negative, Free, or Rigid`` /
       ``torsion reference normal (NxX NxY NxZ) must be non-zero`` / ``must not be parallel to
       the direction Ez``
     - give ``Free``, ``Rigid`` or a stiffness in N·m/rad, and a reference normal that is not
       along ``Ez``.
   * - ``line <L>: the imposed twist Pretwist(B) - Pretwist(A) = ... deg exceeds 1000 turns``
     - the static twist is ramped in stages of at most 45°, so it is limited to 1000 turns; check
       the units of ``Pretwist`` (degrees).
   * - ``line <L> is torsionally restrained at both ends: its LINE TYPES row ... must give an
       explicit GJ > 0``
     - torsion has no ``EI/1.3`` default: use the 14-column ``LINE TYPES`` row with ``GJ`` (and
       positive ``GAs``, ``Irt``, ``Irn``) for every section of the line.
   * - ``torsional END CONNECTIONS ... require a finite-EI line`` / ``need End B on a Fixed,
       Coupled or Vessel point or a Rigid6 body point``
     - torsion is solved on cubic-Hermite lines whose End B is an anchor, a ``Coupled``/
       ``Vessel`` point or a Rigid6 body point (both end frames then turn with their parents).
   * - ``a torsional END CONNECTION on the end of ROD <N> (...) is not supported: a free or
       pinned rod is axisymmetric`` / ``on the end of Coupled/Vessel ROD <N> is not supported`` /
       ``on a body needs a Rigid6 body``
     - outside the torsion scope (:doc:`capabilities`). A free or pinned rod has no roll angle
       about its own axis, so it cannot hold the torque. Move End A to a ``Fixed`` rod, a rod fixed
       to a Rigid6 body (``RODS`` type ``Body<N>``), a Rigid6 body or a ``Fixed`` point (a
       ``Coupled``/``Vessel`` End A only in a deck without bodies and rods: a deck with them runs
       on the multibody march, which takes no ``Coupled`` End A for a finite-EI line).
   * - ``a torsional END CONNECTION on a rod end is not supported at End B`` / ``on a rod end
       needs a Fixed End B``
     - a rod end holds a torsion frame at End A only, with a ``Fixed`` End B. Restrain the line
       through its End A at the rod end, or end it on a ``Fixed`` point at a ``Fixed`` rod end's
       position; that rod's ``Rod<N>`` loads then leave its force out.
   * - ``a line restrained in torsion needs a host that turns its fairlead frame``
     - the C API's ``CableDyn_InitDeck``/``InitDeckAt`` move the line ends by translation only.
       Run the line in a coupled OpenFAST or FAST.Farm run or in the standalone driver,
       initialise a C API handle with ``CableDyn_InitDeckRotating`` and pass the host's
       rotations, or set ``TorsStiffness Free`` in every ``END CONNECTIONS`` row.
   * - ``torsion: the twist would move more than pi/2 from its committed value``
     - the host turned a fairlead by more than 90° about the line's end direction without a
       step (an output probe or a non-stepping input update). Keep the platform turn per
       coupling step well below 90°.
   * - ``a body holding a line restrained in torsion turns by more than 90 deg in one step even
       after 6 step halvings``
     - the body turns faster than one step can follow the twist; reduce ``dtM``.
   * - ``torsion in a dynamic run needs the force-blended generalised-alpha (OPTION
       alpha_force_blend True)``
     - remove ``False alpha_force_blend`` from a deck with torsion.
   * - ``OUTPUT "Torq...": line <L> is not torsionally restrained (END CONNECTIONS
       TorsStiffness), so it carries no torque`` / ``... line <L> is torsionally restrained at
       one end only and its torsion is not solved: <reason>``
     - a ``Torq``/``Twist`` channel needs a line solved in torsion: restrained at both ends, or
       at one end with the other free to twist; the second message gives the rule a line
       restrained at one end missed (see the note below).
   * - ``motionFile: point <id> has a non-zero roll column, but no line restrained in torsion
       (END CONNECTIONS TorsStiffness) at its moving (non-Fixed) end has that end there`` /
       ``the roll column of point <id> must
       be 0 at t = 0`` / ``gives the roll column (12th) on some rows only`` / ``the roll column
       (12th, degrees) must be a finite number``
     - the roll column drives the frame of a torsional line's moving end, starts from 0 (put a
       constant twist in ``Pretwist``), and appears on every row of the point or on none
       (:doc:`file_formats`).

FAILURE and CONTROL sections
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 42 58

   * - Message
     - Cause and fix
   * - ``FAILURE row needs 5 cols`` / ``FAILURE row has trailing content``
     - write ``FailID Point Lines FailTime FailTen`` with the line list comma-separated and no
       spaces (``1,2``).
   * - ``FAILURE FailIDs must be sequential from 1``
     - number the rows 1, 2, 3, … in deck order.
   * - ``FAILURE ... lists line L, which is not attached to point P``
     - every listed line must end at the failing point.
   * - ``FAILURE needs FailTime > 0 or FailTen > 0``
     - a row with both triggers at zero could never fire.
   * - ``FAILURE at a rod end (R<n>A/R<n>B) is not supported``
     - failures act on POINTS; name the point id (``P<n>`` or an integer).
   * - ``FAILURE requires a dynamic deck`` / ``FAILURE is not supported on finite-EI decks`` /
       ``... on ROD decks`` / ``FAILURE deck does not support motionFile coupling``
       / ``... seabed friction``
     - FAILURE runs on the ``EI = 0`` point-system and Rigid6 dynamic routes without rods,
       ``motionFile``, or ``frictionMu``.
   * - ``FAILURE on a Rigid6 BODY deck does not support Connect/Free or Point3 body points``
     - a FAILURE deck with Rigid6 bodies runs on the staggered body scheme, which takes the
       bodies and their lines only; model a clump or buoy on the line as part of a body.
   * - ``this entry point does not support the CONTROL section``
     - the standalone driver does not consume CONTROL. Line control is an OpenFAST
       ``CompMooring = 5`` feature; remove the section for a standalone run.
   * - ``CONTROL row has trailing content`` / ``line L is assigned to more than one CONTROL
       channel``
     - write ``ChannelID Lines`` with a comma list without spaces, and assign each line once.
   * - ``control channel C commands DeltaL = ... m on EI = 0 line L, outside MoorDyn-F's
       bounds -S/2 <= DeltaL <= S (S = UnstrLen/N = ... m)`` (or ``on finite-EI line L``)
     - the command lengthens the line's fairlead-side segment by more than ``UnstrLen``/N (the
       line's unstretched length over its number of segments) or shortens it by more than half
       of that, where MoorDyn-F also stops. Keep ``CableDeltaL`` within the bounds, or mesh the
       line with fewer, longer segments so the command is a smaller fraction of one.
   * - ``control channel C commands DeltaL = ... m on ... line L, which would make its controlled
       segment (... m long) non-positive``
     - on a line of several sections the controlled segment is shorter than half of
       ``UnstrLen``/N, so a haul-in within MoorDyn-F's bounds would consume it. Keep the
       haul-in shorter than the segment, or make the fairlead-side section's segments longer.
   * - ``CONTROL line L: active line control of a finite-EI line needs the force-blended
       generalised-alpha (OPTION alpha_force_blend True)``
     - the configuration blend has no committed-length treatment, so a ramp would lag; remove
       ``False alpha_force_blend`` from a deck that controls a finite-EI cable.

.. _non-convergence:

A solve does not converge
-------------------------

An ``EI = 0`` static line that does not converge, or a dynamic step that does not converge after
the recovery substeps, ends the run with exit code ``2``; the ``.out`` holds the converged prefix
for inspection only. A finite-EI static initialisation failure (``finite-EI cable static solve
failed`` or ``unresolved/kinked finite-EI equilibrium``) also ends the run with exit code ``2``.

The ``EI = 0`` catenary path and the finite-EI static solve are both robust from a trivial seed,
but a few geometries are genuinely hard:

- **A large grounded touchdown on the** ``EI = 0`` **path.** A long, near-horizontal grounded run can
  make the linear-Lagrange tangent singular regardless of seed. If the case is a lazy-wave or
  bending-dominated cable, use the finite-EI path (``EI > 0``), which is built for it.
- **A weightless finite-EI line longer than its span.** Every element has zero net weight (to a
  relative 1e-6 of its displaced weight, attachments included), so the line has no catenary: it
  bows under the axial compression its bending stiffness carries (the Euler elastica). It is
  solved, with the note ``line N is weightless and longer than its span``: nothing in the deck
  chooses the plane or the side of the bow, so it is solved bowed downward in the vertical plane
  through its ends, the limit of a vanishing net weight, and the bow can turn about the chord at
  no cost. If the line has a net weight, however small, give it (``MassDenInAir``) to settle
  the shape; a light line, heavy or buoyant, bows toward its weight
  (:doc:`solver_paths`, weight continuation). With its ends one above the other nothing chooses
  the side of the bow: ``the weightless (neutrally buoyant) line is longer than its vertical
  span`` stops the run. In a current, with attachments, over a non-level seabed, under
  ``tensile_safety True`` or with an end connection out of the plane of the chord the
  continuation does not apply, and a line the routes cannot solve stops with ``the weightless
  (neutrally buoyant) line is longer than its span``. Shorten the line to its span, or give it
  net weight (a larger ``MassDenInAir``, or clumps) or a tension that holds it taut. A line
  heavier than water that is too long for its span gets ``the net-heavy line is too long for
  its span to hang as a catenary`` instead.
- **A finite-EI lazy-wave cable at too coarse a mesh.** An under-resolved arch or touchdown
  carries a large element ``h·κ`` and can stall the dynamic Newton. The resolution metric flags
  this; the builder can auto-refine a fragile mesh when the deck opts in (``adaptive_mesh True``).
  This remains true when a large net-buoyant mesh first uses coarse-to-fine sequencing: the
  converged sequenced state is still diagnosed and, when necessary, warm-start refined. Otherwise
  **increase** ``NumSegs`` on the sag-bend and hang-off sections.
- **Several separated finite-EI contact regions.** These can be physical: a cable can bridge a
  bathymetric rise, or a buoyant section can separate two broad grounded heavy sections. CableDyn
  records the island count but does not reject that topology. Adaptive refinement is requested
  only when contact classification toggles over one interior node (an isolated contact node or
  isolated suspended gap), which is a mesh-scale signal; refine the local sections if that
  signal remains active.
- **A residual-converged folded branch.** CableDyn checks the element rotation measure after every
  finite-EI sequence attempt, every final deck-built equilibrium, and the public automatic-mesh
  route. ``max(h*kappa) > 0.7`` is rejected by name even if Newton's residual is small. This is a
  mesh/branch safety failure, not permission to relax the tolerance. The refusal names the
  element and the factor to refine ``NumSegs`` by there (``refine NumSegs at least <n>x about
  element ...``): on a resolved bend the curvature does not change with the mesh, so ``h*kappa``
  falls with the element length and ``n`` is ``max(h*kappa)/0.7`` rounded up, times the
  refinement the solve already applied to the deck element. Refine the reported section by it
  and inspect the static profile; a fold that stays kinked on the finer mesh is a non-physical
  branch, not a resolution limit. The check samples element interiors adaptively, so a
  cubic-element fold cannot hide between output nodes.
- **Odd, prime, or section-wise nonuniform meshes.** These are supported; do not change
  ``NumSegs`` merely to make the total divisible by two. The nested hierarchy retains physical
  section interfaces and interpolates at the true cumulative rest-length coordinate. Its
  suspended-span bending-scale preflight checks the actual longest proposed coarse element, so a
  sparse long section is not over-coarsened merely because the deck also contains many short
  elements. Flat-bed installed lines with an already supported anchor retain their grounded-tail
  branch homotopy and are still accepted only after exact-mesh residual and kink checks.
- **A long, light finite-EI line that solves at one orientation and not at another.** Turning a
  deck about the vertical (its end points, current and seabed with it) leaves the physics
  unchanged, but not the arithmetic: the static solve of a long line from its seed is a long
  descent whose path the last digits of the input can change. Azimuths, declinations and the
  global frame are defined in :doc:`conventions`; check that the deck's are the intended ones
  before anything else. A descent from the seed runs on while its residual keeps falling and
  stops when it has stalled (:doc:`theory`, Static equilibrium), so such a line normally solves
  at every orientation; one that still fails, or that reaches a different shape at a nearby
  orientation, is near a branch boundary of its own geometry. Inspect the static profile
  (``.static.out``: positions, tension and curvature along the line), compare it with the deck at
  a refined mesh, and judge whether the shape is the one the line would take. CableDyn does not
  choose between physically admissible branches for you.
- **A very slack cable on a frictionless flat bed.** If its rest length exceeds the vertical-plus-
  horizontal L-shaped path between the endpoints, a smooth single-touchdown equilibrium may not
  exist: the surplus must fold or form another contact region. CableDyn rejects a resulting
  element-localized wad through the curvature safety check. This is not fixed by relaxing Newton
  tolerances; revise the physical support/contact model or geometry.
- **A line resting in a trench, valley or pit of a gridded bathymetry.** A frictionless grounded
  run's tension :math:`T = T_0 + w\,(z - z_0)` falls with depth. In a trench deep enough it reaches
  zero, and an ``EI = 0`` line then rests slack at the bottom with its excess length piled there;
  the anchor tension of the run rising from the pile is :math:`w` times the depth of the trench
  below the anchor, whatever the line length. On a two-dimensional rough bed the run slides
  sideways into the valleys. Both rest in the creases of the bilinear grid, which the solver
  rounds over 5 % of the grid spacing (see :doc:`theory`) so that a node has an equilibrium
  there. A pile appears in the static profile as coincident nodes with zero tension and large
  turning angles; a finite-EI line carries compression there instead, which the driver notes.
  With 5 m elements on steep trench walls the end tensions of a pile still change by about 1 %
  on a mesh four times finer: refine the line over the trench when they matter.
- **A grounded run that slides down a slope, or anchor tension with as-laid friction.** By default
  (``staticsFriction none``) the static solve is frictionless in still water, so a grounded run
  on a slope slides down it whatever ``frictionMu`` is, and a line longer than its span folds or
  is rejected. ``asLaid staticsFriction`` holds every grounded node toward its as-laid position
  (see :ref:`friction in statics <static-friction>`), so the run rests where it was laid. A line laid slack
  (``asLaidTension 0``) and pulled taut by its fairlead is then held back by friction along its
  grounded run, and its anchor tension is lower than the frictionless static's by up to
  ``mu w`` times the grounded length (an 850 m chain in 200 m of water with ``frictionMu 0.35``:
  1352 → 368 kN). If the run was laid at a known tension, give it as ``asLaidTension`` (or
  ``asLaidTension<ID>``): a run laid at the tension it carries mobilises no friction.
- **A finite-EI line laid past the point under its fairlead** (``asLaid staticsFriction``). A line
  longer than the seabed run
  from its anchor to the point under its fairlead plus its hang is laid beyond that point, and
  its suspended part turns back over the grounded run at the touchdown. On an ``EI = 0`` line
  this fold solves; a finite-EI line must round it into a hook of its bending length, which the
  static solve may not reach (it then fails with its route diagnostics, for example ``too long
  for its span``). Lay the line across the span (``layAzimuth``, e.g. 90° from the
  anchor → fairlead direction), shorten it, or move the anchor.
- **A twisted finite-EI line.** ``torsion continuation stalled at Phi = ... (target ...)``
  reports the imposed twist the static ramp reached: beyond it the line has no nearby static
  equilibrium on the path, typically because a loop is forming (hockling), which needs a
  dynamic analysis and is not resolved as self-contact. ``finite-EI torsion static solve ended on
  an unstable equilibrium`` means the descent from a buckled (unstable) twisted state did not
  find a stable one. The twist stages refuse, or descend from, only an instability the twist
  adds: a twisted state with no more negative stiffness modes than its untwisted state (a
  planar state that is unstable out of its plane, which a line without torsion starts from with
  a note) starts with the note ``the twisted static state keeps the instability of its untwisted
  state``. Where such a state cannot be kept, ``torsion stage failed: the untwisted equilibrium
  it starts from is itself unstable`` names the untwisted state, not the twist, as the cause. ``the twist moved more than pi/2 from its committed value in one step``
  stops a dynamic step that would change the twist by more than a quarter turn (the unwrapping
  of the twist cannot be trusted beyond it): reduce ``dtM`` or slow the imposed roll.
  ``tangent turns by more than 120 degrees`` names an element or node pair where the twist of
  the centreline is no longer reliable: refine the mesh there.
- **A finite-EI equilibrium reported unstable.** ``found no physical equilibrium ... the
  converged state is an unstable equilibrium (tangent stiffness not positive definite)`` means
  the state that balanced its residual is a saddle of the potential energy: a compressed strut, a
  buckled arch or an inverted fold. A coarse mesh can also produce it. On elements longer than
  half the bending length :math:`(EI/|w|)^{1/3}` the axial force oscillates into compression at
  Gauss points near touchdown or a section change, which lowers the out-of-plane stiffness of a
  line solved in 3D. Each static route therefore refines such a state to a mesh that resolves
  the bending length before it fails: the catenary-continuation route is repeated there, and
  the mesh-sequenced state is prolongated and polished there. If the message names that refined
  mesh as well (``still unstable on the refined mesh``), the instability is physical: check the
  layout, the line length and the buoyancy.
- **Discrete buoyancy modules.** ``finite-EI static solve with discrete ATTACHMENTS failed at
  load fraction ...`` means the homotopy from the smeared modules to the lumped ones (see
  *Discrete attachments* in :doc:`theory`) did not reach the discrete equilibrium: the damped
  Newton solve of a load step did not converge, nor did its pseudo-transient and line-search
  repetitions, down to steps of 1/1024 of the module loads (or 64 load steps failed in all).
  The message names the load fraction of the first failed solve and the load fraction the
  homotopy reached. A discrete state reached by those repetitions or smaller steps is checked as
  the smeared one was; ``... the discrete equilibrium reached after a failed Newton solve ...``
  names the check it failed (the kink limit away from the attachment nodes, the tensile
  contract, the physical-branch audit or the stability test), and a state that passes them is
  reported in the note ``... was reached after a failed Newton solve ... and passed the
  acceptance checks of the smeared state``. Check that the deck with the modules replaced by the equivalent
  smeared buoyancy section solves; if it does, the discrete layout itself is the difficulty.
  ``... attachment <k> of the line (Mass ..., Volume ...) crossed the still-water level ...``
  means the solves carried that attachment across the surface, where the dynamics drops its
  buoyancy: its weight in air takes it below the surface and its weight in water above it, so a
  point attachment has no static position there (the dynamics would bob it there). It is a
  net-buoyant module that would float, or a module whose node lies nearer the surface than the
  deflection its buoyancy gives the line. The message of the failed solve follows it. Move it
  along the line or change its ``Mass`` or ``Volume``.
- **A cold start at full load.** The static solve continues the load in stages; if you have
  hand-tuned a case into a bad basin, remove the tuning and let the default continuation run
  from the catenary/arch seed.

If a *dynamic* step fails after a good static IC, the usual cause is a time step too large for a
transient event (a snap) — but note the implicit integrator's whole point is large steps, so
first confirm the static IC itself is smooth (plot the ``<out_root>.static.out`` curvature).
The failure message reports the simulated interval; ``recovery_max_substeps`` raises the
internal subdivision ceiling, and ``dynamic_solver`` sets the dynamic Newton tolerance and
iteration budget (see :doc:`options`). Qualify any change against a smaller ``dtM``.

Warnings and notes that do not stop a run
-----------------------------------------

.. list-table::
   :header-rows: 1
   :widths: 42 58

   * - Message
     - Cause and fix
   * - ``Note: line <L> is torsionally restrained at one end only and its torsion is not solved:
       <reason>``
     - a line restrained at one end, its other end free to twist, is solved in torsion (its free
       end turns with the twist of the line) where a line restrained at both ends would be; the
       reason names the rule it misses: no ``GJ`` in its ``LINE TYPES`` rows (give the 14-column
       row), two moving ends, ``False alpha_force_blend`` in a dynamic run, or a restrained End A
       on the end of a free, pinned or ``Coupled``/``Vessel`` rod or on a body other than Rigid6.
       The line is then solved as without the torsion columns.
   * - ``Note: line <L>: torsion restrained at End <B|A> only: no static torque; Twist<L> = <x>
       deg (End B relative to End A, right-handed about the End A -> End B tangent)``
     - a line restrained in torsion at one end: it carries no static torque, and under
       torque–tension coupling (``GJ|K``) its stretch twists it by
       :math:`-\sum (K/GJ)(l - L)`, so a free End B turns by :math:`+x` and a free End A by
       :math:`-x` about the End A → End B tangent.
   * - ``Note: line <L>: torsion solved, total twist Twist<L> = ... deg (imposed Pretwist(B) -
       Pretwist(A) = ... deg, with the end frames' turn and the shape's geometric twist), torque
       ... N m (<n> twist stage(s), <m> buckling descent(s))``
     - the static twist stage of a torsional line. The total twist is the ``Twist<L>`` channel at
       the static state: the imposed pretwist difference plus the turn of the end frames (a
       ``PtfmInit`` or ``TURBINES`` rotation of a parent turns its end) less the geometric twist the
       line takes up by its shape; the torque follows from it. A non-zero descent count means the
       straight or untwisted branch was unstable at the imposed twist and the solve moved to a
       buckled shape; check the shape and the ``Twist<L>`` channel.
   * - ``WARNING: CableDyn mooring module: <n> of the <N> CableDyn sampling nodes in the water
       lie outside the SeaState wave-kinematics grid at t = ... s (warned once)`` (OpenFAST)
     - the SeaState grid (``X_HalfWidth``, ``Y_HalfWidth``, ``Z_Depth``) does not cover the
       lines in the water (nodes above the free surface carry no fluid load and are not
       counted), and SeaState gives the nodes outside it the kinematics of the grid boundary: waves
       out of phase beyond a half-width, kinematics that are too strong below ``Z_Depth``. The
       message names the farthest node in each direction. Enlarge the listed inputs in the
       SeaState file past the farthest anchor (``Z_Depth`` to the water depth, its default) and
       raise ``NX``, ``NY``, ``NZ`` to keep the spacing. A SeaState file written for the
       platform alone, such as the r-test ``MD_Shared`` file, triggers it. See
       :ref:`openfast:SeaState grid` for sizes and memory.
   * - ``Note: LINE <L> is stretched to a static strain of ... % at the fairlead``
     - the fairlead tension over the EA of the End A section exceeds ``maxStrain`` (when the
       OPTION is given and positive) or 10 % (when it is not given or is ``0``, which disables
       only the dynamic guard). Any line, ``EI = 0`` or finite-EI, is assessed on every
       standalone route. A line far shorter than its span converges at
       such a strain without failing, because the dynamic ``maxStrain`` guard does not apply to
       the static solve. Check the line length against the span and the EA. Only a note: the
       equilibrium and the outputs are unchanged. Types with a Syrope working curve or a
       load-dependent stiffness are not assessed.
   * - ``WARNING: LINE <L> section of type "<name>" (... m in <n> segment(s)) has segments of ...
       m, ... % of the line length``
     - a section whose segments are longer than 1/8 (12.5 %) of the line, i.e. coarser than a
       uniform eight-segment line, is too coarse to follow the line shape there; a 100 m
       one-segment top section of a 520 m line shifts the fairlead tension by tens of percent.
       The rule compares the segment length with the whole line, so it does not depend on how
       the line is split into sections. Refine its ``NumSegs``; a converged tension usually needs
       segments well below this bound. (A line with fewer than three segments in all is reported
       whole.)
   * - ``WARNING: line type ... sinks ... m into the seabed ...; kBot is soft for this line``
     - a grounded run of this type would sink deeper than its own diameter into the penalty
       seabed. Raise ``kBot``; the default ``1.0e5`` embeds a heavy chain by about half its
       diameter, which is normal.
   * - ``WARNING: LINE ... hangs ... m below its Fixed anchor and the deck has no seabed``
     - the deck has no ``WtrDpth`` or ``bathymetryFile``, so a slack mooring hangs through the
       missing seabed. This is typical of an OpenFAST ``MooringFile``, which takes the depth from
       the host; add ``WtrDpth`` for a standalone run.
   * - ``Note: motionFile point ... starts moving at ... m/s``
     - the lines start at rest, so an end that starts at speed sends an axial shock down the line
       and can put its upper part into compression for several steps. A harmonic started at
       ``t = 0`` begins at its peak velocity. Start the motion from rest or ramp its amplitude in
       over one or two periods, as ``examples/data/lozon/generate_gomex80_heave.py`` does.
   * - ``Note: line ...: the static layout carries the grounded run ... m past its anchor, where
       it folds back (a hairpin) ...``
     - a current, or a seabed sloping down past the anchor, has pushed the grounded run past its
       anchor where no seabed friction holds it, and it folds back to it (see :doc:`theory`).
       The layout is a valid, stable equilibrium of the deck as written, but not the usual one.
       Check the line length, the current and the seabed, and inspect
       ``<out_root>.static.out`` before using the layout. The note, finite-EI or ``EI = 0``,
       names the cause (the current, the slope, or on an ``EI = 0`` line neither: a slack line
       laid out and back, which a shorter line removes) and the remedy that fits the deck: with
       the default ``staticsFriction none`` the static solve applies ``frictionMu`` against a
       deck current only, so a current points to ``frictionMu`` and a slope to
       ``staticsFriction asLaid``, which holds the run toward its as-laid position; a run without
       ``dtM`` and ``TMax`` has no seabed friction in its static solve at all; where friction
       already acts, or the deck's route rejects it (``frictionMu`` beside ``Connect``/``Free``
       points or ``Point3`` buoys, ``asLaid`` on the multibody march), it points to a shorter
       line. A run that the ``staticsFriction asLaid`` reference itself lays past the anchor is
       the deck's own layout and is not noted.
   * - ``Note: line ...: the static layout folds the grounded run back on itself (a ... deg turn
       at node ..., a hairpin) ...``
     - an ``EI = 0`` line whose grounded run turns back by more than 150° at a node, away from
       its ends (for example a slack line whose excess length the static solve lays out and back
       on the seabed). The node is a deck node, numbered as the ``<J>`` of the node channels
       (1 = End A). As above, the layout is an equilibrium of the deck as written; check the
       line length before using it.
   * - ``Note: line(s) ... on the seabed at the static start with no seabed friction``
     - a dynamic deck with a current and interior line nodes in seabed contact at the static
       start: nothing holds those nodes against the current, so the layout can drift along the
       seabed through the run. Set ``frictionMu``; the note says so where the deck's route rejects
       it. It is printed
       once per run, and nothing in the solution changes. On the coupled route it takes the
       current known at initialisation (the deck's, or the host's steady current).
   * - ``Note: line ...: the equilibrium in the current is held in the vertical plane of the line; it
       is unstable out of that plane ...``
     - in a current along the plane of the line the static state is a planar equilibrium that a
       lateral disturbance would leave (the line is held in the plane only by the symmetry), and
       no out-of-plane equilibrium was found. The state is valid in the plane; a cross-flow
       component or seabed friction (``frictionMu``) gives the line a stable layout.
   * - ``Note: line ...: a nodal tangent turned up to ... deg in one step``
     - the time-step audit of a finite-EI line: above 0.25° per step (0.1° with
       ``False alpha_force_blend``) the mean tension can err by about 1 %. Reduce ``dtM``.
   * - ``Note: line ...: a taut segment turned up to ... deg in one solver step``
     - the time-step audit of an ``EI = 0`` line, per solver step (the sub-steps of a
       sub-stepped step count as steps): above 1° per step the mean and standard deviation of
       the tension can err by about 1 % (1.3 % at 2.9° on a heaving chain), and near 6° per step
       snap-load peaks come out 10 to 20 % low with either generalised-α blend. With
       ``off ei0_substeps`` set ``auto`` (the default) or reduce ``dtM``; with ``auto`` the note
       means steps it did not resolve (more than ``ei0_substep_max`` needed, a step recovered
       after a stall or a half of a line-system step halved after a failure, whose sub-steps
       are taken as given, a step that kept its plain result because a sub-step failed, or a
       line attached to a body, rod or point of the monolithic body and point coupling, which
       is not sub-stepped): reduce ``dtM``.
   * - ``Note: line ...: ei0_substeps auto solved ... of the ... line step(s) it examined in sub-steps``
     - information: the steps in which a taut segment turned by more than ``ei0_substep_angle``
       or a segment snapped from slack to taut were solved in sub-steps (see
       ``ei0_substeps``). Only committed steps count: a step that is rolled back and taken
       again (a line-system step halved after a stall, a step recovered after a stall, a
       corrector or a re-solved coupling step) counts once, as it is finally taken, so the
       steps examined can be fewer than the line's steps. A companion note counts the steps
       that needed more than ``ei0_substep_max`` sub-steps, and another the steps that kept the
       plain step's result because a sub-step did not converge. OpenFAST and FAST.Farm print the
       same counts, summed over the lines, as ``CableDyn: ei0_substeps auto solved ...`` at the
       end of the run.
   * - ``Note: ei0_substeps auto does not sub-step the EI = 0 lines attached to the bodies, rods and points of the monolithic body/point step``
     - information, once per run of a deck with ``monolithic bodyScheme`` coupling, the default
       of every standalone deck with ``Rigid6`` bodies, ``Point3`` buoys, rods or
       ``Free``/``Connect`` points on ``EI = 0`` lines (7 of the shipped example decks): the
       lines attached to those objects and points are stepped inside the junction Newton and
       taken whole at each monolithic step (``dtM``, divided by ``accuracy bodySubstep``, the
       default, to resolve the body-mooring modes), so their rotation and snaps are resolved
       only as far as that step resolves them; a line whose ends are all fixed or anchored is
       sub-stepped as usual. Reduce ``dtM`` when the segment-turn note above appears for them,
       or select ``staggered bodyScheme``, which sub-steps them.
   * - ``Note: line ...: ... segment step(s) went from slack to taut above the initial tension``
     - snap loads on an ``EI = 0`` line at a solver step that does not resolve the axial wave
       over a segment: the peak is set by a single step. A 15 m surge of a semi-taut
       chain–polyester line peaks at 4.65 MN at ``dtM`` 0.05 s with the default sub-steps
       (5.7 MN with ``off ei0_substeps``) against 4.6 MN at 0.0025 s. The run is valid; confirm
       design peaks with a smaller ``dtM``. On a line without axial damping (``BA = 0``) the
       snap peaks do not converge in time or mesh, as single segments rattle; a smaller ``dtM``
       raises them, and at a ``dtM`` that does not resolve the axial wave the sub-steps of
       ``ei0_substeps auto`` can raise isolated spikes. Give
       the line physical axial damping (``BA`` in N·s, not the per-segment damping-ratio form,
       which changes with the mesh) or finite ``EI`` to obtain converged peaks (see
       :doc:`modeling`).
   * - ``Warning: line ...: segment ... carried ... N at t = ... s for a single step, ... times
       the largest tension on the line one step before and after``
     - a non-physical tension spike: the tension of one segment (elastic, viscoelastic or
       Syrope; numbered from End A, as in ``.Line<L>.t.out``) rose and fell within one step to ten times anything the line carried one step
       before and after, which no physical
       snap or tension wave does. It is the signature of an under-resolved slack–taut
       transition integrated without energy control, for example with
       ``False alpha_force_blend`` (the ``EI = 0`` scheme of 0.1.1 and earlier) or with
       ``rhoInf`` near 1. Remove ``False alpha_force_blend``, keep ``rhoInf`` at or below
       0.95, or reduce ``dtM``; the run summary counts the spikes of the line.
   * - ``Note: rhoInf = ... leaves almost no numerical dissipation``
     - printed by the standalone driver for a dynamic deck with ``rhoInf`` above 0.95: the modes ``dtM`` does not resolve keep the residual of each
       Newton step and the energy of under-resolved snaps. In an irregular sea this can raise the
       tensions several times (a lazy wave at ``1 rhoInf`` with a ``1e-4`` Newton tolerance
       peaked at twenty times the converged value). Use ``rhoInf`` ≤ 0.95 (default 0.4), or a
       ``dynamic_solver`` relative tolerance of ``1e-6`` or tighter and a smaller ``dtM``.
   * - ``Note: line ...: elements as short as ... are below sqrt(EI/EA)``
     - the finite-EI deck mesh is finer than the axial-bending length :math:`\sqrt{EI/EA}`:
       the axial stiffness of each element swamps its bending stiffness and the static
       Newton system loses the precision to converge. An 80 m lazy wave (6.5 mm limit)
       solves at 8 mm elements and not at 4 to 6 mm, where the solve stops within seconds
       and names the mesh. Coarsen ``NumSegs`` to at least the length the note gives.
   * - ``Note: line ...: the equilibrium on the deck mesh (... elements) failed the stability test
       with elements longer than half the bending length; stable on the refined mesh of ...
       elements`` (or ``the equilibrium on the mesh of ... elements (refined from the deck mesh of
       ...) failed ...``)
     - on the deck mesh, or on a refinement of it that was still too coarse, the static state
       read as unstable, an artefact of elements longer than half the bending length
       :math:`(EI/|w|)^{1/3}` (see :doc:`modeling`, step 5). The run uses
       the refined mesh, statics and dynamics alike, and its outputs have that many segments.
       Mesh the touchdown and section changes to that rule to keep the deck mesh.
   * - ``Note: line ...: the deck mesh (... elements) could not resolve the curvature of the
       equilibrium; refined to ... elements``
     - the deck mesh is too coarse for the bends of the static state. Either an element folded
       beyond :math:`L_0\kappa = 0.7` (a bend shorter than the element), and the static solve
       refined the mesh locally where the bend is, and where elements are longer than half the
       bending length, at most 16-fold per deck element and graded into the neighbouring
       elements; or the continuation or polish failed on a deck mesh with elements longer than
       half the bending length :math:`(EI/|w|)^{1/3}`, and the route was repeated on the whole
       line refined uniformly by a power of two, up to the factor at which every element meets
       that length, and then on the deck mesh with only its long elements split to that length
       (or, at a rotationally
       restrained end, on end elements halved toward the end down to its boundary layer). See
       :doc:`theory`, Static equilibrium. The run uses the refined mesh, statics and dynamics
       alike, and its profile and per-line outputs have that many segments; the refinement
       only splits deck elements, so the node channels still name deck nodes (see
       :ref:`outputs-refined-nodes`). Mesh the line to the bending-length rule to keep the deck
       mesh.
   * - ``Note: line ... starts the dynamics from a static state solved in its vertical plane that
       is unstable out of that plane on its mesh of ... elements, the coarsest ... m long where
       half the bending length (EI/|w|)^(1/3) is ... m; ...``
     - a finite-EI line free in torsion is solved in its vertical plane, and the dynamics release
       its out-of-plane DOFs. On elements longer than half the bending length the axial force at
       touchdown or a section change oscillates into compression and makes that planar state
       unstable out of the plane, so a lateral disturbance (a cross current, a sway motion) can
       move the line from it in a way the mesh, not the physics, decides. On a line with
       ``ATTACHMENTS`` the test runs on the discrete equilibrium, after the attachment polish,
       and the bending length uses the smeared weight of the buoyant stretch. The results are
       those of the deck as written. Refine the mesh by the factor the note gives, or set
       ``adaptive_mesh True``; a line restrained in torsion is solved in 3D and refined
       automatically (see :doc:`modeling`, step 5). When ``adaptive_mesh True`` is already set,
       its own refinement criteria stopped short of the bending length: refine the deck mesh.
   * - ``Note: line ... mesh too coarse for its bends``
     - the element-mean axial force of a finite-EI line, averaged with its neighbours, is
       compressive, and the pointwise resultant oscillates well beyond it. Refine ``NumSegs`` in
       the reported region, or set ``tensile_safety True`` to reject the state. A pointwise dip
       at a seabed touchdown with tensile neighbouring elements is not reported.
   * - curvature near a hang-off changes with ``dtM`` or the mesh
     - end curvature is a boundary-layer quantity. Run a ``dtM`` study (halve it until the value
       changes by less than a few percent), grade the mesh toward the end, and report the value
       1–2 m from a pinned end, not at the pinned node (see :doc:`modeling`, step 5).

An OpenFAST ``CompMooring = 5`` run fails at init
-------------------------------------------------

The module covers the scoped MoorDyn-F coupled surface and **fails closed** outside it. If init
aborts with a CableDyn fatal error, check whether the deck uses one of these combinations:

.. list-table::
   :header-rows: 1
   :widths: 46 54

   * - Not supported on the coupled route
     - Use instead
   * - active ServoDyn control (``CONTROL``) in FAST.Farm
     - line control of ``EI = 0`` lines and finite-EI cables **is** supported in a single-turbine
       model; for controlled lines in a farm, use stock MoorDyn (``CompMooring = 3``) in the same
       binary
   * - deck ``waves``/``wavetrain`` OPTIONS, and a deck ``current`` on a deck with finite-EI
       cables, Rigid6 bodies or rods, in FAST.Farm, or with a SeaState that carries waves or
       current
     - put the sea state and current in SeaState, or a current table in a WaterKin file
       (``CurrentMod 1``); a steady deck ``current`` is kept on a single-turbine, pure
       ``EI = 0`` deck in a SeaState without waves or current
   * - a finite-EI cable in the same deck as Rigid6 bodies, rods, or ``Connect``/``Free`` points
     - model the cable and the body/point system in separate decks or use the supported
       combinations in :doc:`capabilities`
   * - ``a coupled deck with both BODIES and RODS is not supported``: bodies (Rigid6 or Point3)
       and rods in one deck, a rod fixed to a body (``Body<N>``, ``Body<N>Pinned``) included
     - the coupled march advances the bodies or the rods of a deck, not both (also in the C API and
       Python). Run the deck with stock MoorDyn (``CompMooring = 3``) in the same binary, or, without
       ``CoupledPinned`` objects, with the standalone driver, whose multibody march takes both; a
       deck with only bodies or only rods runs coupled
   * - OpenFAST linearisation of a cable with a ``Rigid`` ``END CONNECTIONS`` row (``formal
       OpenFAST linearization of a cable with a rigid end connection is not supported``), of a deck
       with ``Free`` or ``Connect`` points or a line with VIV (``Cl > 0``), or with a ``CONTROL``
       section
     - linearise a variant with a numeric rotational stiffness at the hang-off, the lines attached to
       ``Fixed`` or ``Coupled`` points, ``Cl = 0`` and no ``CONTROL`` section; time-domain runs
       support all of them
   * - a ``Rigid`` end-connection direction reversed by exactly 180 degrees in one host update
     - drive the platform through intermediate orientations
   * - ``OPTION staticsFriction asLaid lays a line on the seabed from its anchored end; ... has a
       moving End B``
     - a line between two moving points has no anchored end to lay it from: use
       ``staticsFriction none`` (the march then starts from the frictionless static equilibrium,
       and the friction acts from there)
   * - a host/file fluid combination named as inseparable
     - select host wave/current and file wave/current independently as documented, or place the
       whole field in SeaState
   * - a ``Point3`` restoring model beyond buoyancy and supported fluid loads
     - represent the restoring physics with supported line/body terms or use stock MoorDyn

Finite-EI rotational end coupling **is** supported in the time domain on the coupled route: an
``END CONNECTIONS`` direction at a coupled hang-off rotates with the OpenFAST platform
orientation, the mesh angular velocity and acceleration enter the implicit residual, and the
connection moment is returned to OpenFAST on the load mesh (see :doc:`openfast`). In the
standalone driver an end-connection direction stays fixed in global axes on a ``Fixed`` or
``Coupled`` point driven by a ``motionFile``, and turns with the vessel under ``vesselMotion``
or ``vesselRAO``.

Everything CableDyn does support end-to-end — coupled time-domain analysis, ``PtfmInit``,
``NumCrctn > 0``, SeaState kinematics, checkpoint-restart, linearisation, rigid bodies/rods, and
``Mod_SharedMooring = 5`` — is listed in :doc:`capabilities`.

The standalone binary will not launch (Windows)
-----------------------------------------------

Use the release ``CableDyn_driver.exe`` or CableDyn-enabled ``openfast.exe``. Those two
non-OpenMP x64 files are statically linked and require no adjacent compiler, BLAS, OpenMP,
or C/C++ runtime DLL. A locally built GNU/OpenMP executable may still require its selected
toolchain libraries. A GNU build loads ``openblas.dll`` from its own directory when it starts;
if the library is missing, the driver stops with exit status ``2`` and a message naming the
library, each location tried, and the Windows load error. Keep ``openblas.dll`` next to the
executable (``cmake --install`` stages it) or run from the activated environment. A missing
``DISCON.dll`` is different: the OpenFAST model explicitly
requested a ServoDyn controller, so copy that model-specific controller with the model or
disable it. See :doc:`installation` (standalone binaries).

**Stack size of a GNU build.** A build with gfortran on Windows (MinGW-w64) links the driver
and the test programs with a 64 MiB stack reserve instead of the 2 MiB MinGW default, because
with OpenMP gfortran places fixed-size local arrays on the stack. A reserve is address space,
not committed memory. The shared library does not rely on it: a program that loads
``libcabledyn``, such as ``python.exe``, chooses the stack of the threads that call it. The
``stack`` tests check that the library runs on threads with a 1 MiB stack, and that a driver
linked with a 1 MiB reserve runs a 2048-element deck.

If your issue is not here, see :doc:`faq`; the :doc:`driver_format` row for the feature is the
authoritative statement of what is supported, and :doc:`validation` records exactly which cases
are validated.
