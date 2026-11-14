.. SPDX-License-Identifier: Apache-2.0

Examples
========

The ``examples/`` folder ships ready-to-run input decks. It is part of the source archive —
download **Source code (zip)** from the release page (:doc:`installation`); the executables do not
contain it. Every standalone deck below was run with ``CableDyn_driver.exe`` for this release;
the run time is the wall time on an ordinary desktop.

.. code-block:: powershell

   New-Item -ItemType Directory -Force results | Out-Null   # the driver does not create it
   .\CableDyn_driver.exe .\examples\<deck>.dat .\results\<root>

Use the closest deck as a template, copy it under a new name, and keep every file it references
(motion, Syrope, bathymetry) in the same relative location. The deck grammar is in
:doc:`driver_format`, every option in :doc:`options`, and every output in :doc:`outputs`.

**Route** is the solver path the deck exercises: *cable* (``EI = 0`` element), *Hermite*
(finite-EI bending element), *points/bodies* (``EI = 0`` lines coupled to dynamic points, bodies,
or rods), or *mixed* (both elements in one deck). **Static** decks stop at the equilibrium;
**dynamic** decks march in time from it; **modal** decks compute natural periods and mode shapes
about it.

Start here
----------

.. list-table::
   :header-rows: 1
   :widths: 36 40 12 12

   * - Deck
     - What it shows
     - Route
     - Run time
   * - ``chain_catenary_shallow_30m.dat``
     - 270 m R4 chain in 30 m of water, mostly grounded — the :doc:`quickstart` deck
     - cable, static
     - < 1 s
   * - ``chain_catenary_r3_100m.dat``
     - 550 m R3 chain in 100 m, classic grounded catenary — :doc:`tutorial_catenary`
     - cable, static
     - < 1 s
   * - ``wd0050_chain.dat``
     - 410 m chain in 50 m with a long grounded length, fairlead at the surface, plus
       point-position channels
     - cable, static
     - < 1 s
   * - ``cabledyn_options_reference.dat``
     - a runnable 30 m chain whose active rows show every common default; commented rows show
       each alternative form of current, waves, WaterKin, motion, and bathymetry
     - cable, static
     - < 1 s
   * - ``chain_modes.dat``
     - the 12 lowest natural periods and mode shapes (``nModes``) of the 100 m R3 chain
       catenary, written to ``<root>.modes.out`` — :doc:`tutorial_catenary`
     - cable, modal
     - < 1 s

Mooring configurations
----------------------

.. list-table::
   :header-rows: 1
   :widths: 36 40 12 12

   * - Deck
     - What it shows
     - Route
     - Run time
   * - ``spread_3line_chain.dat``
     - IEA-15MW VolturnUS-S three-line chain spread, 200 m — :doc:`tutorial_spread`
     - cable, static
     - < 1 s
   * - ``spread_4line_chain.dat``
     - symmetric four-line spread and multi-line output selection
     - cable, static
     - < 1 s
   * - ``iea15mw_volturnus_mooring.dat``
     - one line of the VolturnUS-S spread, for single-line comparisons
     - cable, static
     - < 1 s
   * - ``taut_chain_steep.dat``
     - steep, near-taut chain with almost no grounded length
     - cable, static
     - < 1 s
   * - ``wire_catenary_mooring.dat``
     - steel-wire catenary with wire mass, stiffness, and drag
     - cable, static
     - < 1 s
   * - ``composite_chain_wire.dat``
     - chain + wire composite on a penalty seabed: one line, two sections
     - cable, static
     - < 1 s
   * - ``composite_chain_poly_chain.dat``
     - chain–polyester–chain: one line, three ordered sections
     - cable, static
     - < 1 s
   * - ``composite_chain_poly_chain_modes.dat``
     - the 12 lowest natural periods and mode shapes (``nModes``) of that composite line, partly
       grounded, with each section's added mass and the linearised seabed contact
     - cable, modal
     - < 1 s
   * - ``semitaut_chain_polyester.dat``
     - Lozon et al. (2025) Gulf of Maine 200 m semi-taut composite (chain at the anchor,
       polyester above)
     - cable, static
     - < 1 s
   * - ``lozon_gomex80_mooring.dat``, ``lozon_gomaine200_mooring.dat``,
       ``lozon_humboldt800_mooring.dat``
     - the single-line moorings of the three Lozon sites (80, 200, 800 m); the 200 m and 800 m
       decks use the viscoelastic ``Es|Ed`` / ``Bs|Bd`` rope form, with dynamic-branch values
       labelled in each deck as assumptions because the paper tabulates only the static ``EA``
     - cable, static
     - < 1 s

