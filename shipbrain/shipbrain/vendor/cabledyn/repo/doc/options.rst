.. SPDX-License-Identifier: Apache-2.0

OPTIONS reference and defaults
==============================

This page lists every keyword the ``OPTIONS`` section accepts, with every alias. Each keyword is
described with the same fields: value type and unit, default, valid values, the route that
consumes it, and an example record. The runnable :file:`examples/cabledyn_options_reference.dat`
shows every syntax form, including commented mutually exclusive alternatives. Every maintained
example repeats the common defaults that affect its route and links back to this page. A value
labelled *absent* is not represented by a magic number: omission itself is meaningful.

Record syntax
-------------

* **Scalar records** use the OpenFAST order ``value keyword``. Anything after the keyword is
  commentary, so ``0.05 dtM - Time step (s)`` and ``0.05 dtM time step`` are both valid.
* **Positional records** (``current``, ``waves``) put the model name first and the keyword last:
  ``airy 2.0 8.0 0.0 waves``. The ``dynamic_solver`` record puts its keyword first.
* **Descriptions.** In every OPTIONS record, the first ``-`` that has whitespace on both sides
  starts a description; it and everything after it are ignored. Negative numbers such as ``-1.0``
  are unaffected.
* **Keywords** are case-insensitive. An unknown keyword is fatal
  (``unknown OPTION keyword "<name>"``); CableDyn never silently ignores a misspelling.
* **Repeated keywords.** Records are applied in order, so the last record for a keyword wins
  (for example, a subsequent ``0 motionFile`` row disables an earlier path).
* **Numbers.** Every numeric value must be one plain number with a ``.`` decimal point
  (``1e-3``, ``0.05``, ``-50``). A value containing ``/``, ``,`` or ``;``, or written as a repeat
  count such as ``2*0``, is rejected with the deck line number instead of being read partially;
  ``1/20 dtM`` is an error, never ``dtM = 1``. Integer-valued options (for example
  ``recovery_max_substeps``, the quadrature orders, ``nModes``, ``StreamOrder`` and ``WaveSeed``)
  reject non-integral values.
* **Logical values** (for example ``modified_newton``, ``adaptive_mesh``, ``alpha_force_blend``
  and ``cable_load_feedback``) accept,
  case-insensitively, ``True``/``T``/``yes``/``y``/``on``/``1`` and
  ``False``/``F``/``no``/``n``/``off``/``0``. Any other spelling is an error.
* **File paths** are single whitespace-free tokens, optionally quoted, resolved relative to the
  deck's directory. They may contain ``/`` or ``\`` separators and may be longer than the
  64-character identifier limit. A ``#`` or ``!`` starts a comment even inside a path.

In the tables, *Standalone* means ``CableDyn_driver.exe``; *OpenFAST* means a ``CompMooring = 5``
(or ``Mod_SharedMooring = 5``) coupled run in OpenFAST, maintained by NLR (National Laboratory of
the Rockies, formerly NREL).

Environment and seabed
----------------------

