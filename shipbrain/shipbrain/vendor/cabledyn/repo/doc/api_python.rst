.. SPDX-License-Identifier: Apache-2.0

Python API reference
====================

.. module:: cabledyn

This page documents every public name of the :mod:`cabledyn` package. Everything is imported
from the top-level package, for example ``from cabledyn import CableDynDriver, read_output``.
The workflows that use these objects are described in :doc:`python`.

Two groups of names have different installation requirements:

* The standalone-driver API (running decks, reading and analysing results, editing decks, batch
  studies, and all exception classes) is pure Python. It needs NumPy and, to run analyses, the
  ``CableDyn_driver`` executable, but never the CableDyn shared library.
* The in-process coupling API (:class:`CableDyn`, :func:`abi_version`, :func:`abi_minor`,
  :func:`library_path`, and :func:`version_string`) loads the CableDyn shared library the first
  time one of these names is accessed. These names are deliberately left out of
  ``cabledyn.__all__``, so
  ``from cabledyn import *`` works in an installation without the shared library.

Plotting methods import matplotlib and ``to_dataframe`` imports pandas only when they are
called; both are optional dependencies. Every plotting method returns the matplotlib axes it
drew on and draws on a new figure unless an ``ax`` is supplied. The exception is
:func:`animate`, which returns a matplotlib ``FuncAnimation``.

Unless stated otherwise, quantities are in SI units: metres, seconds, kilograms, and newtons.
Result objects are immutable, and the NumPy arrays they hold are read-only.

Running the standalone driver
-----------------------------

.. autoclass:: cabledyn.CableDynDriver
   :members:

.. autoclass:: cabledyn.DriverResult
   :members:

Batch studies
-------------

.. autofunction:: cabledyn.run_study

.. autoclass:: cabledyn.StudyResult
   :members:

.. autoclass:: cabledyn.StudyCaseResult
   :members:

Parameter sweeps
----------------

:func:`parameter_grid` builds the case specifications that :func:`generate_deck_cases`
consumes, from lists of values for each deck selector.

.. autofunction:: cabledyn.parameter_grid

Reading results
---------------

:func:`read_output` returns the most specific table class for the file it reads:
:class:`TimeHistory` for the main output, :class:`LineNodeHistory` and
:class:`LineSegmentHistory` for per-line dynamic outputs, :class:`StaticProfile` for the static
profile, :class:`NaturalModes` for the two tables of a ``.modes.out`` file, and
:class:`OutputTable` for any other numeric table. :class:`TimeHistory`, :class:`StaticProfile`,
:class:`NaturalModes` and :class:`ModeShapes` are subclasses of :class:`OutputTable`;
:class:`LineNodeHistory` and
:class:`LineSegmentHistory` are subclasses of :class:`TimeHistory`, so every table method is
available on them.

.. autofunction:: cabledyn.read_output

.. autoclass:: cabledyn.OutputTable
   :members:

.. autoclass:: cabledyn.TimeHistory
   :members:

.. autoclass:: cabledyn.LineNodeHistory
   :members:

.. autoclass:: cabledyn.LineSegmentHistory
   :members:

.. autoclass:: cabledyn.StaticProfile
   :members:

.. autoclass:: cabledyn.NaturalModes
   :members:

.. autoclass:: cabledyn.ModeShapes
   :members:

.. autoclass:: cabledyn.ChannelStatistics
   :members:

.. autoclass:: cabledyn.StaticLineSummary
   :members:

.. autoclass:: cabledyn.SpatialStatistics
   :members:

Reading other codes' outputs
----------------------------

These readers return the same table classes as :func:`read_output`, so statistics, fatigue,
spectra, plots, comparisons, and exports work unchanged on results of OpenFAST (maintained by
NLR, the National Laboratory of the Rockies, formerly NREL) and MoorDyn and on the files of an
OpenFAST run that uses CableDyn as its mooring module. :func:`read_table`
chooses the reader from the file name. Malformed files raise :exc:`OutputFormatError`.

.. autofunction:: cabledyn.read_table

.. autofunction:: cabledyn.read_openfast_output

.. autofunction:: cabledyn.read_moordyn_output

.. autofunction:: cabledyn.read_moordyn_line

.. autoclass:: cabledyn.MoorDynLineHistory
   :members:

.. autofunction:: cabledyn.read_coupled_run

.. autoclass:: cabledyn.CoupledRun
   :members:

Comparing runs
--------------

:func:`compare_histories` aligns two :class:`TimeHistory` tables on one time grid, without
extrapolating beyond the interval they share, and reports error metrics and statistic changes
for each channel. Differences are candidate minus reference, in the unit of the channel.

.. autofunction:: cabledyn.compare_histories

.. autoclass:: cabledyn.HistoryComparison
   :members:

.. autoclass:: cabledyn.ChannelComparison
   :members:

Signal processing
-----------------

Each function returns a new table of the same class as its input, with the same channels,
units, source path, and title; the input is never modified. The filters require uniform
sampling, so resample a variable-step record first.

.. autofunction:: cabledyn.resample

.. autofunction:: cabledyn.moving_average

.. autofunction:: cabledyn.fft_filter

Fatigue analysis
----------------