Synthetic ropes
---------------

A rope's ``EA`` and ``BA`` tokens select the constitutive model; see :doc:`tutorial_ropes` and,
for the equations, the viscoelastic (series-Kelvin) and Syrope sections of :doc:`theory`.

.. code-block:: text

   polyester_linear  0.1438 22.42  1.424e8                         -0.8          0.0  1.2 0.2 1.0 0.0
   polyester_ve      0.1438 22.42  1.424e8|2.50e8                 4.0e9|1.1e7   0.0  1.2 0.2 1.0 0.0
   nylon_mean_load   0.1500 24.00  6.0e7|1.00e8|0.4              4.0e9|1.1e7   0.0  1.2 0.2 1.0 0.0
   polyester_syrope  0.1438 22.42  "SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"  5.0e10|1.0e5  0.0  1.0 0.0 1.0 0.0

.. list-table::
   :header-rows: 1
   :widths: 36 40 12 12

   * - Deck
     - What it shows
     - Route
     - Run time
   * - ``polyester_catenary_mooring.dat``
     - 690 m semi-taut polyester leg with a single linear ``EA``
     - cable, static
     - < 1 s
   * - ``nylon_taut_mooring.dat``
     - taut nylon leg with a single linear ``EA``
     - cable, static
     - < 1 s
   * - ``ve_polyester_catenary_mooring.dat``
     - the polyester leg with the viscoelastic (series-Kelvin) model, constant dynamic stiffness
       (MoorDyn ``ElasticMod 2``: ``EA`` = ``Es|Ed``, ``BA`` = ``Bs|Bd``)
     - cable, static
     - < 1 s
   * - ``ve_nylon_loaddependent_mooring.dat``
     - viscoelastic nylon with mean-load-dependent dynamic stiffness (``ElasticMod 3``:
       ``EA`` = ``Es|alphaMBL|vbeta``)
     - cable, static
     - < 1 s
   * - ``ve_polyester_dynamic_waves.dat``
     - the viscoelastic polyester leg under a 1.5 m, 10 s Airy wave for 10 s
     - cable, dynamic
     - < 1 s
   * - ``syrope_polyester_mooring.dat``
     - Syrope working-curve polyester with a ``SYROPE IC`` load history; needs
       ``data/syrope/syrope_settings.dat`` and ``data/syrope/syrope_owc.dat``
     - cable, dynamic
     - < 1 s
   * - ``composite_chain_syrope_chain.dat``
     - chain–Syrope polyester–chain mooring on a vessel in a 12 s surge, heave and pitch record;
       needs ``data/syrope/`` and ``data/vessel/vessel_surge_heave_pitch_12s_dt005.txt``
     - cable, dynamic
     - < 1 s
   * - ``composite_ve_syrope_jonswap.dat``
     - two chain–polyester–chain legs of one floater, the polyester viscoelastic (``Es|Ed``) on
       one and Syrope on the other, the floater moved by ``data/vessel/sample_rao.txt``
       (``vesselRAO``) in a JONSWAP sea that also loads the lines: the two rope models side by side
     - cable, dynamic
     - ~2 s

Dynamic environment
-------------------