.. list-table::
   :header-rows: 1
   :widths: 16 12 11 31 18 12

   * - Keyword and aliases
     - Type, unit
     - Default
     - Valid values and rules
     - Route
     - Example
   * - ``g`` / ``gravity``
     - real, m/s²
     - ``9.80665``
     - finite, > 0
     - both; OpenFAST host ``Gravity`` overrides the deck
     - ``9.80665 g``
   * - ``rhoW`` / ``WtrDnsty`` / ``water_density``
     - real, kg/m³
     - ``1025``
     - finite, > 0; also used by ``EQUIVALENT BUOYANCY`` conversion
     - both; OpenFAST host ``WtrDens`` overrides the deck
     - ``1025.0 rhoW``
   * - ``WtrDpth`` / ``water_depth``
     - real, m
     - absent: no flat seabed
     - finite, > 0; flat seabed at ``z = -WtrDpth``. Mutually exclusive with a
       ``bathymetryFile`` row. Required by ``waves``
     - both; OpenFAST uses host ``WtrDpth`` unless the deck names a ``bathymetryFile``
     - ``200.0 WtrDpth``
   * - ``bathymetryFile`` / ``bathymetry_file`` / ``seafloorFile`` / ``seafloor_file``
     - path
     - absent
     - non-empty. The file holds ``x y depth`` rows (plain numbers, any order, comments allowed)
       forming one complete rectangular grid of at least 2 × 2 points with no duplicate
       ``x y`` pair; depths finite and > 0
     - standalone static ``EI = 0``, independent-line ``EI = 0`` dynamic, ``Connect``/``Free``
       point-system, Hermite finite-EI dynamic, free/fixed rod, and Rigid6 decks (not Syrope
       lines); in OpenFAST the deck file overrides the host flat bed on supported routes
       (coupled Rigid6 decks require a flat ``WtrDpth``)
     - ``site.bty bathymetryFile``
   * - ``kBot`` / ``kb``
     - real, Pa/m (N/m³)
     - ``1.0e5``
     - finite, > 0 when a seabed is present. Mapped to each line node and rod contact station by
       local diameter × tributary length; a Free/Connect point with Mass or Vol, and a Point3
       buoy, over its footprint (Vol, or Mass/7850 kg/m³, to the power 2/3); a Rigid6 reference
       point uses a fixed 1 m² area
     - both
     - ``1.0e5 kBot``
   * - ``cBot`` / ``cb``
     - real, Pa·s/m (N·s/m³)
     - ``1.0e4``
     - finite, ≥ 0 when a seabed is present; scaled like ``kBot`` (per line node and rod contact
       station, and over the footprint of a Free/Connect point with Mass or Vol or a Point3
       buoy) and acts only on contacting nodes and points moving downward
     - both
     - ``1.0e4 cBot``
   * - ``frictionMu`` / ``mu`` / ``frictionCoefficient``
     - real, –
     - ``0`` (off)
     - finite, ≥ 0, or ``none``. A positive value needs ``WtrDpth`` or ``bathymetryFile``, and
       ``dtM``/``TMax`` in the standalone driver. Line nodes carry stick-slip friction springs; in
       a current the static solve holds the line with friction springs from its still-water laid
       shape, and the march continues them (``staticsFriction asLaid`` holds it toward its
       as-laid position instead, in still water too). Friction acts at the nodes, so a coarse
       grounded mesh steps the tension of the laid part; the initialisation report notes a
       finite-EI line whose grounded elements are too long (*Mesh resolution* in :doc:`theory`).
       The isotropic shorthand of
       ``frictionMuAxial``/``frictionMuLateral``. Not supported (the deck is rejected) with a
       ``FAILURE`` section, on a deck with ``Connect``/``Free`` points or ``Point3`` buoys, or
       on a deck whose lines attach to ``Rigid6`` bodies or rods unless it runs on the default
       standalone monolithic multibody march: ``staggered bodyScheme``, a ``motionFile``,
       ``Coupled``/``Vessel`` rods and every coupled OpenFAST deck with bodies or rods reject it
     - both, within the limits in this row
     - ``0.5 frictionMu``
   * - ``frictionMuAxial`` / ``frictionMuLateral`` (aliases in the rules)
     - real, –
     - ``frictionMu``
     - finite, ≥ 0. Anisotropic seabed friction of line nodes (the axial/normal pair of
       OrcaFlex, by Orcina): the coefficient along the line and across it. A row omitted takes
       ``frictionMu``; both must then be positive, or both zero. An equal pair is the isotropic
       law bit-for-bit. Rods and bodies, which have no line axis, use the lateral coefficient.
       The route limits of
       ``frictionMu`` apply. Aliases: ``frictionMu_axial``, ``mu_axial``, ``muaxial`` for the
       axial coefficient; ``frictionMu_lateral``, ``mu_lateral``, ``mulateral``,
       ``frictionMuNormal``, ``frictionMu_normal`` for the lateral one. See :doc:`theory`
     - both, within the limits of ``frictionMu``
     - ``0.2 frictionMuAxial``
   * - ``staticsFriction`` / ``statics_friction`` / ``staticsSeabedFrictionPolicy`` /
       ``seabedFrictionPolicy``
     - word
     - ``none``
     - ``none`` or ``asLaid`` (also ``as_laid``, ``as-laid``), case-insensitive; OrcaFlex's
       statics seabed friction policy. ``none``: the static solve is frictionless in still water
       and the friction anchors of the march start at the static node positions; in a deck
       current friction springs from the still-water equilibrium hold the line, and the anchors
       continue their static forces. ``asLaid``: the
       static solve resists the horizontal displacement of every grounded node from its as-laid
       position (the line laid from its lower end, the anchor or the fairlead when that is lower,
       along ``layAzimuth`` on the seabed at ``asLaidTension``, its top end then moved to its
       position; on a mesh the finite-EI statics refines, laid on the refined mesh) with the
       regularised Coulomb
       law of the dynamics, capped at ``mu N``, in still water and in a current, so a run on a
       slope with ``tan(slope) < mu`` holds and surplus length rests where it was laid; the
       march continues the springs. ``none`` is the default, as in MoorDyn: a run laid slack
       and pulled taut is held back by its friction, so the as-laid statics lowers anchor
       tensions (by up to ``mu w`` times the grounded length), and the frictionless statics is
       the conservative choice for anchor loads unless the as-laid layout and tension are
       known. Used only with ``frictionMu > 0`` and a seabed; rejected where the static
       equilibrium solves the lines without seabed friction: on decks with bodies, rods or
       ``Connect``/``Free`` points (``frictionMu`` itself is accepted on the default monolithic
       body and rod march), and on a finite-EI line between two moving points (End B on a
       ``Coupled``/``Vessel`` point, as a line shared between two turbines), which has no anchored
       end to lay it from. See
       :ref:`friction in statics <static-friction>`
     - both
     - ``asLaid staticsFriction``
   * - ``layAzimuth`` / ``lay_azimuth``, and ``layAzimuth<ID>``
     - real, deg
     - absent: each line's chord direction, from its lower end (anchor → fairlead, or
       fairlead → anchor when the fairlead is lower)
     - finite. Horizontal direction, from global +x toward +y, in which the line was laid away
       from its lower end (the anchor, or the fairlead when that is lower): the as-laid
       reference of ``staticsFriction asLaid``.
       ``layAzimuth`` sets every line; ``layAzimuth<ID>`` (the line ID appended, e.g.
       ``layAzimuth2``) sets line ``ID`` and overrides it. A direction off the vertical plane of
       the line ends puts the finite-EI static solve in 3D, as does a bathymetry sloping across
       that plane under the laid run. An ID that names no line is rejected
     - both
     - ``225.0 layAzimuth2``
   * - ``asLaidTension`` / ``as_laid_tension``, and ``asLaidTension<ID>``
     - real, N
     - ``0``
     - finite, ≥ 0. Effective tension with which the line was laid: the as-laid node spacing is
       the unstretched one times ``1 + asLaidTension/EA``, so a run on a level seabed whose
       static tension equals it carries no friction force. ``asLaidTension<ID>`` sets line ``ID`` alone, as for
       ``layAzimuth<ID>``
     - both
     - ``2.0e5 asLaidTension1``

Clock and initial condition
---------------------------