:meth:`TimeHistory.fatigue` is the usual entry point. The functions below apply the same
rainflow counting and damage-equivalent-range calculation to any scalar sequence.

.. autofunction:: cabledyn.rainflow_cycles

.. autofunction:: cabledyn.cycle_histogram

.. autofunction:: cabledyn.damage_equivalent_range

.. autoclass:: cabledyn.FatigueResult
   :members:

.. autoclass:: cabledyn.RainflowCycle
   :members:

.. autoclass:: cabledyn.RainflowHistogram
   :members:

Fatigue damage
--------------

A :class:`FatigueCurve` gives cycles to failure for a stress range (S--N, MPa) or a normalised
tension range (T--N). The factory functions return curves with published constants; the source is
in each docstring and in :attr:`FatigueCurve.source`. :func:`channel_damage` and
:func:`damage_along_arc` apply Palmgren--Miner damage to rainflow cycles, and
:func:`lifetime_fatigue` weights the damage of several sea states over a design life.

.. autoclass:: cabledyn.FatigueCurve
   :members:

.. autofunction:: cabledyn.dnv_rp_c203_curve

.. autofunction:: cabledyn.dnv_os_e301_curve

.. autofunction:: cabledyn.api_rp_2sk_curve

.. autofunction:: cabledyn.chain_nominal_area

.. autofunction:: cabledyn.miner_damage

.. autofunction:: cabledyn.channel_damage

.. autoclass:: cabledyn.ChannelDamage
   :members:

.. autofunction:: cabledyn.cable_stress

.. autofunction:: cabledyn.damage_along_arc

.. autoclass:: cabledyn.DamageProfile
   :members:

.. autofunction:: cabledyn.study_sea_state_damage

.. autoclass:: cabledyn.SeaStateDamage
   :members:

.. autofunction:: cabledyn.lifetime_fatigue

.. autoclass:: cabledyn.LifetimeFatigue
   :members:

Range graphs
------------

.. autoclass:: cabledyn.RangeGraph
   :members:

.. autofunction:: cabledyn.read_range_graphs

.. autofunction:: cabledyn.read_range_graph

.. autofunction:: cabledyn.node_range_graph

.. autofunction:: cabledyn.static_range_graph

.. autofunction:: cabledyn.element_range_graph

Design checks
-------------

.. autofunction:: cabledyn.bend_check

.. autoclass:: cabledyn.BendLimits
   :members:

.. autoclass:: cabledyn.BendCheck
   :members:

.. autofunction:: cabledyn.mbr_utilisation

.. autofunction:: cabledyn.tension_check

.. py:data:: DNV_OS_E301_STRENGTH_FACTOR
   :type: float
   :value: 0.95

   DNV-OS-E301 characteristic strength of a new chain or steel-wire-rope line body,
   ``S_C = 0.95 S_mbs``: the default ``strength_factor`` of :func:`cabledyn.tension_check`.
   Other line bodies take the factor of their design basis.

.. autoclass:: cabledyn.TensionCheck
   :members:

.. py:data:: API_RP_2SK_SAFETY_FACTORS
   :type: dict[tuple[str, str], float]

   API RP 2SK (3rd edition, 2005) factors of safety on the maximum line tension, keyed by
   (condition, analysis): intact 2.00 (quasi-static) and 1.67 (dynamic), damaged (one line
   broken) 1.43 and 1.25, transient 1.18 and 1.05.

.. py:data:: DNV_OS_E301_PARTIAL_FACTORS
   :type: dict[tuple[str, int], tuple[float, float]]

   DNV-OS-E301 (Ch.2 Sec.2) partial safety factors (gamma_mean, gamma_dyn) on the mean and
   dynamic tension, keyed by (limit state, consequence class): ULS class 1 (1.10, 1.50), ULS
   class 2 (1.40, 2.10), ALS class 1 (1.00, 1.10), ALS class 2 (1.00, 1.25).

Spectral analysis
-----------------

:meth:`TimeHistory.spectrum` and :meth:`TimeHistory.coherence` are the usual entry points. The
functions below apply the same Welch estimators to arrays held in memory.

.. autofunction:: cabledyn.power_spectrum

.. autofunction:: cabledyn.magnitude_squared_coherence

.. autoclass:: cabledyn.PowerSpectrum
   :members:

.. autoclass:: cabledyn.SpectralPeak
   :members:

.. autoclass:: cabledyn.CoherenceResult
   :members:

Extreme values
--------------

:func:`block_maxima` and :func:`upcrossing_maxima` sample extremes from a record;
:func:`fit_gumbel` and :func:`fit_weibull` fit a distribution to them. The fits describe the
sample they are given: they do not check independence or stationarity, do not extrapolate a
block length, and give no confidence interval.

.. autofunction:: cabledyn.block_maxima

.. autofunction:: cabledyn.upcrossing_maxima

.. autofunction:: cabledyn.fit_gumbel

.. autoclass:: cabledyn.GumbelFit
   :members:

.. autofunction:: cabledyn.fit_weibull

.. autoclass:: cabledyn.WeibullFit
   :members:

Line geometry
-------------