.. list-table::
   :header-rows: 1
   :widths: 36 40 12 12

   * - Deck
     - What it shows
     - Route
     - Run time
   * - ``dynamic_chain_held.dat``
     - 10 s still-water march from equilibrium; the tension must not drift —
       :doc:`tutorial_dynamics`
     - cable, dynamic
     - < 1 s
   * - ``dynamic_chain_current.dat``
     - the same line in a 1 m/s uniform current
     - cable, dynamic
     - < 1 s
   * - ``dynamic_chain_waves.dat``
     - the same line under a 2 m, 8 s Airy wave (Morison, Froude–Krylov, wetting)
     - cable, dynamic
     - < 1 s
   * - ``chain_torsethaugen_spread.dat``
     - the same chain in a short-crested Torsethaugen sea (Hs 5 m, Tp 11 s, cos-2s
       ``WaveSpreading`` s = 4) — :doc:`tutorial_dynamics`
     - cable, dynamic
     - ~1 s
   * - ``chain_two_train_sea.dat``
     - a two-train sea: a spread JONSWAP wind sea plus a long-crested swell from 60°
       (``wavetrain`` rows) — :doc:`tutorial_dynamics`
     - cable, dynamic
     - ~1 s
   * - ``moordynC_wavekin/chain_wavekin7_currents1.dat``
     - MoorDyn-C water kinematics: ``WaveKin 7`` (``wave_frequencies.txt``) and ``Currents 1``
       (``current_profile.txt``) read from the deck folder — :doc:`tutorial_dynamics`
     - cable, dynamic
     - < 1 s
   * - ``moordynC_currents/chain_wavekin3_currents2.dat``
     - MoorDyn-C ``WaveKin 3`` (the elevation record ``wave_elevation.txt``, reduced to its
       Fourier components) and ``Currents 2`` (``current_profile_dynamic.txt``: a sheared current
       that turns across the line and grows over the run) on a partly grounded chain held by
       seabed friction
     - cable, dynamic
     - < 1 s
   * - ``moordynC_currents/chain_currents5_grid.dat``
     - MoorDyn-C ``Currents 5``: the grid in x, y, z and time ``current_profile_4d.txt``, a cross
       current growing along the line and ramped in over 30 s
     - cable, dynamic
     - < 1 s
   * - ``stream_wave_shallow_chain.dat``
     - the 30 m R4 chain under a steep Dean stream-function wave (H 8 m, T 10 s,
       ``StreamOrder`` 20) — :doc:`tutorial_dynamics`
     - cable, dynamic
     - < 1 s
   * - ``airy_wave_shallow_chain.dat``
     - the same chain, wave height and period with linear Airy theory, for comparison
     - cable, dynamic
     - < 1 s
   * - ``chain_range_tdp.dat``
     - a 410 m chain in 50 m whose fairlead surges 5 m at 30 s under a 6 m, 10 s Airy wave: range
       graph (``Outputs`` flag ``r``, ``RangeStart``) and touchdown-point channels; plot it with
       ``plot_range_envelope.py`` — :doc:`tutorial_python`
     - cable, dynamic
     - < 1 s
   * - ``laid_cable_cross_current.dat``
     - a laid cable in a 1.2 m/s cross current held by anisotropic seabed friction
       (``frictionMuAxial`` 0.3, ``frictionMuLateral`` 1.0) — :doc:`tutorial_dynamics`
     - cable, dynamic
     - < 1 s
   * - ``chain_sloped_bathymetry_friction.dat``
     - the chain of ``chain_range_tdp.dat`` on a structured seabed (``bathymetryFile``
       ``data/bathymetry/sloped_seabed.txt``) that rises toward the anchor and slopes across the
       line, held by seabed friction from its as-laid layout (``staticsFriction asLaid``) under
       the surging fairlead
     - cable, dynamic
     - < 1 s
   * - ``composite_axial_damping_mode1.dat``
     - the chain–polyester–chain mooring under a 4 m Airy wave with ``axialDampingRatio mode1``:
       a negative ``BA`` of −0.02 damps the line's first axial mode (2.03 Hz) at 2 % on any mesh
     - cable, dynamic
     - < 1 s
   * - ``viv_taut_line_crossflow.dat``
     - cross-flow VIV (``LINE TYPES`` ``Cl``, ``dF``, ``cF``; ``VIVphaseSeed``,
       ``VIVrmsWindow``): a taut 100 m line locks in across a 0.15 m/s current at a mid-span
       amplitude A/D of 0.66, MoorDyn-F's; the ``Outputs`` flag ``V`` writes the nodal lift —
       :ref:`theory-viv`
     - cable, dynamic
     - ~2 s

Points, buoys, bodies, and rods
-------------------------------