.. list-table::
   :header-rows: 1
   :widths: 16 12 11 31 18 12

   * - Keyword and aliases
     - Type, unit
     - Default
     - Valid values and rules
     - Route
     - Example
   * - ``bodyIC``
     - text
     - ``static``
     - ``static``: free ``Rigid6`` bodies and free rods, jointly with ``Free``/``Connect``
       points, start at their static equilibrium (weight, buoyancy, hydrostatic restoring,
       steady-current drag, seabed contact, and the attached lines re-solved). A body with no
       reachable or restrained equilibrium stops with an error naming it. ``deck``: they start
       at their deck pose, for example to release a body in a free-decay test. Coupled runs
       solve it with the host's coupled points at their initial (``PtfmInit``) pose
     - both
     - ``deck bodyIC``
   * - ``bodyWetting``
     - text
     - ``sphere``
     - ``sphere``: a ``Rigid6`` body's buoyancy, drag, fluid inertia, and added mass scale with
       the submerged fraction of an equivalent sphere at its centre of buoyancy (a dry body
       carries none). ``moordyn``: fully wet at any elevation, as in MoorDyn. Bodies with
       ``C33``/``C44``/``C55`` are always fully wet
     - both
     - ``moordyn bodyWetting``
   * - ``rodHydro``
     - text
     - ``exact``
     - ``exact``: a surface-piercing rod carries the hydrostatic moment of its displaced volume
       (waterplane second moment :math:`\pi d^4/64`). ``moordyn``: adds MoorDyn's
       :math:`\rho g (\pi d^4/32)\sin\varphi\cos\varphi` while End A is below the surface and End B
       above, reproducing MoorDyn-C's pitch stiffness
     - both
     - ``moordyn rodHydro``
   * - ``bodyHydro``
     - text
     - ``morison``
     - ``morison``: ``Rigid6`` bodies carry the fluid inertia :math:`\rho V (1 + C_a)\dot{u}`.
       ``moordyn``: they do not, as in MoorDyn
     - both
     - ``moordyn bodyHydro``
   * - ``bodyScheme``
     - text
     - ``monolithic``
     - ``monolithic``: free ``Rigid6`` bodies, ``Point3`` buoys, free and pinned rods and
       ``Free``/``Connect`` points step in one implicit generalised-alpha step with their
       ``EI = 0`` lines (a Newton iteration on the object accelerations around the line steps);
       no sub-stepping is needed for stability. A deck without lines keeps its explicit
       central-difference march, sub-stepped for the objects' own restoring, unless it names
       ``monolithic bodyScheme``. ``staggered``: the staggered predictor-corrector, sub-stepped
       for the stiffest body-mooring mode and the objects' own restoring. Decks with
       a ``motionFile`` or a ``FAILURE`` section, and coupled runs, use ``staggered`` whatever
       the value. See :doc:`theory`
     - standalone
     - ``staggered bodyScheme``
   * - ``bodySubstep``
     - text
     - ``accuracy``
     - ``accuracy``: the monolithic step divides each coupling step so that the estimated
       stiffest body-mooring frequency satisfies :math:`\omega\,\Delta t \le 0.28`, the
       accuracy of the staggered scheme's own sub-steps. ``none``: it takes ``dtM`` as given
       (stable at any ``dtM``; the body-mooring modes are then resolved only as far as ``dtM``
       allows). Ignored by ``staggered bodyScheme``, which always sub-steps
     - standalone
     - ``none bodySubstep``
   * - ``dtM`` / ``dt``
     - real, s
     - absent (static-only)
     - finite, at least ``1e-100`` (the time integration divides by ``dtM**2``). In the
       standalone driver ``dtM`` and ``TMax`` are given together or not at
       all; only ``TMax = 0``, which marches no step, needs no ``dtM``
     - standalone step; OpenFAST targets ``0.1`` s when absent, rounds it to at least one whole
       glue ``DT``, and reports the value used
     - ``0.05 dtM``
   * - ``TMax``
     - real, s
     - absent (static-only)
     - finite, ≥ 0 and an integer multiple of ``dtM``. ``TMax = 0`` runs the dynamic
       initialisation and writes the ``t = 0`` row: the static start of a dynamic deck, checked
       with every other option kept (motion records longer than ``TMax`` and a later
       ``RangeStart`` included), with or without ``dtM``
     - standalone only; OpenFAST uses the host ``TMax``. Do not copy the host duration into a
       coupled deck
     - ``600.0 TMax``
   * - ``RangeStart`` / ``range_start``
     - real, s
     - ``0``
     - finite, ≥ 0 and ≤ ``TMax`` (any value at ``TMax = 0``, where the graphs hold the
       ``t = 0`` row). First output time accumulated into the range graphs
       (``<out_root>.Line<L>.range.out``, ``LINES`` ``Outputs`` flag ``r``), so a start-up
       transient is left out. Needs at least one line with the ``r`` flag and, standalone,
       ``TMax``
     - both; OpenFAST holds it against the host ``TMax``. A FAST.Farm shared mooring rejects the
       ``r`` flag
     - ``100.0 RangeStart``

Nonlinear solver
----------------

Static-solver tolerances are built in and are not deck options; keys such as ``staticRelTol`` are
rejected as unknown. The dynamic Newton controls are set with ``dynamic_solver``.

