<!-- SPDX-License-Identifier: Apache-2.0 -->

# Changelog

All notable changes to CableDyn are recorded in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.2] - 2026-11-09

### Added

- OPTION `axialDampingRatio` (`segment` or `mode1`): under `mode1` a negative `BA` is the damping
  ratio of the line's first axial mode, the same on any mesh (BA = 2 zeta EA / omega_1, omega_1
  from the line's sections). `segment`, MoorDyn's damping ratio per segment, stays the default.
- An initialisation note for every line with a negative `BA` per segment: the damping ratio this
  gives the line's first axial mode on its mesh, about zeta pi/(2N) on N elements.
- `VIVphaseSeed zero` starts every VIV phase at zero, the start of MoorDyn-F in OpenFAST v5.0.0,
  which does not carry its phase seed into its state; the default `spread` keeps MoorDyn-C's
  `2 pi i/N`.
- Initialisation notes for a modal analysis about an unstable static state (the line and the
  number of its modes with omega^2 < 0) and for a `Point3` buoy that starts off balance under
  the default `bodyIC static` (the unbalanced force and the distance to the buoy's static
  balance as a `Free` point). The static solve does not place a `Point3` buoy: a 112 t, 259 m^3
  buoy started with 1.5 MN unbalanced and surfaced in 2 s without a word.
- Example decks for cross-flow VIV, the mode-1 axial damping ratio, MoorDyn-C `WaveKin 3` and
  `Currents 2`/`5` files, viscoelastic and Syrope composite legs on an RAO-driven floater, a
  cable shared by two moving floaters, buoyancy modules under a bend stiffener, a sloping
  bathymetry with as-laid friction, torsion with one end free, and the modes of a composite
  line; every shipped deck, those of the `moordynC_*` folders included, now runs in CTest and in
  the example fallback scan.
- Regression tests through the deck driver: one linear sea as deck wave rows, `WaveKin 7` and
  `WaveKin 3` gives one response; the modes of a two-section string match its closed-form
  frequency equation at second order in the element length; a cylindrical bend stiffener
  matches the equivalent cable-and-sleeve section, and a clamped cable's root moment is
  `a sqrt(EI T)`.

### Changed

- The modal analysis (`nModes`) of a long line is many times faster. Its lowest eigenvalues come
  from a shift-invert block Lanczos iteration on the banded Cholesky factor of the stiffness,
  their count certified by the inertia of `K - σM`, instead of the band reduction (LAPACK
  `dsbgvx`), whose time grew with the square of the line length. The 10 modes of a 1024-element
  finite-EI line take 0.14 s instead of 3.7 s; on a 4000-element line 10 modes take 0.5 s
  instead of 55 s and 50 modes 2.9 s instead of 59 s (GNU build, one thread). Shapes and
  frequencies still come from inverse iteration and the quadruple-precision Rayleigh quotient:
  on the same matrices the frequencies agree to 1e-15, and `lazy_wave_modes.dat` writes the same
  frequencies and shapes within 2e-8 of a unit displacement. Short lines, an indefinite or
  singular stiffness, and an iteration that is not certified keep the band reduction. A mode
  whose largest components are equally large (the mirrored nodes of a symmetric line) takes its
  sign from the first of them in node order instead of from round-off.
- The finite-EI dynamic step does less redundant work: band operators are swept over their stored
  rows only, the step mass is summed in one pass, the rigid-end transport tangent and the rigid
  end-connection moment are formed from the rows they need, the element kernels form their
  Gauss-point factors once, and each element kernel is evaluated once for its load and its
  tangent where a tangent follows at the same state. Results are bit-identical; the finite-EI
  example decks run 2-15 % faster.
- The coupled loads of an `EI = 0` line attached at its end nodes are formed from those nodes'
  rows only, and a system stepped on one thread runs its per-line loops without entering an
  OpenMP region. Results are bit-identical; a moored Rigid6 body on three chains runs about 7 %
  faster.
- With `modified_newton True`, a finite-EI cable in the monolithic step of the multibody march
  keeps full Newton: it is stepped again from the same start at every coupling iteration, where
  reuse cost more than it saved (`mixed_body_rods_points.dat` with the option: 7.0 s, now 5.6 s).
  The documented speed trade-off of the option is measured again on the examples.
- A finite-EI static solve whose equilibrium is in axial compression (with `tensile_safety True`)
  stops refining once two passes leave the compression where it was (to 0.1 %), instead of
  splitting elements up to the element budget: a power cable given twice its length fails in 6 s
  instead of 76 s, with the same compression named. Decks that refinement does resolve are
  unchanged (the static matrix and every example give identical outputs).
- The standalone driver runs a line combining `EI = 0` and finite-EI sections as one finite-EI
  cable, as the C API and OpenFAST do, whatever the other lines of the deck; it refused such a
  line unless the deck also had a separate `EI = 0` line. Its results match the C API's stepping
  of the same deck to the digits of the output file.
- The L5 wall-clock records (`validation/performance` and the L5 rows of `VALIDATION.md`) are
  measured again on one host, with the release driver and a GNU build. The new
  `validation/scripts/performance_records.py` builds the lazy-wave span, one-hour mooring and
  tension-only chain models for CableDyn, OrcaFlex, MoorDyn-F and MoorDyn-C, checks each against
  its reference response (the records are written only inside it), times them and writes the
  records.

### Fixed

- Finite-EI node tension, curvature and bend moment next to the touchdown point: the floor
  reaction of the first grounded node was spread over its grounded half-element alone, wherever
  the touchdown point lay in the touchdown element. The local tension error there fell only at
  the first order with the element length (4.3, 1.9, 1.0 N at 1.6, 0.8, 0.4 m elements on a
  lazy-wave cable at 270 N) and the node outputs stepped as each node grounded or lifted off.
  The touchdown element now takes the reaction of its grounded stretch, from the grounded node
  to the touchdown point located from the two nodes' clearances: the error falls at the second
  order (2.1, 0.7, 0.2 N) and the outputs vary continuously.
- The tangent outputs of a finite-EI line take the line's tangent, the node's Hermite tangent
  DOF, instead of a difference of node positions. At an end clamped by an `END CONNECTIONS`
  `Rigid` row they now give the direction the clamp holds: a cable clamped 15 deg off the
  vertical read 163.8 deg for a 165 deg clamp, and up to 14 deg off where the line bends within
  its first element.
- The VIV lift of a line written fairlead first pointed against MoorDyn's: the node tangent ran
  from End B to End A, which is MoorDyn's model started from the phases plus pi. The lift and the
  `V` line files now match MoorDyn's on either deck order. Where two lock-in branches coexist the
  start can select the other one.
- A negative `BA` of an `EI = 0` line of several sections is resolved with the length, `EA` and
  mass of its own element. It took those of the element at the mirrored position from the other
  end, so the line types of an asymmetric composite line exchanged their axial damping.
- Finite-EI dynamic step at rest under a large axial damping coefficient: the round-off floor of
  the step's force scale left out the axial damping, whose strain rate is formed from the Newmark
  velocity and carries gamma/(beta dtM) times the rounding of the coordinates. A held line damped
  near its first axial mode (`BA` = 2 zeta EA/omega_1, as `mode1 axialDampingRatio` gives, or a
  direct `BA` of that size) stalled at a few times the tolerance and stopped (3 of 30 runs of a
  400 m wire held at rest, `BA` 5e7 to 8e8 N s, `dtM` 0.002 to 0.01 s). The floor now includes
  `BA` gamma/(beta dtM), as the twist floor includes its damping.
- Finite-EI statics on a strongly graded deck mesh: when the route fails on the deck mesh and on
  its uniform refinement, it is repeated on the deck mesh with each element longer than half the
  bending length split to that length. A lazy wave meshed 4 m / 0.9 m / 10 m (sag bend, buoyant
  section, touchdown) failed in an oblique or cross current with "already in axial compression
  without the current", and now agrees with the same deck on 2 m elements.
- The static solve of a finite-EI line in a current named an element-mean axial compression on
  elements longer than half the bending length as a limit of the current (the friction holding
  the grounded run, or the run pushed along the seabed), and on that diagnosis skipped the
  mesh-sequenced route. On such elements the axial force of a stiff line oscillates, so the
  compression names the mesh: the message now says so and how to refine, and the other routes
  still run (a lazy wave on a graded mesh in a 0.2 m/s cross current now solves).
- Static solve of discrete `ATTACHMENTS` in a current across the line's vertical plane: the
  smeared start now carries the attachments' drag as well as their weight, and the attachment
  polish moves both to the nodes. It applied the whole attachment drag to a state without it, and
  on a frictional seabed its Newton solves diverged, so the discrete state was reached only
  through the fallback solves or not at all (a lazy wave with 25 modules in 0.3 m/s across its
  plane). A current along the plane takes the former path.
- Finite-EI statics with discrete `ATTACHMENTS`: a solve of the attachment polish that stalled on
  a residual floor above the tight static tolerance (a few times 1e-8, on a fine or locally
  refined mesh) went on to the fallbacks and halved its load steps until the static start
  failed, although the line's own static solve accepts such a floor at the coupled static
  tolerance 1e-6. A clamped cable arriving at its anchor in a tight bend with one clump failed
  for every clump mass and position tried. The polish now repeats a stalled solve at 1e-6 from
  the same state before its fallbacks, and the run notes the residual of the discrete
  equilibrium when it lies above the tight tolerance.