.. list-table::
   :header-rows: 1
   :widths: 36 40 12 12

   * - Deck
     - What it shows
     - Route
     - Run time
   * - ``clump_weight_free_point.dat``
     - a chain ending in a 20 t clump weight modelled as a ``Free`` point
     - points, dynamic
     - < 1 s
   * - ``connect_weighted_point.dat``
     - two lines meeting at a force-balanced weighted ``Connect`` point
     - points, dynamic
     - < 1 s
   * - ``rigid6_buoy.dat``
     - a submerged 6-DOF ``Rigid6`` buoy on three taut polyester legs in current —
       :doc:`tutorial_bodies`
     - bodies, dynamic
     - < 1 s
   * - ``rod_moored_spar.dat``
     - a buoyant free rigid rod held by four polyester legs in current, with rod end-position
       output
     - rods, dynamic
     - < 1 s
   * - ``buoy_clamped_cable.dat``
     - a floating ``Rigid6`` buoy on three taut legs with a finite-EI cable clamped at its keel
       (``END CONNECTIONS`` ``Rigid`` on a ``Body1`` point), 30 s of swell —
       :doc:`tutorial_bodies`
     - bodies, dynamic
     - ~6 s
   * - ``spar_pinned_rods.dat``
     - a free ``Rigid6`` spar with a fixed hull rod, two ``Body1Pinned`` outrigger rods carrying
       tethers, and three chains, in waves and current — :doc:`tutorial_bodies`
     - bodies, dynamic
     - ~2 s
   * - ``mixed_body_rods_points.dat``
     - one march over a ``Rigid6`` body, fixed and pinned rods, ``Free`` points on a chain, taut
       legs and a finite-EI cable; a free-decay release — :doc:`tutorial_bodies`
     - mixed, dynamic
     - ~3 s

Line failure (accidental limit state)
-------------------------------------

A ``FAILURE`` row detaches a line from its fairlead mid-run, by time or by tension; the
examples ``README.md`` reports the transient on the remaining lines.

.. list-table::
   :header-rows: 1
   :widths: 36 40 12 12

   * - Deck
     - What it shows
     - Route
     - Run time
   * - ``als_volturnus_line_break_time.dat``
     - the IEA-15MW VolturnUS-S as a free ``Rigid6`` body on three chains in a JONSWAP sea with a
       steady thrust; line 1 breaks at its fairlead at t = 300 s and the platform moves 62 m to a
       two-line equilibrium
     - bodies, dynamic
     - ~30 s
   * - ``als_volturnus_line_break_tension.dat``
     - the same platform; line 1 breaks when its fairlead tension first reaches 3.0 MN
     - bodies, dynamic
     - ~30 s

Dynamic power cables
--------------------

The Lozon et al. (2025) installed lazy-wave cables at three reference sites. CableDyn finds each
touchdown and lazy-wave shape from the geometry alone; there is no initial-shape input.