.. list-table::
   :header-rows: 1
   :widths: 16 12 11 31 18 12

   * - Keyword and aliases
     - Type, unit
     - Default
     - Valid values and rules
     - Route
     - Example
   * - ``rhoInf`` / ``rho_inf``
     - real, –
     - ``0.4``
     - finite, in ``[0, 1]``; generalised-alpha high-frequency spectral radius. Smaller values
       damp the modes ``dtM`` does not resolve (axial waves, slack-taut transitions) faster;
       ``0`` annihilates them in one step. Above ``0.95`` the march has almost no numerical
       dissipation: those modes then keep the residual each Newton step leaves and the energy
       of under-resolved snaps, and the standalone driver prints a note. In an irregular sea a
       finite-EI lazy wave at ``1 rhoInf`` with a ``1e-4`` relative Newton tolerance peaked at
       2.0e5 N against 1.02e4 N (3.1e4 N at ``0.99``) and was exact with ``1e-6``; ``EI = 0``
       lines at ``1`` and
       ``1e-4`` failed the ``maxStrain`` guard, and at the default tolerance their peaks rose
       2 to 5 times at ``0.95`` to ``1``. Keep ``rhoInf`` at or below ``0.95``, or tighten the
       ``dynamic_solver`` relative tolerance to ``1e-6`` and resolve the snaps with ``dtM``
     - both
     - ``0.4 rhoInf``
   * - ``maxStrain`` / ``max_strain``
     - real, –
     - ``0.5``
     - finite, ≥ 0; ``0`` disables the strain bound. Plausibility guard checked after every
       committed dynamic step of the ``EI = 0`` lines: a non-finite nodal state, or any element
       stretched beyond this engineering strain (``0.5`` = 50 %, several times the breaking
       strain of steel, polyester, and nylon lines), stops the run with exit code 2 and a message
       naming the line, element, strain, estimated elastic tension, and time. It catches a
       numerically unstable march whose Newton residual still converges; a physical run never
       reaches the default. Finite-EI cables are guarded by ``tensile_safety`` instead. The static
       solve is not stopped by it: when the static fairlead strain of any line, ``EI = 0`` or
       finite-EI (tension over the EA of the End A section), exceeds this value, or 10 % when the
       OPTION is not given or is ``0``, the run prints a ``Note`` and continues
     - both for the dynamic guard (``EI = 0`` lines); standalone for the static note (every line)
     - ``0.5 maxStrain``
   * - ``dynamic_solver rel abs max_iter backtracks [rhoInf]``
     - keyword-first record: two reals, two integers, optional real
     - ``1e-8 1e-14 30 12``
     - ``rel`` and ``abs`` finite and > 0; ``max_iter`` an integer ≥ 1; ``backtracks`` an integer
       ≥ 0; the optional sixth token sets ``rhoInf`` (same range). ``EI = 0`` dynamic solves
       use all four controls. A finite-EI (Hermite) cable uses only ``rel`` and ``max_iter``
       for each step (``abs`` and ``backtracks`` are ignored on this route) and converges its
       static equilibrium to at least ``min(1e-6, rel)``, on every route: alone in a standalone
       deck, in a mixed ``EI = 0`` + finite-EI standalone deck, in OpenFAST
       (``CompMooring = 5``), in FAST.Farm and behind the C API, so a cable driven by the same
       motion steps to the same state on each. Use controls qualified for
       the mesh and load case; the maintained 952-element Gulf of Maine cable uses
       ``1e-4 1e-14 100 12``
     - both (see rules)
     - ``dynamic_solver 1e-8 1e-14 30 12``
   * - ``modified_newton`` / ``modifiednewton``
     - logical
     - ``False``
     - ``True`` enables guarded within-step tangent reuse on every dynamic solver the deck builds.
       It does not relax convergence tolerances and should be qualified against full Newton.
       Measured against full Newton on the example decks (one thread): 4 to 20 % faster on
       finite-EI cables, free-hanging or with a touchdown (lazy waves in waves, current and vessel
       motion, a buoyed cable, rods on a spar); 12 % slower on an ``EI = 0`` cable laid on a
       frictional seabed in a current, whose stick-slip friction makes a reused tangent take more
       iterations; within a few per cent elsewhere on ``EI = 0`` systems. A finite-EI cable in
       the monolithic step of the multibody march keeps full Newton, as it is stepped again from
       the same start at every coupling iteration (reuse there made ``mixed_body_rods_points.dat``
       7.0 s against 5.8 s);
       results move at the solver tolerance (Bergdahl mean cycle maxima within 0.16 %)
     - both
     - ``False modified_newton``
   * - ``recovery_max_substeps`` / ``recoverymaxsubsteps``
     - integer, –
     - ``1024``
     - integer from 4 to 65536. Maximum internal subdivisions after a stalled tension-only step
       or a failed or under-resolved finite-bending interval. The nominal host time grid and
       output times are unchanged; prescribed position, velocity, and acceleration follow one
       C2 quintic trajectory inside the interval. The standalone completion summary reports the
       recovered intervals and the largest subdivision count used
     - both
     - ``1024 recovery_max_substeps``
   * - ``ei0_substeps`` / ``ei0substeps``
     - word
     - ``auto``; ``off`` with ``False alpha_force_blend``
     - ``auto`` or ``off``. ``auto``: a converged step of an ``EI = 0`` line in which a segment
       that ends the step taut (above 0.1 % of the largest step-start tension) turned by more
       than ``ei0_substep_angle``, or a segment slack at the start of the step ended it above a
       quarter of the largest step-start tension while the step does not resolve the axial wave
       over the segment (the wave crosses it more than once per step), is solved again from the
       same committed state in ``max(4, ceil(turn/ei0_substep_angle))`` equal sub-steps (at most
       ``ei0_substep_max``). The tensions are those of the run audit (the elastic tension, or that
       of the viscoelastic or Syrope law), and the step-start tension is taken as at least 0.1 %
       of the line's initial tension, so a line slack all over at the step start does not count
       barely taut segments. The end motion inside the step follows
       the C2 quintic of the recovering step and the last sub-step lands on the given end state;
       the output and coupling times are unchanged. At ``dtM = 0.1`` s a taut segment of the
       Lozon 80 m all-chain mooring turns by up to 6 deg per step in 5 m / 7 s heave, and both
       generalised-α blends then give snap-load peaks 10 to 20 % low; with ``auto`` they are 4 %
       and 8 % low on average, within 4 % of the converged run sampled at the same 0.1 s output
       times, at 1.6 to 2.5 times the wall time of the plain steps on the 5 m / 7 s and
       10 m / 14 s motions (1.67 times over the 20-case Lozon mooring envelope). A step that
       triggers costs its plain step and usually four sub-steps, at most the plain step and
       three passes of ``ei0_substep_max`` sub-steps (49 line solves at the default) when the
       sub-stepped interval is measured again and that pass fails; where bodies or rods
       sub-cycle the lines ``n`` times per ``dtM`` (``staggered bodyScheme``, coupled runs),
       each sub-cycle is such a step, so the worst case is ``n (1 + 3 ei0_substep_max)`` line
       solves per ``dtM``. If a sub-step does not converge, the plain step's own result is
       kept. ``off`` takes every step as given, as before this option. ``monolithic
       bodyScheme`` is the default of every standalone deck with ``Rigid6`` bodies, ``Point3``
       buoys, rods or ``Free``/``Connect`` points on ``EI = 0`` lines (7 of the shipped example
       decks): its junction Newton needs the end reaction and tangent of the whole step, so the
       lines attached to those objects and points are not sub-stepped (a line whose ends are all
       fixed or anchored is), and the driver notes it once per run; ``staggered bodyScheme``
       sub-steps them. The standalone driver reports the sub-stepped steps per line, and
       OpenFAST and FAST.Farm runs report them at the end of the run. The settings are checked
       when the line is initialised. See :doc:`theory`
     - both (``EI = 0`` lines)
     - ``off ei0_substeps``
   * - ``ei0_substep_angle`` / ``ei0substepangle``
     - real, deg
     - ``1.0``
     - finite, in ``(0, 90]``. Largest chord turn of a taut segment in one step before
       ``ei0_substeps auto`` sub-steps it
     - both (``EI = 0`` lines)
     - ``1.0 ei0_substep_angle``
   * - ``ei0_substep_max`` / ``ei0substepmax``
     - integer, –
     - ``16``
     - integer from 2 to 1024. Most sub-steps ``ei0_substeps auto`` takes for one step; a step
       whose turn needs more is solved in this many, and the run notes it
     - both (``EI = 0`` lines)
     - ``16 ei0_substep_max``

Finite-EI cable controls
------------------------