- Finite-EI statics in a current with a `Rigid` end connection: when the drag load steps stall at
  a limit point, the pseudo-arclength continuation that follows the path around it was skipped
  for a line with a `Rigid` end, so the statics failed where the same line with a stiff
  rotational spring solved (a 3 km cable clamped at its fairlead in 1.1 m/s, folded back past
  its anchor). The continuation now takes a `Rigid` end in the basis of its direction, with the
  transverse components of the end tangent held, as the static solve does.
- Finite-EI statics that restart at full stiffness no longer depend on the line's azimuth. When
  the first stage of the stiffness continuation fails (a clamped end on a mesh too coarse for
  its boundary layer), the energy descent from the seed was cut at a fixed count (1600
  iterations at the default allowance). On a 3.8 km clamped lazy wave that descent takes 1171
  to 1661 iterations depending on the last digits of the input, so turning the deck about the
  vertical failed the statics at 328.3 and 329 deg and solved them elsewhere. Past its allowance
  the descent now runs on while the norm of its residual keeps halving within an allowance, to
  one and a half allowances. The lazy wave solves at all 28 azimuths tried, with the same
  tensions, and the static states of the decks that solved before are unchanged.
- Finite-EI statics: the note "static residual floor above the dynamic tolerance" could report a
  residual below that tolerance (accepted at 6.91e-9 against 1e-8): a polish repeated at the
  coupled static tolerance after the tight one failed can still end below the tight tolerance.
  The note is now printed only when the residual reached lies above it.
- `staticsFriction asLaid` on a bathymetry: the friction reference of a finite-EI line sinks each
  node under the normal load the solver applies at its laid position, with the buoyancy of the
  dry part of a section laid within its radius of the surface (a seabed shallower than the
  cable radius) and the dry weight of an attachment above it. It took the submerged weights, so
  such a run rested off its laid path across a slope (0.8 mm on a 0.5 m cable 0.1 m deep),
  held there by a spurious friction force. The dry-part load is solved by Newton's method with
  halved steps, which converge where full steps cycle between a wholly dry and a wholly wet node
  (a net-buoyant cable on a seabed shallower than its radius).
- `EI = 0` statics: a residual inside the round-off floor of the nodal forces but above the
  relative tolerance was converged only when it stayed flat. Iterates that alternated between two
  values there ran every stage out of iterations, so a line could fail to find its equilibrium or
  find it depending on the last digits of its coordinates (13 of 32 small translations of a
  suspended three-section line in a current failed, as did translated copies of point systems). A
  residual inside the floor that sets no new minimum over three iterations is now converged.
- Static balance of `Connect`/`Free` points, bodies and rods: a step that raised the force
  residual was accepted when the Newton step from it was half the current one. Near the
  slack/taut kink of a line the Newton step can grow again, and the steps then cycled (a
  Connect point between a near-vertical heavy chain and two wires on the seabed: 4e4 N to 6e6 N
  and back, every four steps) until the solve failed from every seed, although an independent
  catenary solution gives the balance. Such a step is now accepted only when the new Newton step
  is also half the shortest of the solve so far.
- Syrope lines of one section: the static start took one secant EA from the working curve at
  the line's mean strain, so where the tension varies along the rope (its weight on a long or
  inclined taut line) the elements away from the mean started off their curve and their slow
  strains settled the line at rest (a 991 m rope moved its fairlead tension by 3.4e-4 in 1 s;
  63 of 125 random Syrope lines drifted by more than 1e-5). Every Syrope element now takes its
  own secant at its own tension, as on a composite line: the same lines start at rest to 1e-6.
  An update that reverses without contracting takes a secant step on the line's response, so a
  strongly concave working curve converges instead of cycling.
- A bend stiffener over an element that two STIFFENERS rows share no longer gives it a negative
  EI: their covered lengths can sum past the element length by round-off, which a soft cable's EI
  (1e-12 N m^2 and below) turned into a negative compliance, and the static solve then failed
  with an internal message. STIFFENERS `RootOD` and `TipOD` are now at most 1e3 m, the bound of a
  line type's `Diam`, in the solver and the Python deck validator.
- C API and Python on a deck of `EI = 0` lines in a current that varies in space (a `profile`
  current, a `Currents 1` table or a steady grid): the lines took the current at the nodes of
  their straight seeds, while the static solve sampled it at its own nodes. The start was not
  the static state's (end loads off by up to 1.7 % of a component), and a line held at rest
  drifted (0.4 % of its fairlead tension and 12 % of a force component in 2 s). The field is
  now sampled at the static nodes and at the step-start nodes before every step, as the
  standalone driver samples it, and a step that does not commit puts back the field it
  replaced; a uniform current is unchanged.
- A time step below 1e-100 s is refused by name (`dtM`, `CableDyn_Step` and the OpenFAST glue
  `DT`): the time integration divides by its square, which overflowed near 1e-155 s inside the
  line solve ("banded model load q/v must be finite", "non-finite Jacobian"). The Python deck
  validator applies the `dtM` bound.
- A `waves` or `current` row overridden by a later one no longer leaves a bound behind: an Airy
  or stream `waves` row after a JONSWAP row was refused for that row's gamma above 1e3, and a
  `profile` current row after a `uniform` one for that row's velocity above 1e3 m/s. The Python
  deck validator now applies the magnitude bounds of these rows (wave height and period, JONSWAP
  gamma, current speed and depth) to the row in effect only, as the solver does, instead of
  refusing a deck for an out-of-range row a later row overrides.
- A finite-EI line type with `MassDenInAir` of zero or less is refused by name
  (`MassDenInAir must be > 0 on a finite-EI line`) instead of failing inside the model build.
- The Python deck validator refuses, as the solver does, `TDP<L>` channels on a standalone deck
  without a seabed, `Point<P>p` channels of a Coupled/Vessel point that only finite-EI lines reach
  on the aggregate and of any point on a standalone multibody march without an `EI = 0` line,
  and a finite-EI line type without mass.
- Python: `CableDyn.channel` and `channels` refuse a token holding a NUL character, which the
  library read only up to the NUL (`"FairTen1\0x"` returned `FairTen1`).
- Documentation: the length the Morison drag is taken over on each path (unstretched on `EI = 0`
  lines, the deformed centreline on finite-EI lines), and how an independent check of the static
  force balance in a current must integrate it. The end reactions of a finite-EI cable at rest
  in a current, pinned or clamped, balance its weight and drag to 2e-8 of the end force; a test
  checks it. The signed frequency of a mode with omega^2 < 0 (`Omega` = -sqrt(|omega^2|),
  `Frequency` = `Omega`/2 pi, period 0) is documented, and a troubleshooting entry covers a long
  line that solves at one orientation and not at another.

### Upgrading

- On finite-EI lines `L<L>N<J>Dec` and `L<L>N<J>Azi`, `FairDecl`/`AnchDecl`, `FairIncl`/`AnchIncl`
  and `FairAngle`/`AnchAngle`, the `Declination`, `Inclination` and `Azimuth` columns of
  `.static.out`, the `Declination` envelope of the range graph and the `line tangent` of the
  initialisation reports (driver, mixed route, C API notes and OpenFAST) change: by up to 3.1 deg
  at the clamped end of `buoy_clamped_cable.dat`, 1.8 deg in the static profile of
  `lozon_gomex80_power_cable_motion.dat` (1.4 deg in `iea15mw_umaine_mixed_cabledyn.dat`, 0.5 deg
  in `torsion_lazy_wave_hangoff_twist.dat`) and 0.6 deg in the `FairIncl1` history of
  `lazy_wave_vessel_motion.dat`, and by 0.2 deg or less on the other finite-EI examples.
  Positions, forces, tensions, curvatures and every `EI = 0` line are unchanged.
- The VIV lift of a line written fairlead first changes direction (see Fixed); a deck run with VIV
  gives MoorDyn's response on either deck order.
- The static tensions of a one-section Syrope line move by up to 3e-4 (relative); the Syrope
  example is unchanged.
- On the C API and Python point route, a deck in a current that varies in space starts from the
  driver's static state and stays at rest when held.

## [0.4.1] - 2026-11-08

### Added

- In-process stepping in moving water (ABI 1.4). On decks with finite-EI lines, bodies or rods
  the C API and Python march a steady deck current (`current`, WaterKin `CurrentMod 1`, MoorDyn-C
  `Currents 1`), in the static start and in every step. A host can instead supply the fluid at
  every line node: `CableDyn_SetHostFluid`, `CableDyn_NFluidNodes`,
  `CableDyn_GetFluidNodePositions` and `CableDyn_UpdateFluidFields`, in Python `set_host_fluid`,
  `n_fluid_nodes`, `fluid_node_positions` and `update_fluid_fields`. The field is sampled and held
  as in the standalone march and in OpenFAST; in current and waves a stepped cable matches the
  standalone driver to the digits of its output.