.. list-table::
   :header-rows: 1
   :widths: 36 40 12 12

   * - Deck
     - What it shows
     - Route
     - Run time
   * - ``lozon_gomex80_power_cable.dat``
     - Gulf of Mexico, 80 m: bare/buoyant/bare lazy wave with a grounded tail —
       :doc:`tutorial_lazywave`
     - Hermite, static
     - < 1 s
   * - ``lozon_gomaine200_power_cable.dat``
     - Gulf of Maine, 200 m
     - Hermite, static
     - < 1 s
   * - ``lozon_humboldt800_power_cable.dat``
     - Humboldt, 800 m
     - Hermite, static
     - < 1 s
   * - ``lozon_gomex80_power_cable_motion.dat``
     - the 80 m cable driven 36 s by a 3 m, 12 s hang-off heave from
       ``data/lozon/gomex80_heave_3m_12s_dt005.txt`` on 64 elements, within 0.5 % of a
       1024-element solution — :doc:`tutorial_motion`
     - Hermite, dynamic
     - < 1 s
   * - ``lazy_wave_vessel_motion.dat``
     - the 80 m cable with a clamped (``Rigid``) hang-off on a vessel in prescribed 6-DOF surge,
       heave and pitch (``vesselMotion``); ``BendMom1N1`` is the hang-off moment —
       :doc:`tutorial_motion`
     - Hermite, dynamic
     - ~4 s
   * - ``lazy_wave_vessel_rao.dat``
     - the same clamped cable on a vessel driven by the illustrative RAO table
       ``data/vessel/sample_rao.txt`` (``vesselRAO``) in a JONSWAP sea that also loads the
       cable — :doc:`tutorial_motion`
     - Hermite, dynamic
     - ~9 s
   * - ``lazy_wave_bend_stiffener.dat``
     - the RAO-driven cable with a 4 m polyurethane bend stiffener (a cylindrical root and a cone,
       ``STIFFENERS``) at its clamped hang-off; ``BendMom1N1`` is the stiffener root moment and the
       curvature channels sample the stiffener and the cable past its tip — :doc:`modeling`
     - Hermite, dynamic
     - ~9 s
   * - ``lazy_wave_buoyancy_modules.dat``
     - the 80 m cable in a 0.5 m/s current with its buoyant stretch built from ten discrete
       buoyancy modules (``ATTACHMENTS`` series ``first:pitch:last``) — :doc:`tutorial_lazywave`
     - Hermite, static
     - < 1 s
   * - ``lazy_wave_buoyancy_smeared.dat``
     - the same cable with the stretch smeared as one ``EQUIVALENT BUOYANCY`` section, for
       comparison with the modules
     - Hermite, static
     - < 1 s
   * - ``lazy_wave_modes.dat``
     - the 10 lowest natural periods and mode shapes (``nModes``) of the 80 m cable on its
       1024-element mesh — :doc:`tutorial_lazywave`
     - Hermite, modal
     - ~1 s
   * - ``torsion_lazy_wave_hangoff_twist.dat``
     - the 80 m cable with an illustrative ``GJ`` of 50 kN·m², clamped and restrained in torsion
       at both ends, twisted two turns at the hang-off over 60 s by the ``motionFile`` roll column
       (``data/torsion/hangoff_roll_2turns_60s_dt01.txt``) and held for 30 s. ``Torq1N1`` reaches
       3.54 kN·m and ``Twist1`` 690°: the cable takes up 30° of the 720° by writhing out of its
       plane (``L1N58py``, 3.3 m). The range graph carries the torque and twist envelopes. See
       :ref:`theory-torsion`
     - Hermite, dynamic
     - ~2 s
   * - ``torsion_free_end_armoured_cable.dat``
     - the 80 m cable with an illustrative torque–tension coupling (``GJ|K|Bt``), restrained in
       torsion at the hang-off and free to twist at the anchor: the stretch twists the line
       (``Twist1`` −5.6°), and under the 3 m hang-off heave the twist oscillates through torsional
       waves whose torque the hang-off takes (``Torq1N1``) — :ref:`theory-torsion`
     - Hermite, dynamic
     - ~2 s
   * - ``lazy_wave_modules_stiffener.dat``
     - the 80 m cable with ten discrete buoyancy modules (``ATTACHMENTS``) and a 4 m bend
       stiffener (``STIFFENERS``) at its clamped hang-off on the vessel of
       ``lazy_wave_vessel_motion.dat``, in a 0.3 m/s current; the range graph (``Outputs`` flag
       ``r``) of the finite-EI line
     - Hermite, dynamic
     - ~2 s
   * - ``shared_cable_two_floaters.dat``
     - a 360 m array cable hung between the clamped hang-offs of two floaters 300 m apart, both
       ends moving (two ``Coupled`` points, ``data/shared/floaters_surge_heave_12s_dt0025.txt``):
       the span opens and closes by 4 m
     - Hermite, dynamic
     - ~1 s

The first three set ``TMax = 0`` (static only). The motion file holds absolute position,
velocity, and acceleration at every ``dtM`` and is regenerated by
``data/lozon/generate_gomex80_heave.py``.

OpenFAST coupling
-----------------

These files run CableDyn inside OpenFAST, maintained by NLR (National Laboratory of the Rockies,
formerly NREL).

