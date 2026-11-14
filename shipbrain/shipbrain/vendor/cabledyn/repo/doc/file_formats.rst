.. SPDX-License-Identifier: Apache-2.0

Auxiliary input files
=====================

A CableDyn deck can name other input files: a prescribed-motion history, a
structured seabed grid, a MoorDyn-F water-kinematics file, the fixed-name MoorDyn-C
kinematics files, and Syrope working-curve data. This page gives the layout, units and validation
rules for
each one. The deck keywords that point to these files are covered in
:doc:`driver_format` and :doc:`options`. Output files are covered on their own
page.

.. list-table:: Auxiliary files read by the deck parser
   :header-rows: 1
   :widths: 24 34 42

   * - File
     - Referenced by
     - Relative path resolved against
   * - Prescribed motion
     - OPTIONS ``<path> motionFile``
     - the deck directory
   * - Vessel motion record, vessel RAO table
     - OPTIONS ``<path> vesselMotion``, ``<path> vesselRAO``
       (grammar in :doc:`driver_format`)
     - the deck directory
   * - Structured bathymetry
     - OPTIONS ``<path> bathymetryFile`` (aliases ``bathymetry_file``, ``seafloorFile``,
       ``seafloor_file``)
     - the deck directory
   * - WaterKin file
     - OPTIONS ``<path> WaterKin`` (alias ``WaveKin``)
     - the deck directory
   * - Wave-elevation history (``WaveKinFile``)
     - line 5 of the WaterKin file, when ``WaveKinMod = 1``
     - the directory of the WaterKin file
   * - Syrope settings
     - LINE TYPES ``EA`` column ``SYROPE:<path>|alpha|beta``
     - the deck directory
   * - Syrope OWC table
     - the ``OWC`` row of the Syrope settings file
     - the directory of the settings file
   * - MoorDyn-C kinematics files ``wave_elevation.txt``, ``wave_frequencies.txt``,
       ``current_profile.txt``, ``current_profile_dynamic.txt``, ``current_profile_4d.txt``
     - OPTIONS ``3 WaveKin``, ``7 WaveKin``, ``1 Currents``, ``2 Currents`` and ``5 Currents``
       (grammar in :ref:`moordyn-c-wavekin`); the file names are fixed
     - the deck directory

The parser reads no other input files. Line-type properties, nonlinear ``EA`` data
other than the Syrope OWC table, wave spectra, and control-channel values all come
from the deck itself or from the coupling host. Because the MoorDyn-C file names are
fixed, a deck that uses ``WaveKin 3``/``7`` or ``Currents 1``/``2``/``5`` must sit in the same
folder as its kinematics file; a copied or generated deck needs a copy of that file
beside it.

Common rules
------------

Path resolution
~~~~~~~~~~~~~~~

* A path is **absolute** when it starts with ``/`` or ``\``, or when its second
  character is ``:`` (a Windows drive such as ``D:\data\motion.txt``). An absolute
  path is used unchanged.
* Any other path is **relative**. CableDyn adds the directory part of the deck path to
  the front of it, exactly as the deck path was given on the command line. So
  ``CableDyn_driver models/case.dat case`` with ``data/motion.txt motionFile`` opens
  ``models/data/motion.txt``. If the deck path has no directory part, the file is
  opened relative to the current working directory, which is then the deck
  directory.
* The OWC table named in a Syrope settings file is resolved against the settings
  file's directory. A relative ``WaveKinFile`` is resolved against the deck
  directory first, as MoorDyn-F does, and then against the WaterKin file's directory.
* A path is a single whitespace-free token. It may be wrapped in one pair of single
  or double quotes, and it may use ``/`` or ``\`` separators. Paths cannot contain
  spaces, ``#`` or ``!``, because the last two start a comment. A path may be up to
  512 characters long. A ``motionFile`` path that is longer than that after the
  deck directory is added is rejected (``motionFile path is too long after
  resolving relative to the deck directory``).