- `Line.section_curvature()` and the C API quantity `CD_C_LINE_SECTION_CURVATURE` return `CurvX`
  and `CurvY` at every node of a finite-EI line in one evaluation.
- `CableDyn_GetInitNotes` in the C API and `CableDyn.init_notes` in Python: the notes of the last
  deck initialisation on the point route and the aggregate, for a host that does not read the
  standard streams.
- Python: `CableDyn.init_line`, `init_lines` and `calc_output_derivatives` bind the raw-array line
  calls and the load Jacobians of the C API.
- Python: `read_output` reads both tables of `<root>.modes.out` into `NaturalModes` and
  `ModeShapes`; `DriverResult` gains `modes_output` and `read_modes()`.
- Range graphs in coupled OpenFAST runs: the `LINES` `Outputs` flag `r` and `RangeStart` now write
  `<RootName>.CD.Line<L>.range.out` in a single-turbine run, from the committed `dtM` steps of
  `.CD.out`, once per step when OpenFAST retries a step, and across a checkpoint restart. A
  turbine's own instance in FAST.Farm writes `<RootName>.T<n>.CD.Line<L>.range.out`. A FAST.Farm
  shared mooring and the C API reject the flag by name.
- An OpenFAST initialisation note when the deepest interval of the SeaState depth grid exceeds 5 %
  of the depth and a line lies in it: the field is linear there, unlike a deck depth table.
- An initialisation note names the lines that a current can move along a seabed without friction.
- `WaveKin 7`: each row of `wave_frequencies.txt` may carry its own `beta`, as MoorDyn-C reads it,
  so that a component file can describe a short-crested sea; vessel RAOs take each row's heading.
- `WaveRefX` and `WaveRefY` options: the point that an elevation record or a component file
  (`WaterKin WaveKinMod 1`, `WaveKin 3` and `7`) refers to. An extension of CableDyn; default 0, 0.
- CI: a Linux job runs the full test suite on the Prescott OpenBLAS kernel and fails on a fallback
  note in any shipped example deck.

### Changed

- A standalone deck with `TMax 0` no longer needs `dtM`: the static check marches no step, so it
  runs without one on every standalone route and writes the same `t = 0` row as with one. A
  mixed deck that marches no step no longer prints the `dtM` advisory.
- Wave kinematics cost half to a fifth as much, depending on the compiler: on a 298-node line
  in a 4,200 s elevation record of 2,400 components the sum falls from 6.0 to 3.0 ms per step
  in the release build and from 18 to 3.6 ms in a GNU AVX2 build. Results change at round-off.
- `CableDyn_GetLineValues` evaluates the position, velocity, acceleration, tension, curvature,
  bend moment, declination and azimuth of a line in one pass, without a text token per node. The
  values are unchanged bit for bit. A read of `EI = 0` tension was O(n²) and is now linear.
- A coupled run restarts from a checkpoint at any glue step: `ChkptTime` need not be a multiple of
  `dtM`, and the restarted run matches the uninterrupted one bit for bit.
- Range graphs are written when the host reports a completed run, so also at FAST.Farm's last
  whole `DT_Low` and after `CalcSteady`. An earlier run's range graphs are removed as soon as the
  deck is parsed, and a run that stops on an error writes none.
- The Python deck validator reads the files a deck names (WaterKin, the MoorDyn-C kinematics
  files, motion and vessel records, the RAO table, bathymetry, Syrope) and refuses what the solver
  refuses.
- A direction bin below the smallest normal weight holds no energy: its components are exactly
  zero, and a vessel RAO table needs no heading for it.
- The C API refuses the flag `r` on `EI = 0` decks too, which it accepted without writing a file.

### Fixed

- Nodal curvature under a tapered bend stiffener: a node took the stiffness of the softer
  neighbouring element, which steps at every node of a taper, and so overstated the curvature
  by about `h |EI'| / (2 EI)`. It now takes the stiffness `EI(s)` at the node, and the softer
  side only at a real step of the section (the bare tip, stiffener rows that do not match, two
  line types).
- Element curvature under a tapered bend stiffener: the peaks of `.elements.out` and the node
  values of `OutputRecovery element` read the element's interpolation, which bends under one
  stiffness per element. Against the section its curvature is off by the same `h |EI'| / (2 EI)`,
  high where the curvature falls toward the tip and low where it rises. On an element with a
  sleeve they now report the section: the moment over `EI(s)`.
- Curvature and bend moment of a stretched finite-EI line: the node outputs read the conjugate of
  the tangent as the moment, which put `Curv` 2 ε and `BendMom` ε below their definitions.
  `Curv` is now the geometric curvature of the stretched line and `BendMom` the moment that
  balances the forces, `EI κ / (1 + ε)`.
- An `EI = 0` line whose deck chord heads within 45 degrees of +X reported its azimuth in [0, 360)
  instead of (-180, 180] outside the standalone `EI = 0` route: in the C API and Python, on the
  standalone mixed and multibody routes, and in OpenFAST. Its `L<L>N<J>Azi` channels, the
  `Azimuth` column of the static profile and the azimuth of the initialisation summary now follow
  the documented range on every route.
- A solver step retry in OpenFAST works at any `dtM/DT` and matches an unretried step exactly,
  including across a restart; it rebuilt the model at `dtM = DT` and stopped at `dtM > DT`.
- `CalcSteady` with several operating points no longer stops at the second, works at `dtM` larger
  than `DT`, and `.CD.out` and the range graphs run to the end of its run. `-VTKLin` works at `dtM`
  larger than `DT`. Linearisation after `CalcSteady` or after a restart keeps its line states.
- A restart before the first commit keeps a body or rod at its start, and a restart no longer
  rewrites `.CD.static.out`.
- Every initialisation note of a coupled line reaches the console; long lists were cut or dropped.
- The OpenFAST module driver runs a rotating motion in a single-precision build.
- A range-graph file that cannot be written completely is removed instead of left behind.
- A mean level in a MoorDyn-C kinematics file, a non-zero `omega = 0` row of `WaveKin 7` or the
  mean of a `WaveKin 3` record, is added to the elevation alone, as MoorDyn-C does: the wave
  numbers stay those of `WtrDpth` and the stretching maps the water under the total elevation.
  CableDyn took the wave numbers at `WtrDpth` plus the level. With a 0.8 m level in 50 m of water
  and six components in six directions, `WaveKin 7` now matches MoorDyn-C v2.7.2 to 1e-8 instead
  of 7.7e-3 m in elevation and 1 % in velocity. The mean of a WaterKin `WaveKinMod 1` record still
  raises the still-water level; MoorDyn-F drops it.
- The C API messages of `CableDyn_UpdatePointFluidFields` and `CableDyn_CalcOutputDerivatives` on
  the coupled aggregate name its real scope: decks with finite-EI lines, bodies or rods.

### Upgrading

- `Curv`, `CurvX`, `CurvY`, `BendMom` and `StfMom`, and the `Curvature` and `BendMoment` of the
  static profile and the range graphs, change at nodes inside a bend stiffener. Curvature and
  `BendMom` fall by that first-order error, on `lazy_wave_bend_stiffener.dat` by about 5 % on
  0.2 m elements, 4 % on 0.15 m, 2 % on 0.1 m and 0.7 % on 0.05 m; `StfMom` rises by the same
  moment, so the two still add up to the section moment. A line end on a conical root
  changes likewise, and a step between rows on a taper now compares the two stiffnesses at the
  node. Positions, forces, the section moment and every node outside a stiffener are unchanged.
- `PeakCurvature`, `BendMomentAtPeak` and `PeakXi` of `.elements.out`, so `bend_check` and
  `element_range_graph` on that table, change on elements with a stiffener sleeve, and so do
  `Curv`, `CurvX` and `CurvY` under `OutputRecovery element` at their nodes, where they now equal
  the default recovery. The peaks fall by 1.6 / 3.1 / 5.8 % on 0.05 / 0.1 / 0.2 m elements of a
  hang-off whose curvature falls toward the tip, and rise by up to 4.4 % on the 0.15 m elements of
  `lazy_wave_bend_stiffener.dat`, whose curvature rises. Elements without a sleeve are unchanged,
  and `CD_HermiteCable_Dyn_Curvature_Exact` stays the geometric trace.
- `Curv`, `CurvX`, `CurvY`, `BendMom` and `StfMom`, and the `Curvature` and `BendMoment` of the
  static profile and the range graphs, rise on every finite-EI line: curvature by twice the axial
  strain, the moments by the strain, at most 0.024 % and 0.012 % on the examples. `BendMom` equals
  `EI × Curv` only to within the strain. Tension, positions and forces are unchanged, and so are
  `OutputRecovery element` values on elements without a stiffener sleeve.
- Azimuth values of the `EI = 0` lines named above read 360 degrees lower on those routes.
- On a `WaveKin 3` or `WaveKin 7` deck whose mean level is not zero, the elevation away from the
  origin, the fluid velocity and acceleration, and so the loads and every output, change by the
  order of the level over the depth: up to 1 % in velocity at 0.8 m in 50 m. A deck with no mean
  level is unchanged bit for bit.
- OpenFAST checkpoints change format: they carry the range graphs and the input of the last
  commit, so a checkpoint written by an earlier CableDyn cannot be restarted with this one.

