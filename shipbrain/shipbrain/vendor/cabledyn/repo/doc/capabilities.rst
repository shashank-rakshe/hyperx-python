.. SPDX-License-Identifier: Apache-2.0

Capabilities and route selection
================================

CableDyn deliberately exposes several execution routes over one solver core. A feature can be
implemented in the core yet unavailable on a particular route because that caller does not provide
the required motion, fluid field, or restart state. Use this page to choose the route before
writing a deck. The evidence behind every checked item is recorded in :doc:`validation`; rejected
combinations fail closed with a named error.

Execution routes
----------------

.. list-table::
   :header-rows: 1
   :widths: 19 25 30 26

   * - Route
     - Boundary owner
     - Best use
     - Start here
   * - Released ``CableDyn_driver.exe``
     - deck coordinates, held ends, ``motionFile``, ``vesselMotion``, or ``vesselRAO``
     - static design, property checkout, prescribed-motion dynamics, waves/current studies
     - :doc:`standalone_driver`
   * - Source-build ``cabledyn``
       (``build/cabledyn``; ``build\bin\cabledyn.exe`` with the conda toolchain on Windows)
     - same deck route as the release driver
     - source builds, tests, and research automation
     - :doc:`installation`
   * - CableDyn-enabled ``openfast.exe`` (OpenFAST, maintained by NLR, the National Laboratory of
       the Rockies, formerly NREL)
     - OpenFAST platform/body motion and SeaState
     - full turbine simulations, DLCs, mixed mooring/power-cable systems, FAST.Farm
     - :doc:`openfast`
   * - Python executable wrapper
     - a Python process launching the standalone driver
     - parameter sweeps, managed output, post-processing
     - :doc:`python`
   * - C ABI / in-process Python API
     - the embedding program
     - CFD and custom co-simulation with explicit kinematics-in/loads-out ownership
     - :doc:`capi`

Line and constitutive capability
--------------------------------