.. list-table::
   :header-rows: 1
   :widths: 16 12 11 31 18 12

   * - Keyword and aliases
     - Type, unit
     - Default
     - Valid values and rules
     - Route
     - Example
   * - ``adaptive_mesh`` / ``adaptivemesh``
     - logical
     - ``False``
     - Permits finite-EI refinement when the static curvature diagnosis or mesh-scale contact
       chatter is fragile. Multiple adequately sampled grounded runs are allowed and are not
       treated as chatter merely because the contact topology has several islands. ``False``
       keeps the declared ``NumSegs`` authoritative but does not disable the folded-element
       safety check, nor the automatic refinement of a deck mesh that cannot resolve the
       curvature of the equilibrium (reported). When ``True``, reaching the refinement cap while
       the mesh remains fragile is reported. Node output channels keep naming the deck nodes
       on a refined mesh (:ref:`outputs-refined-nodes`)
     - both (finite-EI lines)
     - ``True adaptive_mesh``
   * - ``alpha_force_blend`` / ``alphaforceblend``
     - logical
     - ``True``
     - Generalised-α blend of the dynamics of finite-EI and ``EI = 0`` lines. ``True`` blends
       the forces of the two step ends; ``False`` evaluates the forces at the blended
       configuration :math:`q_{\alpha_f}` (Chung and Hulbert), the ``EI = 0`` scheme of 0.1.1 and
       earlier. On ``EI = 0`` lines ``False`` lets a segment that turns taut within a step carry
       the stretch extrapolated past the blended state, and lets a release create energy: on a
       light, axially stiff cable (80 kg/m, EA 8e8 N) under 3 m heave the fairlead peaks at
       4.2 MN against 0.10 MN with ``True`` at ``dtM = 2.5`` ms (converged finite-EI runs give
       0.093 MN; see :doc:`theory`). On finite-EI lines the blended
       tangent vectors are shortened while the line rotates and raise the mean tension at large
       ``dtM``: on the Lozon Gulf of
       Mexico 80 m cable in 3 m surge the mean hang-off tension is 12511 / 10097 / 9507 / 9360 N at
       ``dtM`` 0.1 / 0.05 / 0.025 / 0.0125 s with ``False`` and 9424 / 9322 / 9314 / 9311 N
       with ``True``. A run prints a note when a nodal tangent turns by more than 0.25 deg
       (``True``) or 0.1 deg (``False``) in one step. A dynamic run with a torsional line
       (``END CONNECTIONS`` ``TorsStiffness``) needs ``True``; a line restrained at one end only is
       otherwise solved without torsion (noted). The lines the raw C
       API builds without a deck (``CableDyn_InitLine``, ``CableDyn_InitLines``) always use
       ``True``: their only integrator setting is ``rho_inf`` (:doc:`capi`). ``False`` also
       turns ``ei0_substeps`` off unless the deck sets it
     - standalone and coupled (finite-EI and ``EI = 0`` lines)
     - ``False alpha_force_blend``
   * - ``cable_statics`` / ``cablestatics``
     - mode
     - ``continuation``
     - ``continuation`` solves a finite-EI cable from its exact ``EI = 0`` catenary by
       continuation in ``EI`` and falls back to the mesh-sequenced route; ``sequenced`` runs
       the mesh-sequenced route (coarse section-preserving hierarchy, ``EI`` and buoyancy
       continuation, prolongation) first and the continuation route as its fallback. Both
       results are audited; on the Lozon cables the two routes agree to the solver
       tolerance (see :doc:`theory`)
     - both (finite-EI lines)
     - ``sequenced cable_statics``
   * - ``OutputRecovery`` / ``output_recovery``
     - mode
     - ``equilibrium``
     - definition of the finite-EI node outputs (``Ten``, ``Curv``, ``BendMom`` channels, the
       static-profile and range-graph columns, ``.t.out`` segment tensions).
       ``equilibrium`` recovers them from nodal equilibrium: the effective tension
       :math:`\mathbf F\cdot\mathbf t`, the moment the neighbouring elements carry, and
       the geometric curvature (1 + strain) × moment / ``EI`` (see
       :ref:`theory-output-recovery`). ``element`` reports the
       length-weighted element-mean axial force :math:`EA(\lvert\mathbf r'\rvert - 1)`, the
       larger one-sided exact curvature (on an element with a bend stiffener sleeve, the recovered
       moment over ``EI(s)``), and the axial resultant at the element midpoint as the
       segment tension, the definitions of the releases before 0.2.0. End forces, positions, ``TDP``
       channels and the material-strain checks (``tensile_safety``, compression notes) are the
       same under both
     - both (finite-EI lines)
     - ``element OutputRecovery``
   * - ``axialDampingRatio`` / ``axial_damping_ratio``
     - mode
     - ``segment``
     - what a negative ``LINE TYPES`` ``BA`` is the damping ratio :math:`\zeta` of.
       ``segment`` (MoorDyn's convention): of each segment,
       :math:`BA = \zeta L_0 \sqrt{EA\,m}` per element, which damps the line's first axial mode
       at about :math:`\zeta\pi/(2N)` on :math:`N` elements, so the axial damping depends on
       the mesh; a dynamic run notes the ratio for each such line. ``mode1``: of the line's
       first axial mode, both ends held, from its sections' lengths, ``EA`` and dry mass, so
       the same on any mesh: :math:`BA = 2\zeta EA/\omega_1` on every element, a damping
       proportional to the stiffness, under which the axial mode :math:`n` is damped at
       :math:`\zeta\,\omega_n/\omega_1` (see :doc:`theory`). A positive ``BA`` is used as given
       under both. Under ``mode1`` a line with a negative ``BA`` and a viscoelastic
       (``ElasticMod`` 2 or 3) or Syrope section is refused by name
     - both (``EI = 0`` and finite-EI lines)
     - ``mode1 axialDampingRatio``
   * - ``axial_quadrature_order`` / ``axialquadratureorder`` / ``axial_quadrature``
     - integer, –
     - ``4``
     - integer from 1 to 6; Gauss order for the finite-EI axial energy. A value different from
       the bending order gives selective integration
     - both (finite-EI lines)
     - ``4 axial_quadrature_order``
   * - ``bending_quadrature_order`` / ``bendingquadratureorder`` / ``bending_quadrature``
     - integer, –
     - ``4``
     - integer from 1 to 6; Gauss order for the finite-EI curvature energy
     - both (finite-EI lines)
     - ``4 bending_quadrature_order``
   * - ``tensile_safety`` / ``tensilesafety``
     - mode
     - ``False``
     - ``True``/``T``/``yes``/``y``/``on``/``1``/``error`` reject axial compression outside the
       tolerance, judged on the element-mean axial force averaged over three elements (see
       :doc:`theory`); ``warn``/``warning``/``monitor`` commit the state, count accepted
       integration-step events, and report the worst force, threshold, element and time after a
       standalone run (the printed ``xi`` is always ``0.5``, the centre of the three-element
       window, because the audit judges element means); ``False``/``F``/``no``/``n``/``off``/``0``
       disable the audit (case-insensitive). A response diagnostic, not a tension-only
       constitutive law
     - both (finite-EI lines)
     - ``warn tensile_safety``
   * - ``tensile_strain_tolerance`` / ``tensilestraintolerance``
     - real, –
     - ``2e-6``
     - finite, ≥ 0; strain band used by the tensile audit. Changes require an engineering basis
       and should be recorded with the run settings
     - both (finite-EI lines)
     - ``2e-6 tensile_strain_tolerance``
   * - ``cable_load_feedback`` / ``cableloadfeedback``
     - logical
     - ``True``
     - ``False`` keeps the cable march, prescribed platform kinematics, host SeaState fields, and
       response channels active, but returns zero cable force and moment to the host: a
       controlled one-way comparison, not a physical operating configuration
     - OpenFAST (coupled finite-EI cables)
     - ``True cable_load_feedback``
   * - ``predictLoads`` / ``predict_loads``
     - logical
     - ``True``
     - with ``dtM`` larger than the glue ``DT``: ``True`` extrapolates the coupled loads between
       CableDyn solves from the last two, ``False`` holds the last solve's loads (about ``dtM/2``
       late). No effect at ``dtM = DT``; the output channels hold the committed samples either way
       (see :doc:`openfast`)
     - OpenFAST
     - ``False predictLoads``