## [0.4.0] - 2026-11-04

### Added

- Full torsion of finite-EI lines: in the dynamics a twist angle at every node, with the polar
  inertia `Irn` and torsional damping (`GJ|K|Bt`), so the torque varies along the line and
  travels as a torsional wave; the statics stay condensed. Lines restrained at one end only
  (the other free to twist), lines hanging from a `Fixed` rod end (I-tube, J-tube), `CONTROL`,
  `ATTACHMENTS` and modal analysis all take torsion. Torsional modes match the continuum within
  the lumped-inertia error (2.6e-4 on the first).
- Torque–tension coupling of armoured cables and wire ropes (`GJ|K`: `T = EA ε + K τ`,
  `M = GJ τ + K ε`) in statics, dynamics, linearisation and the tensile audits; `GJ|0` is the
  uncoupled cable bit for bit.
- OpenFAST linearisation with the line dynamics, as MoorDyn-F's: interior node positions and
  velocities of `EI = 0` lines, the free degrees of freedom of finite-EI cables, and the twist
  angles of lines restrained in torsion. On the UMaine chains the reduced stiffness matches
  MoorDyn-F's to 0.1 % and the lowest nine line-mode frequencies to 0.3 %. Replaces the
  quasi-static linearisation without states. A single-precision OpenFAST (the release
  `openfast.exe`) linearises from CableDyn's double-precision loads, as a double-precision one.
- Section-frame curvature channels `CurvX<L>N<J>`/`CurvY<L>N<J>` on finite-EI lines, for the
  fatigue of an armour wire or conductor at a fixed point of the section; the axes follow the
  twist.
- Cross-flow VIV (the Thorsen et al. model of MoorDyn v2, LINE TYPES `Cl`, `dF`, `cF`) on
  `EI = 0` lines and, as a distributed lift, on finite-EI cables, standalone and on the coupled
  routes, with the LINES output flag `V`. Lock-in follows MoorDyn-F to two to three digits.
- Bend stiffeners (`STIFFENERS`): a tapered linear-elastic sleeve over a finite-EI line end;
  a clamped hang-off follows the planar elastica within 0.2 % of the root moment and OrcaFlex
  11.6d's curvature within 0.8 %. Channels `StfMom`, `FairDefl`/`AnchDefl`.
- Finite-EI lines with two moving ends (a cable shared by two floaters, a FAST.Farm shared
  line) standalone, in OpenFAST, FAST.Farm and the C API; and between two objects on the
  multibody march. The retired Cosserat compatibility route no longer runs them.
- `CoupledPinned`/`VesselPinned` bodies in OpenFAST, as MoorDyn-F's coupled pinned body.
- Active line control (`CONTROL`) of Syrope and viscoelastic segments and of finite-EI cables
  restrained in torsion; composite Syrope lines (chain–polyester–chain).
- Deck currents, prescribed motion, torsion and `TURBINES` rows on the standalone mixed
  `EI = 0` + finite-EI deck; MoorDyn-C `Currents 2` and `5` (time-varying and gridded) on the
  standalone routes, identical to MoorDyn-C v2.7.1 at 739 points and times.
- C API host rotations (ABI 1.3, `CableDyn_InitDeckRotating`, `CableDyn_UpdateRotations`,
  `CableDyn_GetCoupledMoments`), so torsion decks and `Rigid` end connections run there; Python
  `init_deck_rotating`.

### Changed

- Coupled OpenFAST runs start from the equilibrium in SeaState's steady current (`CurrMod 1`)
  instead of the still-water shape.
- A finite-EI cable on the coupled aggregate (mixed decks, OpenFAST, FAST.Farm, the C API) steps
  to the deck's `dynamic_solver` tolerance instead of a fixed 5e-3. The looser step gave wrong
  tensions (a fairlead peak of 4.3e5 N against 1.9e4 N) and a coupled cable that did not damp
  out its residual; the routes now agree to 5e-8 of the peak tension.
- A finite-EI cable pinned to a light moving object is coupled implicitly in the multibody step
  (it was explicit and diverged on light objects).
- Waves: `WvHiCOff` (default 0.5 Hz) cuts an elevation record's components, and the wave
  kinematics vectorise (irregular seas 20 to 33 % faster); `WaveKinMod 1` decks run two to four
  times faster.
- Every Intel ifx build uses the value-safe floating-point model (`/fp:precise`) and automatic
  local variables; ifx results change at round-off.
- Syrope lines take the seabed, Morison loads, current, waves, host fluid and VIV.
- The macOS wheel needs macOS 15 or newer on Apple silicon.
- `TURBINES` decks read and turn finite-EI end frames in each turbine's axes, as FAST.Farm does.
- The CableDyn-enabled `openfast.exe` names itself `OpenFAST-v5.0.0-CableDyn-0.4.0`.
- Speed: on the 51 example decks that 0.3.0 also runs, 0.4.0 is 6 % faster (geometric mean of
  the per-deck times; gfortran, one thread), the wave decks 16 to 30 %. Two decks are slower for
  the fixes above: `mixed_body_rods_points` 52 % (the implicit coupling of a pinned cable) and
  `torsion_lazy_wave_hangoff_twist` 25 % (the nodal twist), and a coupled finite-EI cable step
  costs about 38 % more (the deck tolerance).

### Fixed

- Thread safety of the Intel builds: concurrent handles crashed (shared closure trampolines,
  static local storage), and `CableDyn_Close` paused the OpenMP runtime of the whole process.
- Static starts that failed or depended on round-off: a cable whose End A rests on the seabed,
  a lazy wave restrained in torsion in current (at any pretwist, on every BLAS kernel), torsion
  between two bodies, neutral, weightless and straight lines, pinned and attachment-carrying
  cables on bodies and rods.
- Physics: an `EI = 0` line above the still-water level on a deck without a seabed was modelled
  fully submerged (13 % light in air); lines and attachments above the surface now carry their
  dry weight in the static start; the anchor force on a sloped seabed; the static start in a
  sheared current; modal analysis with end connections and attachments.
- OpenFAST: restarts with a finite-EI cable continue bit for bit; Free and pinned objects start
  from their solved acceleration; channel values below 1e-99 no longer print as asterisks.
- Stack overflows of non-static ifx builds and of `FAST.Farm.exe` built with MinGW, and a crash
  of the ifx run-time on a failing `OPEN` of a long path.
- Messages that said something untrue (SeaState kinematics, body/rod start moves, deck current
  source, torsion twist, FAST.Farm `DT_Mooring`), and a coupled deck mixing bodies and rods now
  says where it runs.
- Output files: the driver refuses an output root whose `.modes.out` or `.Line<N>.V.out` would
  overwrite an input; the Python `overwrite` run keeps aside and restores the `.V.out`,
  `.range.out` and `.modes.out` files as well (an existing one now needs `overwrite`);
  `read_output` reads a `.V.out` lift file; a study refuses a case name such as
  `base.Line1.V`, `base.Line1.range` or `base.modes` beside a case `base`; renaming a line in
  `DeckModel` carries its `CurvX`/`CurvY` channels.
- Python deck validation accepts VIV on an EI = 0 line without a seabed (for example in a
  MoorDyn-C `Currents` profile), as the driver does: the line has its still-water drag either way.

### Upgrading

- OpenFAST checkpoints written by 0.3.0 for decks with finite-EI lines restrained in torsion do
  not reload.
- Decks with torsion need the section's real polar inertia `Irn` (the column was unused).
- Results change beyond round-off on decks with torsion, pinned cables on bodies, coupled
  finite-EI cables (the tolerance), coupled runs in a SeaState current (the static start),
  `TURBINES` decks with rotated turbines, elevation records with components above `WvHiCOff`,
  and `EI = 0` lines above the surface without a seabed.

## [0.3.0] - 2026-10-23

### Added

- `pip install cabledyn`: the package is on PyPI, with wheels for Windows x64 and Linux x86-64
  (processors with AVX2) and macOS on Apple silicon that carry the solver library and the
  standalone driver, so it runs decks without the release executables; other platforms build
  from the source distribution. The release wheels are built and smoke-tested in CI and published
  through PyPI Trusted Publishing.
- OpenFAST with `dtM` larger than `DT`: between CableDyn solves the coupled loads are extrapolated
  from the last two solves instead of held (deck `OPTIONS predictLoads`, default `True`). On the
  IEA-15 MW VolturnUS-S at `dtM = 0.1 s` and `DT = 0.025 s` the platform motions differ from a
  `dtM = DT` run by at most 0.12 % of their standard deviation, against 0.42 % held. Runs at
  `dtM = DT` (the default) do not change.
- Initialisation notes, none of which changes results: a `dtM` that resolves a line's axial
  period in fewer than six steps, with the `dtM` that resolves it; and a finite-EI line whose
  grounded elements lock more seabed friction than 15 % of the touchdown tension, with the
  grounded element length that resolves the tension of the laid part.
- `validation/scripts/openfast_supercycle_ab.py`, which scores coupled runs at a coarser `dtM`
  against `dtM = DT` (`VALIDATION.md`, supercycling verification).