.. list-table::
   :header-rows: 1
   :widths: 28 20 52

   * - Model
     - Status
     - Scope
   * - Linear ``EI = 0`` chain, wire, polyester, nylon
     - Supported
     - static and implicit dynamics; taut, semi-taut, and grounded catenary configurations
   * - Composite line
     - Supported
     - one line assembled from ordered sections with independent type, length, and mesh density
   * - Finite-EI bending cable
     - Supported
     - production cubic-Hermite static/dynamic path for suspended and flat/structured
       seabed-contact cables in standalone and OpenFAST-coupled use; a line between two moving
       points (End B on a ``Coupled``/``Vessel`` point: a cable shared by two floaters, a
       FAST.Farm shared line) has both ends driven, standalone, in OpenFAST, FAST.Farm and the C
       API, with end connections and torsion at both ends; on the standalone multibody march
       a line between two objects (both ends on Rigid6 bodies or rod ends) is driven by both
       objects, coupled in its monolithic step and balanced in its static solve
   * - Mixed ``EI = 0`` + finite-EI deck
     - Supported with route limits
     - a mixed deck of lines between held or coupled points only (no bodies, rods, or
       ``Free``/``Connect`` points) runs in OpenFAST and standalone as a static run or a dynamic
       run with held ends or a ``motionFile``/``vesselMotion`` prescription; standalone it takes
       the deck current (``current`` OPTION, WaterKin ``CurrentMod 1``, MoorDyn-C ``Currents``
       ``1``/``2``/``5``) as the single-line routes do and rejects deck waves (so ``vesselRAO``
       too); a mixed deck with bodies, rods, or
       ``Free``/``Connect`` points runs standalone on the multibody march, with moving objects
       and deck waves/current, but not with a ``motionFile``
   * - Viscoelastic rope (MoorDyn ``ElasticMod`` 2/3)
     - Supported
     - per-element series-Kelvin state (standard linear solid only when ``BA_D = 0``),
       including load-dependent dynamic stiffness; ``EI = 0`` lines, with active line control
       in coupled OpenFAST runs (the slow-branch stretch carried over the length change, as in
       MoorDyn)
   * - Syrope polyester
     - Supported with limits
     - dynamic line with OWC and two history states, single-section and taut or between
       linear-elastic ``EI = 0`` sections (chain–polyester–chain), with the seabed, Morison loads,
       current, waves, host fluid fields and VIV of any ``EI = 0`` line, and active line control
       of a Syrope segment in coupled OpenFAST runs (its slow stretch carried over the length
       change, as in MoorDyn); finite-EI combinations fail closed by name
   * - Torsion of finite-EI lines
     - Supported with limits
     - isotropic torsion of a finite-EI line restrained in torsion at both ends, or at one end
       with the other free to twist (the free end carries no torque and turns with the twist of
       the line: the stretch's under ``GJ|K``, and torsional waves in dynamics; on every route
       and with every feature below that takes a line restrained at both ends)
       (``END CONNECTIONS`` torsion columns, explicit ``GJ``), with torque–tension coupling
       (``GJ|K``): condensed (uniform torque) in statics with a stability check and buckling
       descent, and a twist angle at every node in dynamics, with the polar inertia ``Irn`` and
       torsional damping (``GJ|K|Bt``),
       with turning Rigid6 bodies (the ends of rods fixed to them included), ends of ``Fixed``
       rods, ``vesselMotion``/``vesselRAO`` and the ``motionFile`` roll column standalone
       (``vesselMotion`` and the roll column also on a mixed ``EI = 0`` + finite-EI deck), and
       with the platform orientation in coupled OpenFAST and FAST.Farm runs (torque returned to
       the platform, ``PtfmInit``, checkpoints, linearisation with the twist angles as states;
       see :doc:`openfast`) and through the C API with the host's rotations
       (``CableDyn_InitDeckRotating``, :doc:`capi`), active line control (``CONTROL``) of the
       fairlead segment on the coupled route; ``Torq``/``Twist`` channels and range
       graphs. Stopped by name: ``CableDyn_InitDeck``/``InitDeckAt`` (which move the line ends by
       translation only), ends of free and pinned rods (axisymmetric, no roll angle) and of
       ``Coupled``/``Vessel`` rods, bodies other than Rigid6 and ``False alpha_force_blend``.
       Modal analysis carries the twist angle of every node. Not modelled: seabed friction
       against twist, anisotropic sections, self-contact of a loop (see :ref:`theory-torsion`)
   * - Hockling loops, nonlinear cross-section laws
     - Not provided
     - the buckling onset and the post-buckled shape are computed, but a loop that closes on
       itself is not resolved; the secondary Cosserat path (:doc:`solver_paths`) is not a
       production route
   * - Discrete attachments (``ATTACHMENTS``: buoyancy modules, clumps)
     - Supported
     - lumped at nodes of a finite-EI cable, standalone and coupled, also on a line restrained in
       torsion (they add no polar inertia to its twist)
   * - Bend stiffeners (``STIFFENERS``)
     - Supported with limits
     - tapered linear-elastic sleeve over a finite-EI line end, adding bending stiffness, mass,
       buoyancy and drag per element, standalone and coupled; nonlinear (moment–curvature)
       materials and bend restrictors are not provided
   * - Modal analysis (``nModes``)
     - Standalone only
     - natural frequencies and mode shapes of each line about its static equilibrium (all
       ``EI = 0`` lines, or all finite-EI lines on the Hermite route with their end connections
       and attachments; flat seabed); a line restrained in torsion adds the twist angle of every
       node, so its torsional modes and the torque's effect on the others appear
   * - Cross-flow VIV (LINE TYPES ``Cl``, ``dF``, ``cF``)
     - Standalone and coupled
     - MoorDyn v2's synchronisation model on ``EI = 0`` lines and, as a distributed lift, on
       finite-EI cables of the Hermite and multibody marches (:ref:`theory-viv`), with the
       host's fluid field on the coupled routes and its state in the checkpoint; in-line VIV is
       not provided

Loads and environment
---------------------