:func:`line_geometry` derives arc length, inclination, and a discrete curvature estimate from
the node coordinates of one line. These are post-processing estimates from the output nodes;
the solver's own curvature, tension, and angle channels, where written, are authoritative.

.. autofunction:: cabledyn.line_geometry

.. autoclass:: cabledyn.LineGeometry
   :members:

.. autoclass:: cabledyn.Touchdown
   :members:

.. autofunction:: cabledyn.touchdown_history

.. autoclass:: cabledyn.TouchdownHistory
   :members:

Deck editing and case generation
--------------------------------

:class:`DeckFile` edits an existing deck while preserving everything it does not change.
:class:`DeckWriter` builds a new deck from Python values. :func:`generate_deck_cases` writes a
family of edited decks for a batch study. It and :meth:`DeckModel.save` (with ``rebase=True``)
rewrite relative ancillary paths for the new folder and copy the fixed-name MoorDyn-C
kinematics files (``wave_elevation.txt`` for ``3 WaveKin``, ``wave_frequencies.txt`` for
``7 WaveKin``, ``current_profile.txt``, ``current_profile_dynamic.txt`` and ``current_profile_4d.txt``
for ``1``, ``2`` and ``5 Currents``), which the solver reads from the deck's
own folder, next to the new decks (:doc:`python`).

.. autoclass:: cabledyn.DeckFile
   :members:

.. autoclass:: cabledyn.deck_file.DeckRecord
   :members:

.. autoclass:: cabledyn.deck_file.OptionRecord
   :members:

.. autofunction:: cabledyn.generate_deck_cases

.. autoclass:: cabledyn.GeneratedCase
   :members:

.. autoclass:: cabledyn.DeckWriter(title="cabledyn deck")
   :members:

Deck object model
-----------------

.. autoclass:: cabledyn.DeckModel
   :members:

.. autoexception:: cabledyn.DeckReferenceError

.. autoclass:: cabledyn.SyropeEA
   :members:

The row and object classes (``LineType``, ``Line``, ``Section``, ``Point``, ``Body``, ``Rod``,
``Failure``, ``EndConnection``, ...) are dataclasses in ``cabledyn.builder``.

Snapshots and animation
-----------------------

.. autoclass:: cabledyn.Snapshots
   :members:

.. autoclass:: cabledyn.Recorder
   :members:

.. autofunction:: cabledyn.animation.record

.. autofunction:: cabledyn.animate

.. autoclass:: cabledyn.Seabed
   :members:

.. autoclass:: cabledyn.WaterSurface
   :members:

Results at a time
-----------------

.. autofunction:: cabledyn.line_positions

.. autoclass:: cabledyn.LinePositions
   :members:

.. autofunction:: cabledyn.line_field

.. autoclass:: cabledyn.LineField
   :members:

.. autofunction:: cabledyn.available_quantities

.. autofunction:: cabledyn.profile_at

.. autofunction:: cabledyn.profiles_at

.. autoclass:: cabledyn.ArcProfile
   :members:

.. autofunction:: cabledyn.line_range_graph

Clearance
---------

.. autofunction:: cabledyn.seabed_clearance

.. autoclass:: cabledyn.SeabedClearance
   :members:

.. autofunction:: cabledyn.line_clearance

.. autoclass:: cabledyn.LineClearance
   :members:

.. autofunction:: cabledyn.clearance_matrix

.. autoclass:: cabledyn.ClearanceMatrix
   :members:

.. autofunction:: cabledyn.segment_distance

.. autofunction:: cabledyn.read_bathymetry

.. autoclass:: cabledyn.Bathymetry
   :members:

Summary tables
--------------

.. autofunction:: cabledyn.channel_summary

.. autofunction:: cabledyn.line_summary

.. autoclass:: cabledyn.ChannelSummary
   :members:

.. autoclass:: cabledyn.LineSummary
   :members:

.. autoclass:: cabledyn.SummaryTable
   :members:

In-process coupling
-------------------

These names load the CableDyn shared library on first access; see :doc:`python` for how the
library is located. Array ordering, frames, and units at the coupling boundary follow
:doc:`coupling_boundary`, and the underlying C functions are described in :doc:`capi`.