- The run-time profile (`CABLEDYN_PROFILE=1`) splits the line and cable steps into their kernels
  and assembly sections, and the OpenFAST `CalcOutput` and SeaState sampling into their parts.

### Changed

- Speed: the Windows release executables are compiled for processors with AVX2 (x86-64-v3:
  Intel Haswell and AMD Excavator or newer), which makes the driver 13-33 % faster on the
  benchmark decks; on an older processor they stop at start with a message naming the missing
  instructions. In OpenFAST, `CalcOutput` no longer evaluates cable reactions it discarded and
  assembles a fairlead reaction from the elements at its node (a 600 s IEA-15 MW run with a
  248-element power cable: 227 s to 194 s). Results change at round-off only.
- A static solve in a current that seabed friction cannot hold fails closed sooner (22 s to
  17.7 s on a 1000 m lazy wave), with the same message.
- The manual explains the mesh dependence of the negative `BA` (damping ratio) form and of
  node-lumped seabed friction, and the measured trade-off of `modified_newton`, which stays off.

### Fixed

- Finite-EI node tension, curvature and bend moment at touchdown understated the last suspended
  node's tension by half an element's floor reaction (5.3 % on a 10 m lazy-wave mesh); the coarse
  mesh now follows a four times finer one within 3 %. End forces and the solution do not change.
- OpenFAST restarts with `dtM` larger than `DT` now continue the run bit for bit (the checkpoint
  carries the held SeaState fields). A checkpoint written by an earlier CableDyn cannot be
  restarted with this one.
- A restore (`CableDyn_RestoreState`, OpenFAST correction iterations) of a finite-EI cable with
  seabed friction now continues bit for bit like the step it repeats.
- The FAQ and the OpenFAST tutorial gave 0.1 s as the default `dtM` in OpenFAST; it is the glue
  `DT`.

## [0.2.0] - 2026-10-20

### Added

- Seabed friction in the static solve toward the as-laid position (`staticsFriction asLaid`,
  with `layAzimuth` and `asLaidTension`), as in OrcaFlex. The default stays `none`, so existing
  decks run as before. A 700 m chain on a 5° slope that the frictionless statics folds 24 m past
  its anchor now holds where it was laid.
- Active tensioning (`CONTROL`) of finite-EI cables in OpenFAST, alone or in a deck with
  `EI = 0` lines.
- Sub-stepping of tension-only (`EI = 0`) lines through fast segment rotation and slack-to-taut
  snaps, on by default (`ei0_substeps auto|off`, `ei0_substep_angle`, `ei0_substep_max`).
  It brings snap-load peaks at coarse time steps closer to converged runs; `off` restores the
  previous results.
- Torsion of finite-EI lines in coupled OpenFAST (`CompMooring = 5`) and FAST.Farm runs.
- `Pinned` and `CoupledPinned`/`VesselPinned` rods in coupled OpenFAST runs.
- Seabed contact for `Free`/`Connect` points and `Point3` buoys: a heavy clump no longer sinks
  through the seabed.
- Anchor uplift channels `AnchFz<L>`, `AnchFH<L>` and `TDP<L>Grd` for drag-anchor checks.
- C ABI 1 minor extension 2 for hosts that drive `Coupled` points (for example CFD solvers):
  `CableDyn_InitDeckAt`, `CableDyn_SaveState`/`CableDyn_RestoreState` and
  `CableDyn_GetCoupledLayout`, with matching Python methods. Existing functions are unchanged.
- `OutputRecovery equilibrium|element` option and the `CD_HermiteCable_Dyn_Curvature_Exact` and
  `CD_HFMF_Curvature_Exact` functions (see Changed).
- Run-time profile of the standalone driver (`CABLEDYN_PROFILE=1`).
- New diagnostics, none of which changes results:
  - run audit of `EI = 0` lines in the standalone driver: tension spikes, fast segment turns
    and unresolved snaps, and a note for `rhoInf` above 0.95;
  - a note when the static state of a finite-EI line is unstable out of its vertical plane;
  - a note when the static layout of an `EI = 0` line folds back on the seabed, naming the
    cause and the remedy;
  - notes for a line stretched far beyond its elastic range and for a section too coarse for
    its line;
  - a warning when line nodes of a coupled OpenFAST run lie outside the SeaState
    wave-kinematics grid.

### Changed

- Finite-EI node tension, curvature and bend moment (and `.t.out` segment tensions) are now
  recovered from nodal equilibrium. On the lazy-wave example the largest tension error falls from
  1552 N to 60 N on its former 87-element mesh, and oscillations near touchdown on a coarse mesh
  are removed. End tensions and positions are unchanged. `OutputRecovery element` restores the
  previous definitions.
- `EI = 0` lines step with a generalised-α force blend, as finite-EI lines do. Tension spikes of
  lines that go slack are gone: a light cable under 3 m heave reported 4.2 MN where converged
  runs give 0.093 MN. Tension statistics of the shipped examples change by at most 0.23 % (mean)
  and 0.9 % (maximum). `False alpha_force_blend` selects the former scheme.
- Active tensioning of `EI = 0` lines follows MoorDyn-F through length ramps: fairlead tensions
  within 0.13 % instead of up to 6.3 %. A command outside MoorDyn-F's bounds stops the run
  instead of printing a warning, and the command acts on the segment at the host-driven
  (fairlead-side) end, as in MoorDyn-F.
- In OpenFAST, a deck without `dtM` now solves every glue step (`dtM = DT`) instead of about
  every 0.1 s, so the mooring loads reach the platform without delay. A deck `dtM` that is a
  multiple of `DT` still trades this for speed (see Known issues).
- The touchdown point (`TDP<L>`) now moves continuously instead of in steps of one element.
- Finite-EI statics refine the mesh locally instead of as a whole, which cuts solve time (for
  example 10.0 s to 0.33 s on a 462-element lazy wave). Decks that do not refine are unchanged.
- The power cable of `examples/iea15mw_umaine_mixed_cabledyn.dat` is re-meshed from 87 to 248
  elements. Its static fairlead tension changes by 0.2 %.
- Faster runs: directional and multi-train wave kinematics (17 %), finite-EI cables clamped to
  bodies or rods (66 %), and decks of `EI = 0` lines (13 %). Results can differ in the last digit
  with the Intel compiler.
- The OpenFAST linearisation check and the FAST.Farm shared-mooring comparison against MoorDyn
  are extended: per-fairlead stiffness agrees to 0.1 % (0.29 % for the transverse term) and
  shared-mooring tension means to 0.02 %.

### Fixed

- Node output channels of a finite-EI line whose mesh the static solve refined now read the
  deck node named, not the same index on the refined mesh.
- Static solves that failed or gave the wrong answer:
  - creased gridded bathymetry (trenches, valleys) now has a static equilibrium;
  - a finite-EI line over a rough, non-planar bathymetry no longer fails on a few centimetres
    of roughness;
  - a 3D finite-EI solve on a coarse mesh no longer stops with "unstable equilibrium";
  - a finite-EI line with `ATTACHMENTS` in a cross current on a frictional seabed now solves.
- The anchor tension of a finite-EI cable laid on the seabed no longer jumps when the line
  moves out of its plane.
- Explicit sub-stepping of free and pinned rods and Rigid6 bodies now accounts for seabed
  contact, free-surface crossing and decks without lines, and seabed friction of rods and
  bodies is applied implicitly (no more chatter on a frictional bed).
- `modified_newton` on `EI = 0` lines rebuilds the tangent as documented.
- Junction end tangent of a tension-only line step that ends right after a fresh tangent
  evaluation.
- Error messages are no longer truncated, and now name the cause and workaround for neutral
  buoyancy, unsupported couplings and anchors below the seabed.
- The development environment excludes OpenBLAS 0.3.34, which crashed the modal tests on some
  AMD CPUs. Results are unchanged.

### Known issues

- In OpenFAST, a deck `dtM` larger than `DT` holds the loads between CableDyn's steps, so they
  reach the platform about `dtM/2` late. The lag matters for stiff (taut or tension-leg)
  moorings and for tension statistics; check such results at a smaller `dtM`. See the note on
  the manual's OpenFAST page.

## [0.1.1] - 2026-10-09

### Added

- Torsion of finite-EI lines in the standalone driver (condensed, quasi-static, uniform torque):
  `END CONNECTIONS` columns `TorsStiffness NxX NxY NxZ [Pretwist]`, a `motionFile` roll column,
  the torque returned to Rigid6 bodies, channels `Torq<L>N<J>`, `Twist<L>N<J>` and `Twist<L>`,
  range-graph columns, `DeckModel` and channel support in Python, and the example
  `torsion_lazy_wave_hangoff_twist.dat`. Validated in VALIDATION.md (Torsion). Routes outside
  its scope, coupled OpenFAST (NLR) runs included, stop with a named error; results without
  torsion are unchanged.

### Changed

- Python: NumPy arrays in the public functions carry explicit element types, and the package
  type-checks under `mypy --strict` on Python 3.10 and on current NumPy. Tests that need the
  native shared library are skipped with a reason when it has not been built.