* The file must already exist. A missing or unreadable file stops the run with an
  error that names the kind of file and its resolved path, followed by the reason,
  for example ``cannot open motionFile: <resolved path>`` or ``cannot open the
  WaterKin file: <resolved path>``.

Record rules
~~~~~~~~~~~~

The motion, bathymetry, Syrope settings and OWC files use the deck's record reader:

* A UTF-8 byte-order mark at the start of the file is ignored (in every auxiliary file,
  WaterKin included).
* Lines holding only whitespace are skipped. ``#`` and ``!`` start a comment anywhere on
  a line. ``--`` starts a comment when it begins a whitespace-delimited token, but not on
  a line that contains ``---``.
* Columns are separated by ASCII whitespace (space, tab, form feed, vertical tab).
  Commas are not separators, so CSV files are rejected. A NUL or a non-ASCII whitespace
  character (such as a no-break space) outside a comment is an error.
* A number must be one plain token such as ``0.05``, ``-14`` or ``1.5e-3``. A token
  containing ``/``, ``,``, ``;``, ``*`` or a quote is rejected rather than read in
  part.
* A record may hold up to 512 characters of non-comment text. A longer record is an
  error, never silently truncated.
* A row-level error names the file and the line number, then quotes the row. For
  example:
  ``motionFile line 7: time is outside the dtM/TMax grid [row: ...]``.

The WaterKin file and its ``WaveKinFile`` follow MoorDyn-F's layout instead, which
depends on line position. Their rules are given in `WaterKin file`_.

.. _motion-file:

Prescribed motion file (``motionFile``)
---------------------------------------

The motion file gives the absolute position, velocity and acceleration of every
prescribed point at every model time step of a standalone dynamic run.

Deck reference
~~~~~~~~~~~~~~

.. code-block:: text

   0.05     dtM                                 - CableDyn internal time step (s)
   36.0     TMax                                - Standalone simulation duration (s)
   data/lozon/gomex80_heave_3m_12s_dt005.txt motionFile - Prescribed fairlead motion history

* ``0`` or ``none`` (in any case) turns the option off. The last ``motionFile`` row
  wins, so one template can serve both static and dynamic cases.
* An active ``motionFile`` requires both ``dtM`` and ``TMax``
  (``OPTION motionFile requires dtM and TMax``).
* Only the standalone driver reads the file. The coupling to OpenFAST (maintained by NLR, the
  National Laboratory of the Rockies, formerly NREL) rejects it
  because the host drives the coupled boundary (``... not a deck motionFile;
  remove the motionFile OPTION``). Decks with a ``FAILURE`` section, decks with
  ``Connect``/``Free`` dynamic points, and mixed ``EI = 0``/finite-EI decks also
  reject it. :doc:`driver_format` lists the supported routes.

Columns
~~~~~~~

Each data row has eleven whitespace-separated numbers:

.. list-table::
   :header-rows: 1
   :widths: 8 16 12 64

   * - Col
     - Name
     - Unit
     - Meaning
   * - 1
     - ``time``
     - s
     - Sample time. It must lie on the ``dtM`` grid (see below).
   * - 2
     - ``point_id``
     - --
     - ``ID`` of a POINTS row. It must be a positive whole number (``1`` or ``1.0``).
   * - 3--5
     - ``x y z``
     - m
     - Absolute position in the global frame (``z`` up, still-water level at
       ``z = 0``). These are positions, not offsets from the deck coordinates.
   * - 6--8
     - ``vx vy vz``
     - m/s
     - Absolute velocity.
   * - 9--11
     - ``ax ay az``
     - m/s²
     - Absolute acceleration.

Every row must start with a number, so any header or column-label line must be a comment.
Tokens after the eleventh are ignored, except on a deck with a torsional line (below).