Ambient fluid and prescribed motion
-----------------------------------

.. list-table::
   :header-rows: 1
   :widths: 16 12 11 31 18 12

   * - Keyword and aliases
     - Type, unit
     - Default
     - Valid values and rules
     - Route
     - Example
   * - ``current``
     - positional record, m and m/s
     - ``none``
     - ``none current``; ``uniform vx vy vz current``; or the two-level
       ``profile z1 vx1 vy1 vz1 z2 vx2 vy2 vz2 current``. Values finite; the two profile levels
       may be given in either order, are sorted by ``z``, and must differ. The static initial
       condition includes the steady drag of the current on the line at rest. Requires
       ``dtM``/``TMax`` in the standalone driver; a coupled deck takes its clock from the host.
       Use a WaterKin ``CurrentMod 1`` table for more levels; a deck with both is rejected
     - standalone; in OpenFAST, a single-turbine pure ``EI = 0`` deck without Rigid6 bodies or
       rods keeps it as a steady current when SeaState carries no waves or current. It is
       rejected when SeaState carries waves or current (double counting), in FAST.Farm, and on a
       deck with finite-EI cables, Rigid6 bodies or rods. On a pure ``EI = 0`` deck, a WaterKin
       ``CurrentMod 1`` table is the deck-side current that combines with a SeaState field
     - ``uniform 0.5 0 0 current``
   * - ``waves`` / ``wave``
     - positional record, m, s, deg
     - ``none``
     - ``none waves``; ``airy H T direction waves``; ``stream H T direction waves`` (alias
       ``dean``: the regular nonlinear stream-function wave, see ``StreamOrder``);
       ``jonswap Hs Tp gamma direction waves``; ``pm Hs Tp direction waves`` (aliases ``issc``,
       ``bretschneider``); ``torsethaugen Hs Tp direction waves``; or
       ``ochihubble Hs1 Tp1 lambda1 Hs2 Tp2 lambda2 direction waves`` (see :doc:`theory`).
       Height and period finite and > 0; ``gamma`` finite and ≥ 1; direction finite, in
       degrees. ``WaveSpreading`` spreads a spectral row. Requires ``dtM``/``TMax`` and ``WtrDpth``
       (a ``bathymetryFile`` does not satisfy it). Not combinable with WaterKin
       ``WaveKinMod 1``. A ``jonswap`` sea is synthesised from 200 long-crested components
       over ``[0.2, 5]`` times the peak frequency: one component per equal-width frequency
       bin, placed at a random frequency inside its bin with a random phase (see
       ``WaveSeed``), and scaled so the discrete spectrum gives exactly ``Hs``. The
       frequencies are not equally spaced, so the record does not repeat
     - standalone only; always rejected in a coupled OpenFAST or FAST.Farm deck, because the
       host SeaState supplies the waves
     - ``airy 2.0 8.0 0.0 waves``
   * - ``StreamOrder`` / ``stream_order``
     - integer, –
     - ``0`` (20 terms)
     - ``0`` or an integer from 2 to 60: the number of Fourier terms of a ``stream`` wave. A
       wave higher than 0.8 d or steeper than H/L = 0.142 is rejected, and a solution that
       does not converge fails with a named error
     - standalone ``stream`` waves
     - ``30 StreamOrder``
   * - ``nModes`` / ``n_modes`` / ``modes``
     - integer, –
     - ``0`` (off)
     - integer from 0 to 1000. Modal analysis of every line about its static equilibrium: the
       ``nModes`` lowest natural frequencies and mode shapes of ``K φ = ω² M φ`` (static
       tangent stiffness, structural plus added mass, ends held), written to
       ``<root>.modes.out`` before any dynamic march. Decks of lines between Fixed and
       Coupled/Vessel points on a flat ``WtrDpth`` seabed: all ``EI = 0`` lines (static or
       dynamic deck), or all finite-EI lines on the cubic-Hermite route (dynamic deck; a moving
       End B is held at its static position, as End A is). Other decks are rejected; a deck that
       mixes ``EI = 0`` and finite-EI
       lines stops with ``OPTION nModes is not supported for mixed EI=0/finite-EI decks;
       remove it or set it to 0``. A line restrained in torsion adds the twist angle of every
       node to its modes (``PolarShare`` and ``dTwist`` in :doc:`outputs`). The banded solver has
       no line-length limit: the 10 modes of a 1024-element finite-EI cable take a fraction of a
       second. See :doc:`theory`
     - standalone
     - ``10 nModes``
   * - ``WaveSeed`` / ``wave_seed``
     - integer, –
     - ``1``
     - integer from 1 to 2147483646. Seed of the ``jonswap`` component frequencies and phases:
       the same seed always gives the same sea on every platform, and a different seed gives an
       independent realisation. The stream is the Park–Miller MINSTD generator (multiplier
       48271, modulus 2\ :sup:`31` − 1) started from the seed scrambled by three rounds of a
       31-bit xorshift and one MINSTD step; each component draws its frequency offset, then its
       phase. Run several seeds for extreme-value statistics
     - standalone spectral waves and wave trains (train *i* uses seed + 7919 (*i* − 1))
     - ``7 WaveSeed``
   * - ``wavetrain`` / ``wave_train``
     - positional record, m, s, deg, –
     - none
     - one wave train of a multi-train sea; the rows add up (at most 16):
       ``airy H T direction wavetrain``, ``jonswap Hs Tp gamma direction s wavetrain``,
       ``pm Hs Tp direction s wavetrain``, ``torsethaugen Hs Tp direction s wavetrain``,
       ``ochihubble Hs1 Tp1 lambda1 Hs2 Tp2 lambda2 direction s wavetrain``. ``s`` is the
       cos-2s spreading exponent in [0, 1000]; ``0`` gives a long-crested train. Each train
       has its own heading. Not combinable with a ``waves`` row or ``WaveSpreading``. Same
       requirements as ``waves``
     - standalone; in OpenFAST rejected like ``waves``
     - ``jonswap 4 9 3.3 0 4 wavetrain``
   * - ``WaveSpreading`` / ``wave_spreading``
     - real, –
     - ``0``
     - cos-2s exponent in [0, 1000] of the spectral ``waves`` row: the energy is spread over
       ``direction ± 90°`` with ``D(θ) = K(s) cos^2s(θ − direction)``. ``0`` keeps the sea
       long-crested. Rejected with a regular (``airy``) wave, without waves, or with
       ``wavetrain`` rows
     - standalone spectral ``waves``
     - ``4 WaveSpreading``
   * - ``WaveDirections`` / ``wave_directions``
     - integer, –
     - ``9``
     - integer ≥ 1; equal-angle direction bins of a spread train (each with its own
       frequency set). Long-crested trains use one direction
     - standalone spread seas
     - ``15 WaveDirections``
   * - ``WaveComponents`` / ``wave_components``
     - integer, –
     - ``200``
     - integer ≥ 2; frequency components per train and direction. A ``jonswap`` waves row
       with the default 200 and no spreading keeps the original JONSWAP synthesis; any other
       value moves it to the spectral-sea synthesis. At most 100000 components in all
     - standalone spectral waves
     - ``400 WaveComponents``
   * - ``rampTime`` / ``ramp_time`` / ``tRamp``
     - real, s
     - ``0``
     - finite, ≥ 0; ``0`` disables the ramp. Scales every wave amplitude by the half-cosine
       ``r(t) = (1 − cos(πt/rampTime))/2`` from still water at ``t = 0`` to full height at
       ``t = rampTime``; the fluid acceleration includes the ramp rate, so the ramped field is
       kinematically consistent. The current is not ramped: the static initial condition already
       carries it, so ramping it would start the line out of equilibrium. Recommended for wave
       runs, which otherwise switch the full sea on at ``t = 0`` against a still-water static
       shape; one to two peak periods is typical
     - standalone ``waves``, ``wavetrain``, and WaterKin ``WaveKinMod 1`` waves
     - ``20.0 rampTime``
   * - ``VIVrmsWindow`` / ``viv_rms_window``
     - real, s
     - ``0``
     - finite, ≥ 0; the averaging time of the running RMS cross-flow velocity and acceleration
       of the VIV synchronisation model (:ref:`theory-viv`). ``0`` takes MoorDyn's 500 steps of
       the deck ``dtM``, also where OpenFAST steps CableDyn at a ``dtM`` adjusted to its ``DT``
       (500 steps of the first step when the deck has no ``dtM``); set it to compare runs at
       different ``dtM`` with the same averaging time
     - lines with a LINE TYPES ``Cl > 0``, on every route
     - ``0.25 VIVrmsWindow``
   * - ``VIVphaseSeed`` / ``viv_phase_seed``
     - mode
     - ``spread``
     - the initial phases of the VIV synchronisation model (:ref:`theory-viv`): ``spread`` starts
       node ``i`` from the deck's End A at ``2 pi i/N``, as MoorDyn-C; ``zero`` starts every node
       at zero, where MoorDyn-F in OpenFAST v5.0.0 starts (it does not carry its seed into its
       state). Where two lock-in branches coexist, the seed selects the one a run settles on
     - lines with a LINE TYPES ``Cl > 0``, on every route
     - ``zero VIVphaseSeed``
   * - ``motionFile``
     - path, or ``0``/``none``
     - absent
     - an active path requires ``dtM`` and ``TMax``; ``0`` or case-insensitive ``none`` disables
       it. On a deck with a line solved in torsion, an optional twelfth column rolls the frame of
       that line's moving end when that end is restrained in torsion (degrees, 0 at
       ``t = 0``). See the file
       grammar in :doc:`file_formats`
     - standalone ``Coupled``/``Vessel`` points, prescribed rods, and Rigid6 bodies; rejected
       on ``Connect``/``Free`` point-system, FAILURE, and mixed decks; forbidden in OpenFAST,
       where the host owns coupled motion
     - ``motion.dat motionFile``
   * - ``vesselMotion``
     - path, or ``0``/``none``
     - absent
     - a 6-DOF vessel record (19 values per row with roll/pitch/yaw, or 20 with a unit
       quaternion) on the ``dtM`` grid; every ``Coupled``/``Vessel`` point moves rigidly with the
       vessel from its deck position, and a finite or ``Rigid`` END CONNECTION at such a point
       turns with the vessel. An alternative to ``motionFile`` and ``vesselRAO`` (only one may
       be active); requires ``dtM`` and ``TMax``. Grammar in :doc:`driver_format`
     - standalone line decks accepted with a ``motionFile``; rejected on rod, Rigid6 and
       ``TURBINES`` decks and in OpenFAST
     - ``vessel.dat vesselMotion``
   * - ``vesselRAO``
     - path, or ``0``/``none``
     - absent
     - a displacement RAO table (amplitude and phase lag per DOF, per period and relative
       heading). The vessel motion is the RAO response to the deck linear waves (``airy``,
       spectral rows with ``WaveSpreading``, ``wavetrain`` rows, or a WaterKin ``WaveKinMod 1``
       file), each component at its own heading and phase, with ``rampTime``; a ``stream`` wave
       is rejected. Otherwise as ``vesselMotion``
     - as ``vesselMotion``, with deck waves
     - ``rao.dat vesselRAO``
   * - ``vesselRef``
     - ``x|y|z``, m
     - ``0|0|0``
     - three finite values: the vessel reference point at its reference pose, which is the
       rotation centre of ``vesselMotion``/``vesselRAO`` and the RAO origin (the point at which
       the wave phase is referenced)
     - ``vesselMotion``, ``vesselRAO``
     - ``90.0|0.0|-14.0 vesselRef``
   * - ``WaterKin`` / ``WaveKin``
     - ``0``/``none``, ``3``, ``7``, path, or ``SEASTATE``
     - ``0`` (no WaterKin policy)
     - ``0`` or ``none`` means still water from this record; ``3`` and ``7`` are the MoorDyn-C
       modes that read ``wave_elevation.txt`` and ``wave_frequencies.txt`` in the deck folder; a
       value containing a letter (other than an exponent ``e``) is a MoorDyn-F WaterKin
       filename; ``SEASTATE`` selects the host field. The other MoorDyn-C modes fail closed by
       name. Mode rules are in :ref:`moordyn-c-wavekin` and :ref:`waterkin-file-modes`
     - ``3``/``7`` and file ``WaveKinMod 1``: standalone decks only; ``SEASTATE``,
       ``WaveKinMod 2``, and ``CurrentMod 2``: OpenFAST and C API hosts with a host fluid field
     - ``waterkin.dat WaterKin``
   * - ``dtWave``
     - positive number [s]
     - ``0.25``
     - the step at which ``WaveKin 3`` resamples ``wave_elevation.txt`` (MoorDyn-C)
     - standalone
     - ``0.1 dtWave``
   * - ``WvHiCOff``
     - positive number [rad/s] or ``none``
     - ``3.14159`` (0.5 Hz)
     - the high cut-off frequency of an elevation record (WaterKin ``WaveKinMod 1``,
       ``WaveKin 3``): its Fourier components above it are dropped, as SeaState's ``WvHiCOff``
       zeroes the spectrum of an elevation series. ``none`` keeps them up to the Nyquist
       frequency of ``dtWave``, as MoorDyn-F's ``WaveKinMod 1`` does. A record with no
       component at or below the cut-off is refused
     - standalone
     - ``6.2832 WvHiCOff``
   * - ``WaveRefX``, ``WaveRefY``
     - number [m], at most 10\ :sup:`6` in magnitude
     - ``0``
     - the horizontal point that the phases of an elevation record or a component file
       (WaterKin ``WaveKinMod 1``, ``WaveKin 3`` and ``7``) refer to: the record was measured
       there, and each phase uses the position relative to it (:ref:`theory-waves`). An
       extension of CableDyn, which neither MoorDyn-C nor MoorDyn-F reads. A deck with any other
       sea, or none, is refused by name
     - standalone
     - ``250.0 WaveRefX``
   * - ``Currents``
     - ``0``, ``1``, ``2`` or ``5``
     - ``0``
     - the MoorDyn-C current file in the deck folder: ``1`` the steady profile
       ``current_profile.txt``, ``2`` the depth profile in time ``current_profile_dynamic.txt``,
       ``5`` the grid in x, y, z and time ``current_profile_4d.txt``, each interpolated as
       MoorDyn-C v2.7.1 does (:ref:`moordyn-c-wavekin`); ``3`` and ``4`` (no current source in
       MoorDyn-C v2.7.1) fail closed by name. ``current`` and a WaterKin table are the other
       sources; two sources in one deck are rejected
     - standalone
     - ``1 Currents``