.. py:class:: CableDyn(deck=None)

   One CableDyn solver instance behind the C ABI. The class is a context manager: leaving a
   ``with`` block calls :meth:`close`.

   :param deck: Path of a sectioned ``.dat`` deck; see :doc:`driver_format`. When given, the
      deck is parsed and its static initial condition is solved immediately, as by
      :meth:`init_deck`. ``None`` (the default) creates an uninitialised instance for a later
      :meth:`init_deck` call.
   :type deck: str | os.PathLike | None
   :raises CableDynError: if the handle cannot be created or the deck fails to initialise.
      A failed initialisation releases the handle before the exception propagates.
   :raises ValueError: if the deck path contains a NUL character or, on Windows, cannot be
      represented in the active ANSI code page.

   The coupled exchange is kinematics in, loads out. Kinematics are the position (m), velocity
   (m/s), and acceleration (m/s\ :sup:`2`) of every coupled point, three degrees of freedom per
   point. Loads are the forces (N) the lines exert on those degrees of freedom. Input arrays may
   be flat, shaped ``(n_coupled_dof,)`` with interleaved ``x, y, z`` values per point, or
   column-per-point, shaped ``(3, n_points)``. Returned arrays are always flat ``float64``
   arrays. A ``(3, 3)`` input is read column-per-point, so pass three points flat when in doubt.

   Calls on one instance are serialised by an internal lock. Independent instances may be used
   from different threads; their deck initialisations are serialised inside the library, their
   steps run concurrently. ``dt`` and ``fluid_density`` must be finite real numbers (``dt``
   positive, ``fluid_density`` non-negative) and arrays real-valued; other values raise
   ``TypeError`` or ``ValueError`` before the library is called.

   .. py:method:: close()

      Release the native handle. Calling it again is harmless.

   .. py:method:: init_line(q0, v0, elem_conn, l0, ea, rho_a, fixed_dofs, tension_only, rho_inf)

      Initialise from one line meshed by the caller (``CableDyn_InitLine``). The model is
      structural only: two-node ``EI = 0`` axial elements with a consistent mass matrix, without
      gravity, buoyancy, seabed, hydrodynamics or structural damping, and without a static solve.
      The handle has no deck and no points; the views of :attr:`lines` run from the last node of
      ``q0`` to its first.

      :param q0: Initial node positions (m), flat ``(3 * n_nodes,)`` or column-per-point
         ``(3, n_nodes)``; a ``(3, 3)`` array is rejected as ambiguous.
      :type q0: array_like
      :param v0: Initial node velocities (m/s), shaped as ``q0``.
      :type v0: array_like
      :param elem_conn: **1-based** node pair of each element, flat ``(2 * n_elem,)`` or
         ``(n_elem, 2)``. An integer array.
      :type elem_conn: array_like
      :param l0: Unstretched length of each element (m), ``(n_elem,)``.
      :type l0: array_like
      :param ea: Axial stiffness of each element (N), ``(n_elem,)``.
      :type ea: array_like
      :param rho_a: Mass per unit unstretched length of each element (kg/m), ``(n_elem,)``.
      :type rho_a: array_like
      :param fixed_dofs: **1-based** DOFs the caller prescribes, in the order of the coupled
         vector; node ``k`` owns DOFs ``3k-2``, ``3k-1`` and ``3k``. May be empty.
      :type fixed_dofs: array_like
      :param tension_only: If true an element goes slack instead of carrying compression.
      :type tension_only: bool
      :param rho_inf: Generalised-α spectral radius, in ``[0, 1]``.
      :type rho_inf: float
      :raises ValueError: on a wrong shape, a non-finite value, or ``rho_inf`` outside
         ``[0, 1]``, before the library is called.
      :raises TypeError: on a non-real array, a non-integer index array, or a non-numeric
         scalar, before the library is called.
      :raises CableDynError: if the library rejects the values (an index out of range, a repeated
         fixed DOF, a non-positive ``l0``, ``ea`` or ``rho_a``) or the initial acceleration solve
         fails. The handle must then be initialised again and a saved state is lost, unless it
         held a model on the coupled aggregate, which stays live with its save.

   .. py:method:: init_lines(n_nodes, n_elem, n_fixed, q0, v0, elem_conn, l0, ea, rho_a, fixed_dofs, tension_only, rho_inf, coupled_map=None)

      Initialise from several lines meshed by the caller (``CableDyn_InitLines``), each as in
      :meth:`init_line`, in one system. Every array is the concatenation, in line order, of that
      line's :meth:`init_line` array; ``elem_conn`` and ``fixed_dofs`` stay local to each line.

      :param n_nodes: Node count of each line, at least 2.
      :type n_nodes: array_like
      :param n_elem: Element count of each line, at least 1.
      :type n_elem: array_like
      :param n_fixed: Prescribed DOF count of each line, at least 0.
      :type n_fixed: array_like
      :param coupled_map: Connects lines at shared points. Every line has exactly six fixed DOFs,
         and entry ``6 * i + j`` (0-based ``i``, ``j``) is the **1-based** system DOF of line
         ``i``'s ``j``-th fixed DOF. The entries use every index from 1 to their maximum, which is
         the coupled DOF count; loads and Jacobian entries of a shared DOF are summed. ``None``
         keeps the lines independent, their ``fixed_dofs`` in turn forming the coupled vector.
      :type coupled_map: array_like | None
      :raises ValueError: as :meth:`init_line`, and if the counts do not match the arrays.
      :raises TypeError: as :meth:`init_line`.
      :raises CableDynError: as :meth:`init_line`, and on a ``coupled_map`` with a gap.

   .. py:method:: last_error()

      Return the library's most recent diagnostic message for this instance.

      :returns: The message, or an empty string when there is none.
      :rtype: str

   .. py:property:: init_notes

      The notes of the last deck initialisation, successful or not, on the point and aggregate
      routes alike: the ``Note:`` lines a driver run of the deck prints at its start, without
      the prefix. They take what is known at initialisation: the deck's current, also with a
      host field (:meth:`set_host_fluid`), and not a field the host applies afterwards. The
      notes of the march are not among them.

      :returns: One string per note, empty when there are none.
      :rtype: list[str]

   .. py:method:: init_deck(deck)

      Initialise from a deck file: parse it, build the model, and solve the static initial
      condition.

      :param deck: Path of the ``.dat`` deck. Relative ancillary files named in the deck are
         resolved as described in :doc:`driver_format`.
      :type deck: str | os.PathLike
      :raises CableDynError: if parsing, model construction, or the static solve fails. A
         failed initialisation keeps any previously initialised model.
      :raises ValueError: if the path contains a NUL character or, on Windows, cannot be
         represented in the active ANSI code page.

   .. py:method:: init_deck_at(deck, q0)

      Initialise from a deck file with the static initial condition solved at the host's
      positions of the coupled points (``CableDyn_InitDeckAt``). Every line-bound
      ``Coupled``/``Vessel`` point starts at its entry of ``q0`` instead of its deck coordinates;
      the lines, ``Free``/``Connect`` points, bodies and rods are solved in equilibrium with those
      points held there, at rest. A host whose body starts away from the deck coordinates then
      starts without a transient (:ref:`capi-host-coupling`).

      :param deck: Path of the ``.dat`` deck, as for :meth:`init_deck`.
      :type deck: str | os.PathLike
      :param q0: Either the full coupled vector of the deck (``n_coupled_dof`` values, the layout
         :meth:`step` uses; the ``Fixed``, ``Free`` and ``Connect`` blocks are not read), or the
         ``Coupled``/``Vessel`` blocks alone, in coupled-vector order (the ``MoorDyn_Init``
         layout of a deck whose coupled objects are points that are all attached to lines: a
         ``Coupled`` point attached to no line has no block here). Flat, or column-per-point
         ``(3, n)`` with ``n`` ≠ 3; positions in m.
      :type q0: array_like
      :raises CableDynError: if the deck fails to initialise, or ``q0`` does not match its
         coupled points. A failed initialisation keeps any previously initialised model and its
         saved state.
      :raises ValueError: if the path is rejected as by :meth:`init_deck`; if ``q0`` is a ``(3, 3)``
         array, which is ambiguous (column-per-point or row-per-point: pass three points flat);
         if ``q0`` has any other shape than flat or ``(3, n)``, or a length that is not a
         multiple of 3; or if ``q0`` is not finite.
      :raises RuntimeError: if the loaded library predates ABI 1 minor extension 2.

   .. py:method:: init_deck_rotating(deck, q0=None)

      Initialise from a deck for a host that turns the bodies its coupled points are fixed to
      (``CableDyn_InitDeckRotating``): :meth:`init_deck_at`, or :meth:`init_deck` with
      ``q0=None``, whose model takes each coupled block's rotation from
      :meth:`update_rotations` and passes it with every :meth:`update_states` and :meth:`step`.
      A line restrained in torsion (``END CONNECTIONS`` ``TorsStiffness``) and a ``Rigid`` bending
      end connection then turn with the host at their host-driven end, as on the coupled
      OpenFAST route; the other initialisations refuse a deck with a line restrained in torsion.
      The rotations start at identity (the deck's axes at the static start) and rest.

      :param deck: Path of the ``.dat`` deck, as for :meth:`init_deck`.
      :type deck: str | os.PathLike
      :param q0: The host positions of :meth:`init_deck_at`, or ``None`` for the deck positions.
      :type q0: array_like | None
      :raises CableDynError: as :meth:`init_deck_at`.
      :raises ValueError: as :meth:`init_deck_at`.
      :raises RuntimeError: if the loaded library predates ABI 1 minor extension 3.

   .. py:method:: update_rotations(dcm, omega, alpha)

      Set the host's rotation of every coupled block for the following :meth:`update_states`
      and :meth:`step` calls (``CableDyn_UpdateRotations``); it is kept until the next call and
      saved and restored with :meth:`save_state` and :meth:`restore_state`. Only a finite-EI
      line's host-driven end uses its block.

      :param dcm: ``(n_block, 3, 3)``: block ``k``'s global-to-body direction cosine matrix, its
         rows the body axes in global axes (the OpenFAST mesh orientation); identity is the body
         at its static-start attitude.
      :type dcm: array_like
      :param omega: ``(n_block, 3)``: the body's angular velocity in global axes (rad/s).
      :type omega: array_like
      :param alpha: ``(n_block, 3)``: the body's angular acceleration in global axes (rad/s²).
      :type alpha: array_like
      :raises ValueError: if an array has the wrong shape.
      :raises CableDynError: on a model not initialised by :meth:`init_deck_rotating`, or a
         matrix that is not proper orthogonal to 1e-8 or a non-finite value (the rotations are
         then unchanged).
      :raises RuntimeError: if the loaded library predates ABI 1 minor extension 3.

   .. py:method:: coupled_moments()

      Return the moments the lines apply to the host at the coupled points
      (``CableDyn_GetCoupledMoments``), at the state :meth:`calc_output` reports: block ``k``
      (entries ``3k .. 3k+2``, N m, global axes) is a finite-EI line's torsional and bending
      reaction about the coupled point at its host-driven end, zero for the other blocks and for
      ``EI = 0`` lines.

      :rtype: numpy.ndarray
      :raises RuntimeError: if the loaded library predates ABI 1 minor extension 3.

   .. py:method:: save_state()
                  restore_state()

      Save the whole model, and :attr:`time`, into the instance's single save slot; return to
      it (``CableDyn_SaveState``, ``CableDyn_RestoreState``). The slot is a copy of every line,
      point, body and rod state with its solver history. A restore keeps the slot, so one save
      serves every outer corrector of a host time step, and a restore followed by a step is
      bit-identical to taking that step from the saved state directly. Save when a host time
      step starts after the previous one was accepted, and restore on every repeated pass from
      the same start time, whatever its ``dt`` (:ref:`capi-host-coupling`). A successful
      initialisation discards the slot; a failed one keeps it with the model.

      :raises CableDynError: on an uninitialised model, or from :meth:`restore_state` when
         nothing was saved since the model was initialised.
      :raises RuntimeError: if the loaded library predates ABI 1 minor extension 2.

   .. py:method:: coupled_layout()

      Return the owner of each 3-DOF block of the coupled vector (``CableDyn_GetCoupledLayout``):
      a tuple of ``(point_id, kind)`` pairs, block ``k`` holding the degrees of freedom
      ``3k .. 3k+2``. ``kind`` is ``"fixed"``, ``"coupled"`` (``Coupled`` or ``Vessel``),
      ``"free"`` or ``"connect"``. On a point-system deck every line-bound point has a block, in
      deck ``POINTS`` order; on the coupled aggregate (finite-EI lines, bodies or rods) only the
      ``Coupled`` points do.

      :rtype: tuple[tuple[int, str], ...]
      :raises CableDynError: on an uninitialised model or one built from raw arrays.

   .. py:method:: host_dofs()

      Return the indices of the coupled degrees of freedom the host drives, those of the
      ``"coupled"`` blocks of :meth:`coupled_layout`, as an integer array. With ``x`` the
      ``(3, n)`` host positions of those points in layout order,
      ``q[model.host_dofs()] = x.reshape(-1, order="F")`` fills them in a full coupled vector.

      :rtype: numpy.ndarray

   .. py:property:: initialized
      :type: bool

      Whether the instance holds an initialised model.

   .. py:property:: n_coupled_dof
      :type: int

      Number of coupled degrees of freedom, three per host-driven point.

      :raises CableDynError: if the query fails, for example on an uninitialised model.

   .. py:property:: n_points
      :type: int

      Number of stored system points. This is the number of columns expected by
      :meth:`update_point_fluid_fields`.

      :raises CableDynError: if the query fails, for example on an uninitialised model.

   .. py:property:: n_lines
      :type: int

      Number of lines in the model.

      :raises CableDynError: if the query fails, for example on an uninitialised model.

   .. py:method:: get_coupled_motion()

      Return the current kinematics of the coupled points.

      :returns: ``(q, v, a)``: positions (m), velocities (m/s), and accelerations
         (m/s\ :sup:`2`), each a flat array of shape ``(n_coupled_dof,)``.
      :rtype: tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]
      :raises CableDynError: if the call fails, for example on an uninitialised model.

   .. py:method:: update_states(q, v, a)

      Transfer coupled-point kinematics to the model without advancing time. Use it when a
      host needs loads for trial kinematics before committing a step.

      :param q: Coupled-point positions (m).
      :type q: array_like
      :param v: Coupled-point velocities (m/s).
      :type v: array_like
      :param a: Coupled-point accelerations (m/s\ :sup:`2`).
      :type a: array_like
      :raises ValueError: if an array is neither flat ``(n_coupled_dof,)`` nor
         ``(3, n_coupled_dof // 3)``.
      :raises CableDynError: if the library rejects the call.

   .. py:method:: step(dt, q, v, a)

      Advance one implicit time step of length ``dt`` with the coupled-point kinematics
      prescribed at the end of the step, ``t + dt``.

      :param dt: Step length (s).
      :type dt: float
      :param q: Coupled-point positions at ``t + dt`` (m).
      :type q: array_like
      :param v: Coupled-point velocities at ``t + dt`` (m/s).
      :type v: array_like
      :param a: Coupled-point accelerations at ``t + dt`` (m/s\ :sup:`2`).
      :type a: array_like
      :returns: The number of Newton iterations used.
      :rtype: int
      :raises ValueError: if an array has the wrong shape.
      :raises CableDynError: if the step fails outright. The model is left at time ``t``.
      :raises ConvergenceError: if the step ends without meeting the Newton tolerance. The model
         has then already advanced to ``t + dt`` with its best iterate, so retrying the same
         step would advance time twice.

   .. py:method:: calc_output()

      Return the coupled reaction loads at the current committed state.

      :returns: Forces (N) the lines exert on the coupled degrees of freedom, a flat array of
         shape ``(n_coupled_dof,)``.
      :rtype: numpy.ndarray
      :raises CableDynError: if the call fails.

   .. py:method:: set_host_fluid(enable=True)

      Choose, before a deck initialization, whether the host supplies the ambient fluid.
      With ``enable``, the following :meth:`init_deck`, :meth:`init_deck_at` and
      :meth:`init_deck_rotating` take the field of :meth:`update_fluid_fields`: deck waves
      are refused and a steady deck current sets the static start only.

      :param enable: Whether the host supplies the fluid.
      :type enable: bool
      :raises CableDynError: if the call fails.

   .. py:attribute:: n_fluid_nodes

      Nodes of the host fluid field; zero without one.

   .. py:method:: fluid_node_positions()

      Committed positions of the fluid nodes, where the host evaluates the field of the
      coming step.

      :returns: Global positions (m), shaped ``(3, n_fluid_nodes)``.
      :rtype: numpy.ndarray
      :raises CableDynError: on a model built without a host fluid field.

   .. py:method:: update_fluid_fields(fluid_velocity, fluid_acceleration, waterline_z, dynamic_pressure=None)

      Prescribe the ambient fluid at every fluid node, held until the next call. Call it
      once with the field at ``t = 0`` before the first step, then before each step from
      ``t`` to ``t + dt`` with the field at ``t + dt`` at the positions of
      :meth:`fluid_node_positions`. The density is the deck's.

      :param fluid_velocity: Whole ambient velocity (m/s), global axes, shaped
         ``(3, n_fluid_nodes)`` or flat.
      :type fluid_velocity: array_like
      :param fluid_acceleration: Fluid acceleration (m/s\ :sup:`2`), with the same shape.
      :type fluid_acceleration: array_like
      :param waterline_z: Free-surface elevation above each node (m), ``(n_fluid_nodes,)``.
      :type waterline_z: array_like
      :param dynamic_pressure: Wave dynamic pressure (Pa) for the end caps of rods.
      :type dynamic_pressure: array_like, optional
      :raises CableDynError: on a model built without a host fluid field, or if the call
         fails.

   .. py:method:: calc_output_derivatives(q, v, a)

      Return the coupled loads at an operating point and their analytic Jacobians
      (``CableDyn_CalcOutputDerivatives``). Each line's interior DOFs are condensed out: interior
      positions and velocities are held and interior accelerations eliminated through the mass
      matrix, so ``dload_da`` is :math:`-(M_{cc} - M_{cf} M_{ff}^{-1} M_{fc})`, and the blocks are
      those of :meth:`update_states` followed by :meth:`calc_output`.

      This call **sets the model state**, as :meth:`update_states` does, also when a later stage
      of it fails; the previous state is not restored and :attr:`time` does not change. The
      library's unused ``eps_fd`` argument is not exposed.

      :param q: Operating-point positions (m).
      :type q: array_like
      :param v: Operating-point velocities (m/s).
      :type v: array_like
      :param a: Operating-point accelerations (m/s\ :sup:`2`).
      :type a: array_like
      :returns: ``(loads, dload_dq, dload_dv, dload_da, added_mass)``. ``loads`` is flat,
         ``(n_coupled_dof,)`` (N). The others are ``(n_coupled_dof, n_coupled_dof)`` with
         ``J[i, j]`` the derivative of load ``i`` with respect to coupled DOF ``j``: N/m, N·s/m,
         kg and kg; ``added_mass`` is ``-dload_da``.
      :rtype: tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray, numpy.ndarray, numpy.ndarray]
      :raises ValueError: if an array has the wrong shape or a non-finite value.
      :raises CableDynError: if the library rejects the call, as on a model on the coupled
         aggregate (finite-EI lines, bodies or rods), which has no load derivatives.

   .. py:method:: update_point_fluid_fields(fluid_velocity, fluid_acceleration, waterline_z, fluid_density)

      Prescribe external fluid kinematics at every system point.
      This is the interface for coupling to an external flow solver. Call it before
      :meth:`step`.

      :param fluid_velocity: Fluid velocity at each point (m/s), shaped ``(3, n_points)`` or
         flat ``(3 * n_points,)``.
      :type fluid_velocity: array_like
      :param fluid_acceleration: Fluid acceleration at each point (m/s\ :sup:`2`), with the
         same shape as ``fluid_velocity``.
      :type fluid_acceleration: array_like
      :param waterline_z: Global z coordinate of the free surface (m) at each point, shape
         ``(n_points,)``.
      :type waterline_z: array_like
      :param fluid_density: Fluid density (kg/m\ :sup:`3`).
      :type fluid_density: float
      :raises ValueError: if an array has the wrong shape.
      :raises CableDynError: if the library rejects the fields.

   .. py:property:: lines
      :type: tuple[cabledyn.objects.Line, ...]

      The model's lines in ascending deck id.

   .. py:property:: points
      :type: tuple[cabledyn.objects.Point, ...]

      The model's points in solver order.

   .. py:property:: bodies
      :type: tuple[cabledyn.objects.Body, ...]

      The model's Rigid6 bodies.

   .. py:property:: rods
      :type: tuple[cabledyn.objects.Rod, ...]

      The model's rods.

   .. py:method:: line(line_id)
                  point(point_id)
                  body(body_id)
                  rod(rod_id)

      Return the object with the given deck id.

      :raises KeyError: if there is no such object.

   .. py:method:: channel(token)

      Evaluate one output channel at the committed state and return its value. ``token`` uses
      the deck ``OUTPUTS`` vocabulary (:doc:`outputs`), for example ``FairTen1``, ``L2N5px``,
      ``Curv1N3``, ``Point4Fz``, ``Body1Pz``, or ``Rod2TenA``; the value equals what the
      standalone driver writes for that channel at the same state.

      :rtype: float
      :raises ValueError: if the token is empty or longer than 64 characters.
      :raises CableDynError: if the token is malformed or names an object the model lacks.

   .. py:method:: channels(tokens)

      Evaluate several channels; returns a ``(len(tokens),)`` array.

   .. py:method:: step_held(dt)

      Advance one step with every coupled point held at its current position (zero velocity
      and acceleration); returns the Newton iteration count, as :meth:`step`.

   .. py:property:: time
      :type: float

      Simulation time (s): 0 after initialisation, advanced by every completed step, and set back
      by :meth:`restore_state`.

   .. py:property:: deck
      :type: pathlib.Path | None

      Absolute path of the deck the model was initialised from.