**Roll column (torsion).** On a deck where some finite-EI line is solved in torsion, restrained
at both ends or at one (``END CONNECTIONS`` ``TorsStiffness``, see :doc:`driver_format`), a numeric
twelfth token is read as the roll of the frame of a line's moving end restrained in torsion (End A,
or End B in a deck that lists the anchor as End A; both ends of a line between two moving points),
in degrees, right-handed about the line tangent pointing into the line from that end. It imposes a
twist history without turning the point: the line's imposed twist is

.. math::

   \Phi(t) = \text{Pretwist}_B - \text{Pretwist}_A - \text{roll}_A(t) - \text{roll}_B(t),

the roll of a ``Fixed`` end being 0, so a positive roll lowers :math:`\Phi`. At End A it has the sense of
``Pretwist`` (A) and of rolling the End A frame through a body or vessel; at End B, where the
inward tangent is ``−Ez``, it has the opposite sense to ``Pretwist`` (B). Rules:

* a point gives the roll on every row or on none (``gives the roll column (12th) on some rows
  only``);
* the roll must be 0 at ``t = 0``, because the static initial condition uses the deck
  ``Pretwist``; give a constant twist there (``the roll column of point <id> must be 0 at
  t = 0``);
* a non-zero roll is accepted only at the moving end of a line solved in torsion, restrained
  there (``has a non-zero roll column, but no line restrained in torsion ... at its moving
  (non-Fixed) end has that end there``): a free end has no torsion frame to roll;
* the roll is real valued and not wrapped, so several turns are written as they accumulate; the
  time integration takes its rate and acceleration from the roll history (no column).

:file:`examples/data/torsion/hangoff_roll_2turns_60s_dt01.txt`, used by
:file:`examples/torsion_lazy_wave_hangoff_twist.dat`, holds the hang-off in place and rolls it
from 0 to −720° over 60 s.

Coverage and time grid
~~~~~~~~~~~~~~~~~~~~~~

The model grid is ``t_k = k·dtM`` for ``k = 0 … TMax/dtM``, and ``TMax`` must be a
whole multiple of ``dtM``. The file is checked against this grid:

* Each ``time`` must match a grid time to within ``100·ε·max(1, TMax)``, where ε is
  double-precision machine epsilon. Times off the grid or before ``0`` are rejected
  (``time is outside the dtM/TMax grid``). Write times with enough digits to hit the
  grid exactly. A file may run past ``TMax``: its rows after ``TMax`` are checked
  (on the ``dtM`` grid, to within ``100·ε·max(1, time)``) and not used, so a long
  record serves a shorter run and ``TMax = 0`` checks the static start. At ``TMax = 0``
  without ``dtM`` the grid is the ``t = 0`` row and later rows are not checked.
* Every eligible point needs exactly one row at every grid time. A repeated
  point/time pair is rejected (``duplicate row for point <id> at this time``). A
  missing pair is rejected once the whole file has been read (``motionFile must
  provide every Coupled/Vessel point at every dtM time``).
* Rows may come in any order. The file does not have to be sorted by time or grouped
  by point.
* The driver uses each sample at its own grid time and does no resampling. If a step
  is subdivided internally to recover convergence, the boundary between two samples
  follows a quintic that matches position, velocity and acceleration at both ends.
  The velocities and accelerations are used as given and are not checked against the
  positions, so give a kinematically consistent history. The shipped example uses a
  C2 quintic ramp so the run starts from rest.
* The ``t = 0`` row is applied as the initial boundary state. Make it agree with the
  deck coordinates of the point, because any difference acts as a step change at
  ``t = 0``.