.. list-table::
   :header-rows: 1
   :widths: 44 56

   * - File
     - What it is
   * - ``openfast/IEA-15-UMaine_CompMooring5_CableDyn.fst``
     - IEA-15MW VolturnUS-S template with ``CompMooring = 5`` — :doc:`tutorial_openfast`
   * - ``openfast/CableDyn_UMaine.dat``
     - its CableDyn ``MooringFile``: three R4 chains, ``dtM = DT``
   * - ``openfast/IEA-15-UMaine_CompMooring3_MoorDyn.fst``
     - the same model with stock MoorDyn (``CompMooring = 3``)
   * - ``openfast/MoorDyn_UMaine.dat``
     - its stock MoorDyn v2 deck (also readable by CableDyn, see :doc:`migrating`)
   * - ``openfast/CableDyn_UMaine_rod.dat``, ``openfast/MoorDyn_UMaine_rod.dat``
     - lines 1 and 2 hung from the ends of a ``Coupled`` 100 m pontoon rod between their
       fairleads, with its stock MoorDyn twin (the coupled-rod comparison)
   * - ``openfast/IEA-15-UMaine_CompMooring5_CableDyn_LineFailure.fst``,
       ``openfast/CableDyn_UMaine_line_failure.dat``
     - the ``CompMooring = 5`` model with a ``FAILURE`` row: line 1 breaks at its fairlead at
       t = 100 s of a 400 s run (accidental limit state)
   * - ``openfast/README.md``
     - file roles and where to obtain the turbine sub-models
   * - ``iea15mw_umaine_mixed_cabledyn.dat``
     - three chains plus a finite-EI lazy-wave power cable with a grounded tail (mixed route).
       As a ``MooringFile`` it runs coupled; with ``CableDyn_driver.exe`` it writes the held-end
       statics (``TMax = 0``, < 1 s) or marches the held system when ``TMax > 0``
   * - ``iea15mw_umaine_openfast_cabledyn.dat``
     - an OpenFAST-only ``MooringFile`` for the same platform. Its fairleads are caller-driven
       and its water depth is host-owned, so ``CableDyn_driver.exe`` solves it with held
       fairleads and no seabed, which is not the moored configuration, and warns that the
       lines hang below their anchors; use ``spread_3line_chain.dat`` for the standalone
       equivalent

The turbine model itself (ElastoDyn, SeaState, HydroDyn, WAMIT data) comes from OpenFAST's
``r-test``; :doc:`tutorial_openfast` gives the exact steps.

Auxiliary data
--------------

These files are inputs referenced by decks, not decks:

* ``data/syrope/syrope_settings.dat`` — Syrope settings (names the OWC table, curve type, and
  shape parameters); ``data/syrope/syrope_owc.dat`` — the original working-curve table. Paths are
  relative to the referring file; copy all three Syrope files together.
* ``data/lozon/gomex80_heave_3m_12s_dt005.txt`` — the prescribed hang-off motion;
  ``data/lozon/generate_gomex80_heave.py`` — the script that writes it.
* ``data/vessel/vessel_surge_heave_pitch_12s_dt005.txt`` — the 6-DOF vessel record of
  ``lazy_wave_vessel_motion.dat``; ``data/vessel/generate_vessel_motion.py`` writes it;
  ``data/vessel/sample_rao.txt`` — the illustrative RAO table of ``lazy_wave_vessel_rao.dat``.
* ``data/range_tdp/chain_surge_5m_30s_dt005.txt`` — the fairlead surge of ``chain_range_tdp.dat``;
  ``data/range_tdp/generate_chain_surge.py`` writes it.
* ``data/torsion/hangoff_roll_2turns_60s_dt01.txt`` — the held hang-off with its roll column of
  ``torsion_lazy_wave_hangoff_twist.dat``; ``data/torsion/generate_hangoff_roll.py`` writes it.
* ``moordynC_wavekin/wave_frequencies.txt`` and ``moordynC_wavekin/current_profile.txt`` — the
  MoorDyn-C kinematics files, read from the folder of the deck beside them.
* ``moordynC_currents/wave_elevation.txt``, ``current_profile_dynamic.txt`` and
  ``current_profile_4d.txt`` — the MoorDyn-C files of the two decks in that folder;
  ``moordynC_currents/generate_kinematics.py`` writes them.
* ``data/shared/floaters_surge_heave_12s_dt0025.txt`` — the hang-off motions of both ends of
  ``shared_cable_two_floaters.dat``; ``data/shared/generate_floater_motion.py`` writes it.
* ``data/bathymetry/sloped_seabed.txt`` — the ``x y depth`` grid of
  ``chain_sloped_bathymetry_friction.dat``.
* ``plot_range_envelope.py`` — plots the tension envelope of a range-graph file.