Object views
~~~~~~~~~~~~

The classes returned by :attr:`CableDyn.lines`, :attr:`CableDyn.points`,
:attr:`CableDyn.bodies` and :attr:`CableDyn.rods`. They live in :mod:`cabledyn.objects`, which
imports without the shared library.

.. automodule:: cabledyn.objects
   :no-members:

.. autoclass:: cabledyn.objects.Line
   :members:
   :inherited-members:

.. autoclass:: cabledyn.objects.Point
   :members:
   :inherited-members:

.. autoclass:: cabledyn.objects.Body
   :members:
   :inherited-members:

.. autoclass:: cabledyn.objects.Rod
   :members:
   :inherited-members:

.. currentmodule:: cabledyn

.. py:function:: abi_version()

   Return the C ABI version of the loaded shared library. Importing the in-process API fails
   with :exc:`OSError` when the library's ABI version differs from the one this package
   supports.

   :rtype: int

.. py:function:: abi_minor()

   Return the extension level of ABI 1 of the loaded library: 4 when it also has the host
   fluid calls behind :meth:`CableDyn.update_fluid_fields`, 3 when it has the
   host-rotation calls behind :meth:`CableDyn.init_deck_rotating`,
   :meth:`CableDyn.update_rotations` and :meth:`CableDyn.coupled_moments`, 2 when it has the
   host-coupling calls behind :meth:`CableDyn.init_deck_at`, :meth:`CableDyn.save_state` and
   :meth:`CableDyn.coupled_layout`, 1 when it has the object queries behind
   :attr:`CableDyn.lines` and :meth:`CableDyn.channel`, 0 for an older library.

   :rtype: int