Which points are eligible depends on the deck:

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Deck type
     - Points that need a row at every grid time
   * - Line decks (``EI = 0`` or finite-EI)
     - Every ``Coupled`` and ``Vessel`` point. Rows that name any other point are
       rejected (``references point id <n>, which is not Coupled/Vessel``). At least
       one such point must exist.
   * - Rod decks
     - Every ``Coupled``/``Vessel`` point and **every** ``Rod<N>A``/``Rod<N>B``
       point, including the ends of ``Free`` and ``Fixed`` rods. Only
       ``Coupled``/``Vessel`` rods take their motion from the file; rows for the
       other rods are read and then ignored. For each prescribed rod, the distance
       between its two end rows must stay equal to the rod length to within
       ``1e-8·max(1, L)`` (``does not preserve rod length``).
   * - Rigid6 body decks
     - Every ``Coupled``/``Vessel`` point and every ``Body<N>`` point. If all of a
       body's attachment rows describe the same translation, the body translates and
       keeps its deck attitude. Otherwise CableDyn recovers the rigid rotation, which
       needs at least three non-collinear attachments. Rows that do not describe one
       rigid motion are rejected (``rows do not describe a rigid motion``).

Example
~~~~~~~

From :file:`examples/data/lozon/gomex80_heave_3m_12s_dt005.txt` (trimmed), used by
:file:`examples/lozon_gomex80_power_cable_motion.dat`:

.. code-block:: text

   # Columns: time(s) point_id x(m) y(m) z(m) vx(m/s) vy(m/s) vz(m/s) ax(m/s2) ay(m/s2) az(m/s2)
   0.00  1  5.0000000000e+00  0.0000000000e+00  -1.4000000000e+01  0.0000000000e+00  0.0000000000e+00  0.0000000000e+00  0.0000000000e+00  0.0000000000e+00  0.0000000000e+00
   0.05  1  5.0000000000e+00  0.0000000000e+00  -1.3999999944e+01  0.0000000000e+00  0.0000000000e+00  4.5089173713e-06  0.0000000000e+00  0.0000000000e+00  2.6979689755e-04
   0.10  1  5.0000000000e+00  0.0000000000e+00  -1.3999999103e+01  0.0000000000e+00  0.0000000000e+00  3.5770602704e-05  0.0000000000e+00  0.0000000000e+00  1.0669947197e-03

The deck has one ``Coupled`` point (``ID 1``), with ``dtM = 0.05`` and
``TMax = 36``. The file therefore has 721 data rows, one for each time from 0 to
36 s.

.. _bathymetry-file:

Structured bathymetry file (``bathymetryFile``)
-----------------------------------------------

The bathymetry file defines a variable seabed on a rectangular x-y grid.

.. note::

   This is CableDyn's own ``x y depth`` point list. It is **not** the MoorDyn
   bathymetry grid format, which uses ``nGridX``/``nGridY`` headers and a depth
   matrix. Convert MoorDyn grids to one row per grid node.

Deck reference
~~~~~~~~~~~~~~

.. code-block:: text

   "bathymetry.txt" bathymetryFile - Structured x/y/depth seabed; mutually exclusive with WtrDpth

* ``bathymetryFile`` and ``WtrDpth`` cannot both appear in a deck (``OPTIONS WtrDpth
  and bathymetryFile are mutually exclusive``). Under OpenFAST, the deck's
  bathymetry takes the place of the host's flat depth.
* There is no value that turns the option off. ``0`` or ``none`` would be read as a
  file name, so leave the row out instead.
* ``kBot`` must be finite and positive and ``cBot`` finite and non-negative. Both
  scale the contact law as they do on a flat seabed.
* Only some routes support structured bathymetry. The list is under ``bathymetryFile``
  in :doc:`driver_format`.

Columns
~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 8 14 10 68

   * - Col
     - Name
     - Unit
     - Meaning
   * - 1
     - ``x``
     - m
     - Global x coordinate of the grid node.
   * - 2
     - ``y``
     - m
     - Global y coordinate of the grid node.
   * - 3
     - ``depth``
     - m
     - Water depth below still-water level, **positive down**. The seabed at that
       node is at ``z = -depth``.

Validation
~~~~~~~~~~