MoorDyn compatibility-only keywords
-----------------------------------

These names exist so a migrated MoorDyn deck fails less often at the syntax boundary. They do
**not** tune CableDyn physics and should not be added to a new CableDyn model.

.. list-table::
   :header-rows: 1
   :widths: 22 18 60

   * - Keyword
     - Value
     - CableDyn behaviour
   * - ``tScheme``
     - any token
     - Accepted and ignored; CableDyn always uses implicit generalised-alpha.
   * - ``dtIC``, ``TmaxIC``, ``CdScaleIC``, ``threshIC``
     - plain number
     - Parsed strictly and ignored; CableDyn uses a Newton static initial condition rather than
       MoorDyn dynamic relaxation.
   * - ``WriteLog``
     - plain number
     - Parsed strictly and ignored; reporting uses the normal CableDyn/OpenFAST diagnostics.
   * - ``inertialF``, ``inertialF_rampT``
     - plain number
     - ``inertialF 1`` is accepted without effect: CableDyn always returns the inertia of coupled
       bodies and rods (``Coupled``/``Vessel`` and ``CoupledPinned``/``VesselPinned``) with
       their coupled loads, as MoorDyn-F's ``inertialF 1``. ``0`` (MoorDyn-F's default, no
       inertia) and ``2`` (the inertia ramped in) are rejected by name. ``inertialF_rampT``, the
       ramp time of ``inertialF 2``, is parsed strictly and ignored.
   * - ``dtOut``
     - plain number
     - Parsed strictly and ignored. Standalone output follows ``dtM``; coupled ``.CD.out``
       follows committed CableDyn solves; OpenFAST's main table follows host ``DT_Out``.
   * - ``mu_kT``, ``mu_kA``
     - any
     - Rejected by name: the MoorDyn-F seabed friction coefficients map to ``frictionMu`` with
       ``frictionMuLateral`` (for ``mu_kT``) and ``frictionMuAxial`` (for ``mu_kA``).
   * - ``mc``, ``cv``, ``FricDamp``, ``StatDynFricScale``
     - any
     - Rejected by name: CableDyn applies one regularised Coulomb friction set by
       ``frictionMu``, ``frictionMuLateral`` and ``frictionMuAxial``, with no static-to-kinetic
       ratio or friction damping. Remove the row.