.. py:function:: library_path()

   Return the absolute path of the loaded CableDyn shared library.

   :rtype: str

.. py:function:: version_string()

   Return the loaded library's human-readable version string.

   :rtype: str

Exceptions
----------

All exception classes are importable without the shared library, so in-process errors can be
caught in any installation. The hierarchy is:

* :exc:`DriverError` (a :exc:`RuntimeError`): standalone-driver and result-file errors, with
  subclasses :exc:`DriverNotFoundError`, :exc:`DriverExecutionError`, and
  :exc:`OutputFormatError`.
* :exc:`DeckFormatError` and :exc:`StudyFormatError` (both :exc:`ValueError`): malformed input
  decks and study manifests.
* :exc:`DeckReferenceError` (a :exc:`ValueError`): a :class:`DeckModel` edit that would leave
  an object referenced by other deck objects, or a row that names an object of another model.
* :exc:`StudyOutputError` (an :exc:`OSError`): a study ran its cases but could not write its
  summary files.
* :exc:`CableDynError` (a :exc:`RuntimeError`): a failed in-process call, with subclass
  :exc:`ConvergenceError`.

.. autoexception:: cabledyn.DriverError

.. autoexception:: cabledyn.DriverNotFoundError

.. autoexception:: cabledyn.DriverExecutionError