* Every non-comment row must have exactly three tokens (``rows must be "x y
  depth"``). A text header line is therefore an error unless it is a comment.
* All values must be finite, and every depth must be greater than zero.
* The distinct ``x`` values and the distinct ``y`` values set the grid axes. Each
  axis needs at least two values, and the file must hold exactly one row for every
  ``(x, y)`` pair. So the grid needs at least 2 × 2 nodes, with no duplicates
  (``bathymetry file has duplicate x/y entries``) and no gaps (``bathymetry file grid
  is incomplete``). Two coordinates count as the same when they agree to within
  ``16·ε`` relative.
* Rows may come in any order. Grid spacing does not have to be uniform.

The seabed is interpolated bilinearly within each grid cell, and the creases of that
surface along the interior grid lines are rounded within a band of half-width 5 % of
the smaller grid spacing next to each line (a cubic fillet that makes the surface
twice continuously differentiable; see :doc:`theory`). The rounding moves the surface
by at most a sixth of the slope jump across the line times the band half-width, and
leaves a planar grid and every patch without a crease exactly bilinear. On a slope the
frictionless contact force acts along the surface normal, and its stiffness includes
the slope of that surface. Outside the grid, depth is clamped to
the value at the nearest edge.

Example
~~~~~~~

A minimal 2 × 2 grid with a planar slope along x:

.. code-block:: text

   # x (m)    y (m)    depth (m, positive down)
   -10.0    -10.0     80.0
   410.0    -10.0     79.5
   -10.0     10.0     80.0
   410.0     10.0     79.5

.. _waterkin-file:

WaterKin file
-------------

``WaterKin`` accepts a MoorDyn-F water-kinematics file, so a migrated MoorDyn-F deck
can keep its current profile and wave-elevation history.

Deck reference
~~~~~~~~~~~~~~

.. code-block:: text

   "WaterKin.dat" WaterKin - MoorDyn-F WaterKin file

The ``WaterKin`` value is classified as follows:

* ``0`` or ``none``: still water, no file.
* ``SEASTATE``: host SeaState field, OpenFAST coupling only. No file is read.
* A value containing any letter other than ``e``/``E``: a file name. The file is
  read after the whole deck has been parsed, so where the row sits among the
  OPTIONS does not matter.
* Any other number is rejected.

The last ``WaterKin`` row wins.

Layout
~~~~~~

The file is read **by line position**, as MoorDyn-F reads it. Comment characters are
not stripped and blank lines are not skipped, so every line below must be present,
even when its value is not used. On value lines only the first token is read, and
the rest of the line is free text. An error found on a line names it
(``WaterKin file line 15: WaterKin CurrentMod must be an integer ...``; in the
``WaveKinFile``, ``WaterKin WaveKinFile line N: ...``).

.. list-table::
   :header-rows: 1
   :widths: 10 24 66

   * - Line
     - Content
     - Rules
   * - 1--2
     - Free-text header
     - Ignored.
   * - 3
     - Waves section rule
     - Ignored.
   * - 4
     - ``WaveKinMod``
     - ``0``, ``1``, ``2``, or ``SEASTATE`` (see the mode table below).
   * - 5
     - ``WaveKinFile``
     - Path to the elevation history, relative to this file. It may be quoted, and
       ``""`` means none. It is required when ``WaveKinMod = 1``.
   * - 6
     - ``dtWave`` [s]
     - Must be a finite number ≥ 0 in every mode. It must be > 0 when
       ``WaveKinMod = 1``.
   * - 7
     - ``WaveDir`` [deg]
     - Must be a finite number in every mode. This is the wave heading used by
       ``WaveKinMod = 1``.
   * - 8--13
     - X, Y, Z wave-grid rows (three pairs of type line and data line)
     - Must be present. Their content is ignored.
   * - 14
     - Current section rule
     - Ignored.
   * - 15
     - ``CurrentMod``
     - Integer ``0``, ``1`` or ``2``.
   * - 16--17
     - Current-table header rows
     - Read only when ``CurrentMod = 1``, and ignored.
   * - 18 on
     - ``z ux uy`` rows
     - Only when ``CurrentMod = 1``. See `Current profile table`_.

Modes
~~~~~

.. list-table::
   :header-rows: 1
   :widths: 22 30 48

   * - Selector
     - Meaning
     - Standalone driver
   * - ``WaveKinMod = 0``
     - no waves
     - accepted
   * - ``WaveKinMod = 1``
     - elevation history from ``WaveKinFile``
     - accepted; the OpenFAST coupling rejects it (``WaterKin WaveKinMod 1 is supported
       only by the standalone driver``)
   * - ``WaveKinMod = 2`` / ``SEASTATE``
     - waves from the host SeaState field
     - rejected (``WaveKinMod 2/SEASTATE is coupled-only``)
   * - ``CurrentMod = 0``
     - no current
     - accepted
   * - ``CurrentMod = 1``
     - depth table in this file
     - accepted
   * - ``CurrentMod = 2``
     - current from the host SeaState field
     - rejected

``WaveKinMod = 1`` together with ``CurrentMod = 2`` is always rejected, because the
host's combined field cannot be split into a wave part and a current part. For the
host-coupled selectors, see :ref:`waterkin-file-modes` in :doc:`driver_format`.

A WaterKin current or wave replaces the deck's own ``current``/``waves`` rows; it
does not add to them. A deck that declares both is rejected (``... (double-counting);
keep one``). The WaterKin current and wave fields are then subject to the same
requirements as the inline options: both need ``dtM`` and ``TMax``, and
``WaveKinMod = 1`` also needs a flat ``WtrDpth`` seabed.

Current profile table
~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 8 12 10 70

   * - Col
     - Name
     - Unit
     - Meaning
   * - 1
     - ``z``
     - m
     - Level of the row. Use either elevations (all ≤ 0, ``0`` at the free surface)
       or positive-down depths (all ≥ 0). Depths are converted to ``z = -depth``. A
       column that mixes signs is rejected.
   * - 2
     - ``ux``
     - m/s
     - Current velocity in global x.
   * - 3
     - ``uy``
     - m/s
     - Current velocity in global y. There is no vertical current.

* After the two header rows, the reader checks up to four more lines for the first
  data row, skipping non-numeric lines. This handles both the old and new MoorDyn-F
  layouts. If none of the four lines is a data row, the file is rejected.
* After the first data row, the table ends at the first line that is not numeric: a
  terminator such as ``--- need this line ---``, a blank line, or end of file.
* A line that starts with a number but has a malformed ``ux`` or ``uy`` is rejected.
  Tokens after the third are ignored.
* At least two rows are required. Levels may be listed from the surface down or from
  the seabed up. After sorting, they must be strictly monotonic, and all values must
  be finite.
* Between levels the profile is interpolated linearly in ``z``. Above the top level
  and below the bottom level, the nearest level's velocity is used.

Wave-elevation history (``WaveKinFile``)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

With ``WaveKinMod = 1``, ``WaveKinFile`` holds a surface-elevation history with
two columns:

.. list-table::
   :header-rows: 1
   :widths: 8 14 10 68

   * - Col
     - Name
     - Unit
     - Meaning
   * - 1
     - ``time``
     - s
     - Sample time. The first sample must be at ``t = 0``. Times must be strictly
       increasing but do not need to be evenly spaced.
   * - 2
     - ``elevation``
     - m
     - Free-surface elevation η at the reference location: the origin, or the point of the
       ``WaveRefX`` and ``WaveRefY`` options, an extension of CableDyn.

* Blank lines are skipped. Lines before the first data row whose first token is not
  a number, such as a ``time elevation`` header, are skipped. Once data has
  started, a non-numeric line is an error, and that includes a ``#`` comment line.
  Tokens after the second are ignored.
* At least four rows are required, and all values must be finite.
* The history is resampled at ``dtWave`` by linear interpolation over
  ``[0, TMax)``. Rows after ``TMax`` are ignored. If the file ends before ``TMax``,
  the remaining samples are zero, not the last value. The resampled record is
  zero-padded to an FFT-friendly length, as MoorDyn-F does. It is then reduced once
  to Fourier components that travel in direction ``WaveDir``, and the mean
  elevation is kept as a still-water offset.
* ``TMax / dtWave`` may be at most 10\ :sup:`6` samples; a longer record is rejected
  (``WaterKin TMax/dtWave needs more than 1000000 wave samples``) because the one-time
  reduction grows with the square of the sample count.
* The components above the ``WvHiCOff`` option (default :math:`\pi` rad/s, 0.5 Hz) are
  dropped, as SeaState drops those of an elevation series; ``none WvHiCOff`` keeps them up to
  the Nyquist frequency of ``dtWave``, as MoorDyn-F does. A record with no component at or
  below the cut-off, for example a run shorter than 2 s, is refused by name.
* The record keeps about ``TMax WvHiCOff / (2 pi)`` components (150 for a 300 s run), or
  ``TMax / (2 dtWave)`` with ``none`` (600 at ``dtWave`` 0.25 s), against the 200 of a
  ``jonswap`` sea. Every node sums all of them for its surface elevation. Below the surface,
  the components too short to reach the node's depth are dropped once they cannot change its
  velocity and acceleration beyond round-off (:ref:`theory-waves`). The sum costs about 4 ns
  per node, component and step on one core of a current desktop: 3 ms per step for 300 nodes
  and 2,400 components, the 4,200 s record at ``WvHiCOff`` 3.6, against 2.5 ms for the solve
  of that line. A longer record costs proportionally more, and a larger ``dtM`` less.

Example
~~~~~~~

A WaterKin file with a two-level current profile and no waves:

.. code-block:: text

   MoorDyn v2 water kinematics file
   (header line 2)
   --------------------------- WAVES -------------------------------------
   0                    WaveKinMod  - type of wave input
   ""                   WaveKinFile - file containing wave elevation time series
   0.000000E+00  dtWave      - time step to use in setting up wave kinematics grid (s)
   0                    WaveDir     - wave heading (deg)
   2                                - X wave input type
   -24, 150, 100                    - X wave grid point data
   2                                - Y wave input type
   -100, 100, 5                     - Y wave grid point data
   2                                - Z wave input type
   -600, 0, 60                      - Z wave grid point data
   --------------------------- CURRENT -------------------------------------
   1                    CurrentMod  - type of current input
   z-depth     x-current      y-current
   (m)           (m/s)         (m/s)
   0.0  0.10  0.02
   -10.0  0.30  0.05
   --------------------- need this line ------------------

To drive waves from a history instead, set line 4 to ``1``, line 5 to the history
file (for example ``"eta.dat"``) and line 6 to a positive ``dtWave``. The history
file itself looks like this:

.. code-block:: text

   time elevation
   0.000000000000000E+00   5.000000000000000E-01
   3.125000000000000E-02   4.903926402016152E-01
   6.250000000000000E-02   4.619397662556434E-01

.. _syrope-files:

Syrope settings file and OWC table
----------------------------------

A Syrope polyester line type points to a *settings file*. The settings file names
the *original working curve* (OWC) table and sets the working-curve shape.

Deck reference
~~~~~~~~~~~~~~

The ``EA`` column of the LINE TYPES row holds ``SYROPE:<settings>|alpha|beta``, and
the ``BA`` column holds ``BA_s|BA_d``. From :file:`examples/syrope_polyester_mooring.dat`:

.. code-block:: text

   rope      0.1438  22.42   "SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"  5.0e10|1.0e5  0.0  1.0  0.0  1.0  0.0

.. list-table::
   :header-rows: 1
   :widths: 20 12 68

   * - Part
     - Unit
     - Rule
   * - ``SYROPE:<settings>``
     - --
     - The prefix is case-insensitive. The settings path is relative to the deck and
       must not be empty. If the column fills the input buffer, it is rejected rather
       than resolved to a shortened path.
   * - ``alpha``
     - N
     - Fast-spring constant. Must be > 0.
   * - ``beta``
     - --
     - Fast-spring constant. Must be > 0. The dynamic stiffness is
       ``EA_d = alpha + beta·T``.
   * - ``BA_s``, ``BA_d``
     - N·s
     - Both must be ≥ 0, and their sum must be > 0.

Each Syrope line type's files are read once, after the deck has been parsed. The
limits on the line itself are listed in :doc:`driver_format`. In short, it must be a
single-section, taut ``EI = 0`` line in a dynamic run, with no current, wave or
bathymetry loading.

Settings file
~~~~~~~~~~~~~

Each row has the form ``<value> <name> [description ...]``. Names are
case-insensitive. Rows with fewer than two tokens and rows with unknown names are
skipped. If a name appears more than once, the last row wins. All four names below
are required (``the Syrope settings file needs OWC, WCType, k1, and k2 rows``).

.. list-table::
   :header-rows: 1
   :widths: 14 86

   * - Name
     - Value
   * - ``OWC``
     - Path to the OWC table, relative to the settings file. It may be quoted.
   * - ``WCType``
     - ``LINEAR``, ``QUADRATIC`` or ``EXP``. Any other value is rejected.
   * - ``k1``
     - First shape parameter. ``LINEAR``: ``k1 ≥ 0``; a value ``k1 ≥ 1`` is read as
       the working-curve stiffness in N. ``QUADRATIC`` and ``EXP``: ``0 ≤ k1 < 1``.
   * - ``k2``
     - Second shape parameter. ``QUADRATIC``: ``0 < k2 ≤ 1``. ``EXP``: ``1e-6 ≤ k2 ≤ 700``.
       ``LINEAR`` does not use it, but the row is still required.

.. code-block:: text

   syrope_owc.dat  OWC     - Original working-curve table file (relative to this file)
   EXP             WCType  - Working-curve formulation {LINEAR; QUADRATIC; EXP}
   0.20            k1      - First working-curve shape parameter
   1.50            k2      - Second working-curve shape parameter

OWC table
~~~~~~~~~

.. list-table::
   :header-rows: 1
   :widths: 8 12 10 70

   * - Col
     - Name
     - Unit
     - Meaning
   * - 1
     - ``strain``
     - --
     - Axial strain as a fraction: ``0.02`` means 2 %.
   * - 2
     - ``tension``
     - N
     - Tension on the original working curve at that strain.

* Lines with no numeric token, such as the ``Strain Tension`` and ``(-) (N)``
  header rows, are skipped wherever they appear. Any line that contains a number
  must begin with two plain numbers. Tokens after the second are ignored.
* At least two rows are required, all values must be finite, and both columns must
  be strictly increasing.
* The table must still be valid after the fast spring is removed. Each tension must
  be above ``-alpha/beta``, and the strain that remains after subtracting the
  fast-spring strain must be strictly increasing. If ``alpha`` or ``beta`` is too
  soft for the table, the run is rejected (``the alpha/beta fast spring is too soft
  for this table``).
* Values are interpolated linearly. The running maximum tension must stay within
  the table's tension range, so the table has to cover the highest tension the line
  will reach.

From :file:`examples/data/syrope/syrope_owc.dat` (trimmed):

.. code-block:: text

   Strain      Tension
   (-)         (N)
   0.00000e+00 0.00000e+00
   2.06897e-03 1.71768e+05
   4.13793e-03 3.30952e+05
   ...
   6.00000e-02 4.38601e+06

Keep the deck, the settings file and the OWC table in the same relative layout, for
example :file:`examples/` and :file:`examples/data/syrope/`, so the relative paths
still resolve.