Other MoorDyn constructs that fail by name rather than as unknown input:
``CoupledPinned``/``VesselPinned`` rods and bodies outside a coupled host (they run in OpenFAST,
see :doc:`openfast`). Line-node output channels start at node 1 (``N0`` is rejected; MoorDyn numbers from 0, see
:ref:`node numbering <outputs-moordyn-node-numbers>`), and a number
with a sign inside its mantissa (such as ``1+2``) is rejected instead of being read up to the sign.

Water-kinematics sources
------------------------

A WaterKin file keeps its independent ``WaveKinMod`` and ``CurrentMod`` selectors. Host modes
require the OpenFAST aggregate and a compatible SeaState field; the standalone driver rejects them
with ``WaterKin WaveKinMod 2/SEASTATE is coupled-only``. The detailed supported matrix is in
:ref:`waterkin-file-modes` in :doc:`driver_format`.

With no WaterKin policy, OpenFAST uses its complete SeaState field when one exists. Explicit file
selectors are authoritative: for example, file ``WaveKinMod=0`` and ``CurrentMod=1`` means no host
waves and only the file current profile. A coupled deck cannot carry inline ``waves`` or
``wavetrain`` rows: the host SeaState supplies the waves, so such a deck is rejected at
initialisation. An inline ``current`` row is kept as a steady current only on a single-turbine,
pure ``EI = 0`` deck without Rigid6 bodies or rods whose SeaState carries no waves or current; it
is rejected when SeaState carries waves or current, in FAST.Farm, and on a deck with finite-EI
cables, Rigid6 bodies or rods.

Standalone versus OpenFAST checklist
------------------------------------

For a standalone static calculation, omit both ``dtM`` and ``TMax`` or set ``TMax=0`` (``dtM`` is
then optional) when exercising the dynamic initialisation route. For standalone dynamics, provide
both and ensure ``TMax/dtM`` is integral. ``current``, ``waves``, ``motionFile``, a positive
``frictionMu``, rods, bodies, ``Connect``/``Free`` points, and finite-EI sections (outside a mixed
deck) all need the ``dtM``/``TMax`` pair or ``TMax=0``. File paths are resolved relative to the deck and may use
ordinary nested paths longer than the 64-character deck-identifier limit.

For ``CompMooring = 5``, OpenFAST owns gravity, density, flat depth, platform motion, run duration,
and its output clock. The CableDyn deck owns line properties, mesh, contact coefficients,
``rhoInf``, Newton policy, optional ``dtM``, and CableDyn output channels. The console prints the
actual ``dtM`` and its integer ratio to glue ``DT``; archive that line with production results.