- The test suite runs in parallel (`ctest -j`) and holds on hosted CI runners: the catenary
  reference solve converges from a robust start on every platform, and the driver-path tests
  check the case-insensitive spelling of an output root only on Windows.

### Fixed

- The standalone driver no longer ends without a word when its process is interrupted or hits a
  fatal fault. Ctrl+C, Ctrl+Break, closing the console window, `SIGINT`, `SIGTERM` and `SIGHUP`
  are reported as `CableDyn_driver: stopped by <cause>`, and an access violation, a stack
  overflow or another fatal fault as `CableDyn_driver: fatal error: <cause>`. Both reports give
  the simulated time of the last committed step, and the exit status is unchanged. On Windows a
  fault report also names the module and offset of the fault and, for an access violation, the
  address read or written. Previously a stack overflow in a Windows GNU build ended the process
  with no message. Every thread that enters an OpenMP parallel region keeps room to report its
  own stack overflow, and on Linux and macOS a hardware fault reaches the handler that was there
  before (the Fortran runtime's backtrace, or the default action and its core dump) with its
  original address and context, and a previous handler runs under its own flags and signal mask;
  a fault signal sent by another process (`kill`) is passed on as sent. A signal the driver was
  started with ignored (for example under `nohup`) stays ignored.
- Every non-zero exit the driver makes itself now ends stderr with the closing line
  `CableDyn_driver: ended with exit code <n>`. A process ended from outside (`taskkill /F`, *End
  task*, `kill -9`) runs none of its own code and cannot report anything; the missing closing
  line now identifies it, since `taskkill /F` leaves exit code 1, the same code as a refused
  input. The driver states this at start, after the banner, in an `Exit status:` line.
  `CableDynDriver.run`, `cabledyn-run` and `cabledyn-study` report such a run as ended early,
  with the time its output reached, instead of relaying the start-up log as the error; with a
  driver that does not write the `Exit status:` line (0.1.0 and earlier), a failure is reported
  with the driver's own text as before. The documentation explains how to recognise each kind of
  early end and warns that `taskkill /IM CableDyn_driver.exe /F` ends every CableDyn run on the
  computer. A run the Fortran runtime ends with its own error (for example when memory runs out)
  is reported as ended with a Fortran runtime error, quoting the runtime's line.
- The static solve of a taut, neutrally buoyant finite-EI line (mass per length equal to
  the displaced mass) no longer depends on the sign of the round-off weight: a line whose
  total weight is below 1e-12 of its axial stiffness is seeded as a straight, uniformly
  stretched line. Previously the catenary seed could fail to close on some platforms.
- Windows builds with gfortran: the `modal` test could stop with a stack overflow on some
  CPUs, because it kept 1.7 MB of dense matrices on the stack. Large test arrays and the
  initialisation workspaces of the coupled aggregate and the C API are now allocated on the
  heap, every executable of such a build reserves a 64 MiB stack, and the new `stack` tests
  run the library on a 1 MiB thread stack. Results are unchanged.
- The static Windows `openfast.exe` compiles the CableDyn adapter with `/heap-arrays:1024`,
  like the CableDyn core, so its run-time-sized arrays no longer use the
  `openfast.exe` stack.
- Builds with gfortran 16 are free of `-Wuninitialized` warnings; the reported values (the
  bounds of unallocated components) were never read.
- The EPUB edition of the manual no longer contains the `.nojekyll` marker file.
- Python: `DeckFile` messages for an `END CONNECTIONS` row name the line, the end and the
  offending value, and the unit of a main-output channel written with leading zeros in its ids
  (`Ten01N04`, `Torq03N4`) is recognised, as the driver accepts such names.
- Torsion: an imposed static twist `Pretwist(B) − Pretwist(A)` above 1000 turns (for example
  a value given in the wrong units) now stops with a message naming the line and the value.
  Before, the static twist ramp could run for millions of stages.
- Torsion: installing a torsion description on a dynamic cable now invalidates its step
  snapshot, as a new end connection does, so a later restore cannot rewind to a state taken
  under the previous loads; a rejected description leaves the cable and its snapshot as they
  were, and ending a cable module also clears its torsion frame. End connections set after
  the torsion, and a torsion director that is not the rigid connection direction, are refused
  by name.
- `END CONNECTIONS` row errors now name the line, the end and the offending value.

### Known issues

- An intermittent access violation in the modal analysis tests has been seen on some hosted
  CI runners with GNU builds that use OpenBLAS 0.3.34. The cause is under investigation. The
  released Windows driver uses reference LAPACK and is not affected.

## [0.1.0] - 2026-10-01

First public release. Deck keywords, Python interfaces, and the C ABI are
versioned but may change before `1.0.0`. The validation evidence for every item
below is in
[VALIDATION.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/VALIDATION.md).

### Added

#### Lines and materials

- Geometrically nonlinear tension-only (`EI = 0`) elements for chains, wire ropes,
  and fibre ropes, and cubic-Hermite finite-bending elements for dynamic power
  cables, with continuous centreline curvature and no rotational degrees of
  freedom.
- Linear axial stiffness, Kelvin–Voigt damping, series-Kelvin viscoelasticity, and
  the Syrope polyester working-curve model with load-history initialisation. A
  `SYROPE IC` line starts in the static equilibrium solved on its `Tmax0` working
  curve; `Tmean0` is accepted for MoorDyn compatibility but does not enter the
  state.
- Discrete attachments on finite-EI cables (`ATTACHMENTS`): buoyancy modules and
  clumps (mass, displaced volume, normal and axial drag, added mass) at single arc
  lengths or `first:pitch:last` series, loaded by currents and waves in statics and
  dynamics, standalone and coupled. `EQUIVALENT BUOYANCY` remains the smeared
  alternative.
- Topology: fixed, coupled, free, and connected points; clump weights; rigid bodies
  and rods; finite-stiffness, clamped (`Rigid`), or moment-free cable-end
  connections; line failure; and active unstretched-length control for
  tension-only lines.

#### Statics

- Newton solution with catenary seeding, load continuation, mesh sequencing,
  adaptive meshing, section-interface preservation, and flat or gridded seabed
  contact. The initial condition of every run is the static equilibrium, solved
  directly.
- Tension-only lines are seeded from the exact elastic catenary with
  frictionless-seabed complementarity, by one initialiser shared by the static and
  dynamic routes. Slack, taut, vertical, and finely meshed lines, soft or sloped
  seabeds, and anchors resting on the seabed are covered; compressed branches are
  rejected.
- Finite-EI cables are solved from the exact `EI = 0` catenary by continuation in
  `EI`, with energy-minimising stages and a physical-branch audit (no self-contact,
  stable tangent); `cable_statics` (default `continuation`) selects whether the
  continuation or the mesh-sequenced route runs first. A mesh that cannot resolve
  the equilibrium curvature is refined, graded toward rotationally restrained ends,
  and reported, and a mesh finer than `sqrt(EI/EA)` is named before the solve; a solve
  that stalls on such a mesh stops within seconds. A line too long for its span to hang
  as a catenary (over a flat or uniformly sloped seabed) is solved in the equilibrium its
  bending stiffness holds, reached by walking the anchor back into place from where the
  catenary exists. Over a flat seabed in still water, when that walk fails or reaches a
  state that loops through itself, the bow behind the fairlead is traced instead: the
  anchor starts beyond the fairlead, the grounded run is folded back to its side once it
  reaches it, and the anchor is walked into place. When neither is reached the solve stops
  naming the geometry. With `tensile_safety True` the static refinement of a
  compression stops, naming it, once the compression is the reaction of a held end or a
  refined polish cannot follow it, and a walked bow compressed beyond a tenth of its
  peak tension is rejected before any refinement.
- The frictionless contact of a finite-EI line with a sloped structured seabed acts
  along the surface normal, as for tension-only lines, in statics and dynamics: the
  tension of a grounded run changes along the slope by the weight component.
- A steady current (uniform or a depth profile) enters the static equilibrium,
  including the out-of-plane offset. A finite-EI line whose grounded run the current
  drives into compression is solved out of its plane; a current that leaves a line
  no tension-only equilibrium stops the solve with the compression named; in the
  plane of the line that diagnosis is not repeated on a refined mesh or at a looser
  tolerance, and the drag of the current is evaluated in parallel. A cable
  laid on the seabed with friction reaches its equilibrium in any current direction.
  A very strong current on a frictionless seabed can fold the line back past its
  anchor (a hairpin); that stable equilibrium is kept and a note names it. In a current
  along the plane of the line the equilibrium is selected on the deck mesh coarsened to
  the bending length, so a refined `NumSegs` reaches the same equilibrium, and a planar
  equilibrium that is unstable out of its plane gives way to the stable 3D one.
- Free `Rigid6` bodies, free rods, and `Free`/`Connect` points start at their static
  equilibrium (`bodyIC`, default `static`; `deck bodyIC` keeps the deck pose). The
  solve converges from poor deck poses and never returns an unstable equilibrium.
- A failed initialisation names the line or object, the seeds and solver stages
  tried, and the reason.

#### Dynamics

- Implicit generalised-α integration with consistent structural, hydrodynamic,
  contact, and prescribed-motion terms, and internal step subdivision that never
  commits a partial state.
- Finite-EI cables blend the internal forces of the two step ends
  (`alpha_force_blend`, default `True`); `False alpha_force_blend` selects the
  configuration blend of the journal article.
- Rigid6 bodies, `Point3` buoys, free and pinned rods, and `Free`/`Connect` points
  step monolithically with their lines (`bodyScheme`, default `monolithic`): one
  implicit step with a Newton iteration on the object and point accelerations, each
  line returning its end reaction and condensed end stiffness. Bodies and rods are
  integrated at second order without numerical dissipation. By default
  (`accuracy bodySubstep`) the step is sub-divided to the phase accuracy of the
  stiffest body-mooring mode; `none bodySubstep` takes `dtM` as given.
  `staggered bodyScheme` keeps the staggered predictor-corrector for one release;
  decks with a `motionFile` or a `FAILURE` section, and the OpenFAST and C-API
  coupled routes, use it.
- A finite-EI cable end on a Rigid6 body point or a rod end can be clamped or carry a
  rotational spring; the connection turns with the object and returns its moment to
  it, in statics and dynamics.
- Line modal analysis (`nModes`): natural frequencies and mode shapes of every line
  about its static equilibrium, for `EI = 0` and cubic-Hermite lines, written to
  `<root>.modes.out`, by a banded solver that computes only the requested modes.
- The finite-EI tensile audit (`tensile_safety`) judges the element-mean axial force
  averaged over three elements, the force that enters equilibrium, in the dynamic step
  and in the static contract alike, instead of the pointwise resultant, whose
  oscillation grows with the element length. A coarse mesh whose tensions and
  curvatures are converged is no longer read as compressed or refined for it (the Gulf
  of Mexico 80 m lazy wave under heave passes at 48 elements), and a genuine compression is still
  rejected on every mesh.
- A plausibility guard (`maxStrain`, default `0.5`) stops a run whose `EI = 0` lines
  reach a non-finite state or an element strain beyond the bound.
- After its first steps, a coupled step makes no heap allocation.

#### Environment

- Buoyancy, Morison drag, added mass, Froude–Krylov loading, axial hydrodynamic
  loading, wetting, and current profiles. Finite-EI buoyancy at the free surface
  follows the partial immersion of the circular section.
- Waves: Airy; random-phase `jonswap` seas (`WaveSeed`); ISSC/Pierson–Moskowitz,
  Torsethaugen, and Ochi–Hubble spectra; cos-2s directional spreading
  (`WaveSpreading`, `WaveDirections`); up to 16 superposed wave trains
  (`wavetrain`); Dean stream-function waves (`stream`, `StreamOrder`); and a
  half-cosine wave ramp (`rampTime`).
- MoorDyn-C water kinematics: `WaveKin 3` (`wave_elevation.txt`), `WaveKin 7`
  (`wave_frequencies.txt`), and `Currents 1` (`current_profile.txt`). The other
  MoorDyn-C modes fail closed by name.
- Seabed contact on flat and sloped bathymetry (along the surface normal) with the
  same law in statics and dynamics, and stick-slip seabed friction on `EI = 0` and
  finite-EI lines, isotropic (`frictionMu`) or anisotropic (`frictionMuAxial`,
  `frictionMuLateral`); rods and bodies use a velocity-regularised law. The friction
  state is committed with the step, the snapshots, and the OpenFAST checkpoint.

#### Bodies, rods, and points

- Rigid6 bodies with weight at the centre of gravity, buoyancy at the centre of
  buoyancy, the full rigid-body mass matrix, and hydrostatic restoring (`C44`/`C55`)
  about the body's own axes. MoorDyn v2 14-column `BODIES` rows are read. Buoyancy,
  drag, fluid inertia, and added mass follow the submerged fraction of an equivalent
  sphere (`bodyWetting sphere`, default); `bodyWetting moordyn` and
  `bodyHydro moordyn` reproduce MoorDyn's always-wet body.
- Rigid rods (MoorDyn `ROD TYPES`/`RODS`) with loads integrated over `NumSegs`
  segments, exact wet cross-sections at any tilt, and MoorDyn's end added mass, end
  drag, and end fluid inertia, plus the axial Froude–Krylov force on the end caps.
  `ROD TYPES` columns 6–7 are MoorDyn's `CdEnd CaEnd`; the axial side coefficients
  `CdAx CaAx` are optional columns 8–9. `rodHydro moordyn` reproduces MoorDyn's
  surface-piercing rod moment.
- Rod topologies: rods fixed to a body (`Body<N>`), pinned rods (`Pinned`), rods
  pinned to a body (`Body<N>Pinned`), zero-length rods, the MoorDyn `RODS` attachment
  aliases and `R<N>A`/`R<N>B` line attachments, and decks of bodies and rods without
  lines. One standalone march covers any mix of bodies, rods, points, `EI = 0` lines,
  and finite-EI cables.
- External loads (MoorDyn-F `EXTERNAL LOADS`): constant force and linear or
  quadratic translational damping on Rigid6 bodies, in the global or body frame.
- A `FAILURE` row may detach a line from a free Rigid6 body (standalone), for
  accidental-limit-state runs; the detached end moves as a free point.
- Standalone farm decks: a `TURBINES` section runs FAST.Farm `Turbine<J>` decks in
  the standalone driver, with per-turbine motion records in the `motionFile`.

#### Prescribed motion

- `motionFile` records for coupled points, bodies, and rods.
- 6-DOF vessel motion (`vesselMotion`, about `vesselRef`): position and roll, pitch,
  and yaw in the OrcaFlex `Rz·Ry·Rx` convention or a unit quaternion, with velocities
  and accelerations. Every `Coupled`/`Vessel` point moves rigidly with the vessel,
  and a finite or `Rigid` end connection turns with it.
- RAO-driven vessel motion (`vesselRAO`): a displacement RAO table in the OrcaFlex
  convention, driven by the deck's linear sea (regular, spectral, spread, wave-train,
  or WaterKin) with the same component phases and ramp as the line kinematics.