.. autoexception:: cabledyn.OutputFormatError

.. autoexception:: cabledyn.DeckFormatError

.. autoexception:: cabledyn.StudyFormatError

.. autoexception:: cabledyn.StudyOutputError

.. py:exception:: CableDynError(call, status, detail)

   A CableDyn C API call failed.

   .. py:attribute:: call
      :type: str

      Name of the C function that failed, for example ``"CableDyn_Step"``.

   .. py:attribute:: status
      :type: int

      The C ABI status code: 1 ``BAD_HANDLE``, 2 ``ALLOC_FAIL``, 3 ``BAD_INPUT``,
      4 ``SOLVE_FAIL``, or 5 ``NOT_INITIALIZED``.

   .. py:attribute:: detail
      :type: str

      The library's diagnostic message for the handle, possibly empty.

.. py:exception:: ConvergenceError(call, detail, *, n_iter, stalled)

   An implicit step finished without meeting the Newton tolerance. A subclass of
   :exc:`CableDynError` with :attr:`~CableDynError.status` 4 (``SOLVE_FAIL``).

   The model has already advanced to ``t + dt`` and holds the best iterate found, so retrying
   the same step would advance time twice.

   .. py:attribute:: n_iter
      :type: int

      Number of Newton iterations performed.

   .. py:attribute:: stalled
      :type: bool

      Whether the line search stalled.