.. list-table::
   :header-rows: 1
   :widths: 28 20 52

   * - Feature
     - Status
     - Important ownership rule
   * - Gravity and displaced-volume buoyancy
     - Supported
     - SI input; water density may come from the deck or OpenFAST environment
   * - Morison drag, added mass, Froude–Krylov
     - Supported
     - line and supported rigid-object fields use the same nodewise fluid contract
   * - Flat seabed contact and friction
     - Supported
     - declare ``WtrDpth``, ``kBot``, ``cBot`` and optional friction; supported for coupled
       finite-EI touchdown cables as well as EI = 0 lines
   * - Anisotropic seabed friction
     - Supported with limits
     - ``frictionMuAxial``/``frictionMuLateral`` (OrcaFlex axial and normal coefficients), within
       the friction limits listed in :doc:`options`
   * - Structured bathymetry
     - Supported with limits
     - mutually exclusive with flat ``WtrDpth``; coupled finite-EI cables query the global
       surface through their chord frame; see :doc:`driver_format`
   * - Uniform/profile current
     - Supported
     - standalone deck source; coupled runs use explicitly selected host/file sources
   * - MoorDyn-C currents in time and space (``Currents 2``, ``Currents 5``)
     - Standalone only
     - ``current_profile_dynamic.txt`` and ``current_profile_4d.txt``, interpolated as MoorDyn-C
       v2.7.1 does at every node's position and time, the static start included, on every
       standalone route (the mixed ``EI = 0`` + finite-EI deck too); see
       :ref:`moordyn-c-wavekin`
   * - Airy and JONSWAP waves
     - Supported
     - standalone deck source or OpenFAST SeaState, never an accidental double source
   * - Regular nonlinear (Dean stream-function) waves
     - Standalone only
     - deck ``stream H T dir waves``, ``StreamOrder``
   * - ISSC/Pierson-Moskowitz, Torsethaugen and Ochi-Hubble spectra, cos-2s spreading,
       multiple wave trains
     - Standalone only
     - deck ``waves``/``wavetrain`` rows with ``WaveSpreading``; see :doc:`options`
   * - Prescribed vessel motion (``vesselMotion``, ``vesselRAO``)
     - Standalone only
     - a 6-DOF vessel record, or the RAO response to the deck waves, moves every
       ``Coupled``/``Vessel`` point of a line deck; see :doc:`options`
   * - Range graphs (``r`` line output flag, ``RangeStart``)
     - Standalone and OpenFAST
     - minimum, maximum, and mean along each line over the run, from the committed steps; a run
       restarted from a checkpoint keeps them. A FAST.Farm shared mooring and the C API reject
       the flag by name
   * - WaterKin CurrentMod-1 file table
     - Supported
     - bit-identical to the equivalent inline depth profile
   * - WaterKin WaveKinMod-1 history
     - Standalone only
     - resampled over ``TMax``; caller-driven use fails closed because the aggregate has no
       self-driven per-step wave refresh
   * - WaterKin WaveKinMod-2 / in-file ``SEASTATE``
     - Coupled only
     - consumes the host SeaState through the OpenFAST shell and requires that field to exist

Topology and coupled objects
----------------------------

CableDyn's native objects are finite-element lines and boundary attachments. ``POINTS``, ``BODIES``,
and ``RODS`` are MoorDyn-compatible deck records that the driver translates; they are not an
alternative discretisation of the line. Supported translations include fixed/coupled/vessel
attachments, free or connecting masses and clumps, ``Point3`` buoys, ``Rigid6`` bodies, and coupled
rigid rods. In OpenFAST, ``Coupled``/``Vessel`` bodies and rods are platform-borne 6-DOF nodes that
return a force and a moment, ``CoupledPinned``/``VesselPinned`` rods turn about a platform-borne
node that takes the platform position only and returns a force with zero moment, as do
``CoupledPinned``/``VesselPinned`` bodies about a node at their reference point, and ``Pinned``
rods turn about a fixed End A. A coupled deck (OpenFAST, the C API and Python) carries bodies or
rods, not both, a rod fixed to a body counting as a rod; the standalone driver's multibody march
takes both, as does MoorDyn (``CompMooring = 3``). The C API and Python
run free, fixed and pinned rods and free bodies in still water or in a field the host supplies
at the nodes (:doc:`capi`). The coupled body/rod routes carry
checkpoint state and SeaState drag, Froude–Krylov, and added mass.
``Rigid6`` also carries the documented hydrostatic restoring terms. Consult :doc:`driver_format`
before using an imported object because unsupported fields fail closed.

OpenFAST coverage
-----------------

The ``CompMooring = 5`` shell covers normal coupled time-domain stepping with its own ``dtM``,
nonzero ``PtfmInit``, correction iterations, SeaState fields, checkpoint/restart, scoped
linearisation with the line dynamics, line failures, active-tension control of ``EI = 0`` lines
(linear-elastic, viscoelastic or Syrope segments) and finite-EI cables, and FAST.Farm shared
moorings. Restart and linearisation do not arise under
FAST.Farm, which does not call those module operations, and active-tension control is rejected
there. See :doc:`openfast` for setup and :doc:`coupling_boundary` for the interface contract.

How to interpret this page
--------------------------

``Supported`` means the route is implemented and covered by regression tests, not that every
conceivable combination is valid. Physical source ownership still matters. When two requested
features cannot be separated without double counting—for example a host field whose private
current cannot be split from its wave field—CableDyn stops rather than guessing. The fatal message
and :doc:`troubleshooting` identify the conflicting sources.