#### Outputs

- `FairTen`/`AnchTen` and the end-node `Ten<L>N<J>` channels report the line-end
  force, as MoorDyn and OrcaFlex do: the end element's force with axial damping and
  bending shear, plus the end node's share of weight, seabed contact, and drag,
  without the end node's inertia. At rest it is the static end reaction on every
  route. Finite-EI node tensions are segment tensions, as on `EI = 0` lines;
  `.elements.out` keeps the pointwise extrema.
- Body, rod, and point channels with MoorDyn-F names (`Body<N>…`, `Rod<N>…`,
  `Point<P>Fx/Fy/Fz/FH`), standalone and in OpenFAST.
- Range graphs (`LINES` `Outputs` flag `r`): the minimum, maximum, and mean of
  effective tension, curvature, bend moment, declination, and seabed clearance at
  every node, in `<root>.Line<L>.range.out`; `RangeStart` leaves out a start-up
  transient.
- Touchdown channels `TDP<L>s`, `TDP<L>x/y/z`, `TDP<L>Lay`, and `TDP<L>Exc` for a
  line grounded at one end, on every route including OpenFAST.

#### Standalone driver

- `CableDyn_driver` with documented input, output, exit-code, and convergence
  behaviour. Inputs are range-checked on every row, and errors name the deck line.
  Every number in a deck row, an option, or an auxiliary file must be finite and
  not subnormal, input magnitudes are bounded where larger ones would overflow the
  solver (listed in the deck format reference), and line attachments are unquoted
  point ids or rod ends read whole. Non-fatal notes flag an axial start-up shock from
  a prescribed motion, a slack line below its anchor on a deck without a seabed, an
  over-soft `kBot`, time steps or meshes too coarse for a finite-EI line, and a
  static layout folded back past its anchor.
- The initialisation report, standalone and coupled to OpenFAST, prints the fairlead
  end-force vector with its own inclination and the line tangent angles on a separate
  `line tangent` row; the two angles differ by
  the end node's share of the distributed load and, on a finite-EI line, the end
  shear.
- Arguments and file names are read as Unicode. The Windows release executables
  run with UTF-8 as their code page, so decks, outputs, and working folders may be
  named in any script whatever the system locale. The driver opens exactly the named
  file or refuses it with a reason (over-long paths and reserved device names, and,
  in a GNU source build, names the ANSI code page cannot spell). It never overwrites
  an input file and locks its output root.

#### OpenFAST module

- `CompMooring = 5`: mixed mooring and power-cable systems, SeaState kinematics, an
  independent CableDyn time step (the largest multiple of the glue `DT` not exceeding
  it), correction iterations, initial platform offset (`PtfmInit`),
  checkpoint/restart, quasi-static linearisation, active line control, and FAST.Farm
  shared moorings.
- `Coupled`/`Vessel` bodies and rods follow the platform as 6-DOF nodes of the
  coupling mesh and return the force and moment of their lines, hydrostatics,
  SeaState Morison loads, contact, external loads, and inertia. Coupled rods sample
  SeaState along their segments. Free Rigid6 bodies and rods share the deck with
  them and start at their static equilibrium with the platform at `PtfmInit`.
- Discrete cable attachments run on the coupled route with the host's SeaState
  kinematics.
- Linearisation fails closed on a deck with Rigid6 bodies or rods.
- The coupled initialisation report and `<root>.CD.static.out` give the static
  equilibrium, solved before the SeaState kinematics act. The requested `OUTPUTS`
  printed at initialisation, the first `<root>.CD.out` row and the first OpenFAST
  output row give the t = 0 values, which include the SeaState load at t = 0 on the
  line end nodes; the console labels each state.

#### C interface

- Opaque model handles, checked lifecycle calls, fluid-kinematics exchange, motion
  input, load output, and C ABI version 1. Initialisation is thread-safe, and steps
  on distinct handles run concurrently. `CableDyn_Close` releases the calling
  thread's OpenMP worker pool. OpenBLAS uses one thread per calling thread by
  default (`CABLEDYN_BLAS_THREADS`); a Windows GNU build that cannot load OpenBLAS
  fails with a message naming the library and each location tried.
- ABI 1 minor extension 1 (`CableDyn_GetAbiMinor`) adds object queries:
  `CableDyn_NObjects`, `CableDyn_GetObjectInfo`, `CableDyn_GetLineValues`,
  `CableDyn_GetPointState`, `CableDyn_GetBodyState`, `CableDyn_GetRodState`, and
  `CableDyn_EvalChannel`, which read through the evaluator behind the output
  channels.
- `CableDyn_InitDeck` runs decks with finite-EI lines, `Point3` buoys, free `Rigid6`
  bodies, and free, fixed, or pinned rods on the coupled aggregate (still water).

#### Python package (`cabledyn`)

- Native coupling through the C interface and standalone execution
  (`cabledyn-run`), with atomic result replacement on `overwrite=True`.
- Deck validation and loss-aware editing (`cabledyn-deck`), parameter grids, and
  batch studies (`cabledyn-study`) with provenance manifests.
- `DeckModel`: an object model to build and edit decks, with reference-safe rename
  and remove, validated through `DeckFile`.
- Readers for CableDyn, OpenFAST (text and binary), and MoorDyn outputs, including
  the output files of coupled runs. A channel that an OpenFAST OutList repeats is
  kept, the repeats renamed `<name>_2`, `<name>_3`, ... with a warning.
- Post-processing (`cabledyn-post`): run comparison, resampling and zero-phase
  filtering, spectra and coherence, rainflow counting and damage-equivalent ranges,
  block and up-crossing extremes with Gumbel and Weibull fits, and line geometry.
- Fatigue and design checks for moorings and dynamic power cables: S-N and T-N
  curves with the published DNV-RP-C203, DNV-OS-E301, and API RP 2SK constants,
  Palmgren-Miner damage with an optional Goodman correction, damage along the arc,
  lifetime damage over the sea states of a batch study, MBR bend checks, and tension
  checks against MBL.
- Range graphs, touchdown histories, results at a time as arc-length profiles, seabed
  and line-to-line clearance, and per-channel and per-line summary tables.
- In-process object views (`CableDyn.lines`, `points`, `bodies`, `rods`) and
  `channel()` for any output channel.
- `Snapshots`: time-indexed geometry of every object with the seabed and free
  surface, recorded in-process or collected from driver output files, stored as
  `.npz`, and played by `animate()` in Matplotlib.

#### Examples, validation, and distribution

- Examples: catenary, taut, and semi-taut moorings; synthetic ropes; connected
  objects; bodies and rods; regular and irregular forcing; vessel motion; the IEA
  15 MW VolturnUS-S platform; and the 80, 200, and 800 m reference lazy-wave power
  cables. The 80 m cable under prescribed heave runs on 64 elements, within 0.5 % of a
  1024-element solution in fairlead tension and peak curvature, in under a second.
- Validation record: analytical tests, comparisons with MoorDyn and OrcaFlex, the
  Holcombe lazy-wave and Bergdahl dynamic-chain experiments, coupled OpenFAST tests,
  refinement studies, performance measurements, and the reproduction of the journal
  article
  ([validation/PAPER_REPRODUCTION.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/validation/PAPER_REPRODUCTION.md)).
  OrcaFlex comparisons are kept as the summary values the tests check; the scripts
  that regenerate the full OrcaFlex output for licence holders are included.
- Acknowledgements of MoorDyn, OpenFAST, and OrcaFlex in the README and the manual.
- Statically linked Windows executables (`CableDyn_driver.exe`, `openfast.exe`)
  built with Intel IFX against the reference LAPACK/BLAS; Python wheel and source
  distribution; SHA-256 checksums; a Sphinx user manual; and cross-platform
  continuous integration.

### Fixed

Corrections made during the pre-release review.

- `EXTERNAL LOADS` reads the MoorDyn-F column order `ID Object Fext Blin Bquad CSys`.
  Rows with `CSys` in the third column are still read, and several rows on one object
  add up. IDs run 1, 2, 3, … in row order. A row on a `Point3` body stops with an
  error (external loads apply to Rigid6 bodies only).
- On the coupled OpenFAST route, a deck `waves` option stops with an error, because the
  host's SeaState supplies the waves. A deck `current` is kept as a steady current only on a
  single-turbine, pure `EI = 0` deck without Rigid6 bodies or rods whose SeaState carries no
  waves or current; otherwise it stops with an error. `DeckFile(caller_driven=True)` in the
  Python package applies the parts of this rule that the deck alone decides.
- The `EI = 0` element tension behind the `Ten` channels, range graphs and line tension
  files includes the axial Kelvin–Voigt (`BA`) share, as the end forces already did.
- On sloped bathymetry, `EI = 0` seabed damping and the friction capacity act along the
  floor normal, as on the finite-EI path; a level floor is unchanged.
- The static drag continuation follows its path in one consistent metric near a limit
  point.
- A coupled step that fails after the body and rod update returns bodies and rods,
  as well as lines, to the start of the step. `CableDyn_Step` reports
  `converged = stalled = false` and `n_iter = 0` for any step that does not commit, on
  every route. `CableDyn_EvalChannel` accepts a buffer length with an embedded `NUL`.
- Checkpoint restart and linearisation rebuild from a temporary deck copy written
  beside the `MooringFile` and removed after use, so the files the deck names
  (bathymetry, WaterKin, Syrope tables) resolve as in the original run. The OpenFAST
  module says at initialisation that it provides no VTK visualisation meshes.
- A very large `WaveComponents` × `WaveDirections` request is rejected instead of
  overflowing the component count.
- `OPTION nModes` on a deck that mixes `EI = 0` and finite-EI lines stops with a named
  error; that route writes no modal files.
- MoorDyn friction keywords (`mu_kT`, `mu_kA`, `mc`, `cv`, `FricDamp`,
  `StatDynFricScale`), `CoupledPinned`/`VesselPinned` rods, `N0` line-node channels and
  numbers with a sign inside the mantissa fail with a named error. A relative
  `WaveKinFile` is resolved against the deck folder first, as in MoorDyn-F, then the
  WaterKin file's folder.
- Python: `tension_check` takes `strength_factor` (default 0.95, exported as
  `DNV_OS_E301_STRENGTH_FACTOR`); an `analysis` or `consequence_class` argument that
  does not belong to the chosen standard is rejected.
- Python: `RangeGraph.line_id` may be `None`, and `SeabedClearance` has a `line_id`;
  `PowerSpectrum.window` is stored in canonical form (`"hann"`, `"boxcar"`); MoorDyn-F
  `Node<J>ax/ay/az` channels are read.
- Python: `generate_deck_cases` and `DeckModel.save(rebase=True)` copy the MoorDyn-C
  kinematics files (`wave_elevation.txt`, `wave_frequencies.txt`, `current_profile.txt`)
  next to the new decks, and `cases.json` records them under `companion_files`.
- Python: `DeckFile` rejects the decks the solver rejects: the `WaveKin 3/7` and
  `Currents 1` rules, the `nModes` rules, output-channel and `FAILURE` rules, a
  non-positive `dtWave`, a JONSWAP `gamma` out of range, and an attachment beyond the
  line length.
- Documentation: every command in the manual, the examples and the validation records
  creates its output folder first; the source-build driver name (`cabledyn`) and the
  release name (`CableDyn_driver.exe`) are both given; the validation record quotes the
  values of the shipped example decks and states which tension (end element or
  `FairTen` end force) each comparison uses.

[Unreleased]: https://github.com/SMI-Lab-Inha/CableDyn/compare/v0.4.2...HEAD
[0.4.2]: https://github.com/SMI-Lab-Inha/CableDyn/releases/tag/v0.4.2
[0.4.1]: https://github.com/SMI-Lab-Inha/CableDyn/releases/tag/v0.4.1
[0.4.0]: https://github.com/SMI-Lab-Inha/CableDyn/releases/tag/v0.4.0
[0.3.0]: https://github.com/SMI-Lab-Inha/CableDyn/releases/tag/v0.3.0
[0.2.0]: https://github.com/SMI-Lab-Inha/CableDyn/releases/tag/v0.2.0
[0.1.1]: https://github.com/SMI-Lab-Inha/CableDyn/releases/tag/v0.1.1
[0.1.0]: https://github.com/SMI-Lab-Inha/CableDyn/releases/tag/v0.1.0
