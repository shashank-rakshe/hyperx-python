<!-- SPDX-License-Identifier: Apache-2.0 -->

# CableDyn architecture

This document is for contributors and integrators who need to find their way
around the solver source. It outlines the numerical formulation, the module
layout, and the public interfaces. Full equations are in the
[theory manual](doc/theory.rst); units, frames, and signs are in
[doc/conventions.rst](doc/conventions.rst); build and test instructions are in
[DEVELOPMENT.md](DEVELOPMENT.md); results are in [VALIDATION.md](VALIDATION.md).

## Overview

CableDyn is a Fortran 2018 solver (`src/`) for mooring lines and dynamic power
cables of floating offshore wind turbines and substations. It has two
position-based finite-element paths, neither with rotational degrees of freedom:

- an **`EI = 0` cable path** (positions only) for chains, wire, and synthetic
  moorings; and
- a **finite-EI cubic-Hermite path** (positions and material tangents) for power
  cables, where bending stiffness governs hang-off, sag-bend, and touchdown
  curvature.

Lines connect to **points** (fixed, coupled, free, and connected; clump weights and
buoys), **`Rigid6` bodies**, and **rigid rods**, and one deck may mix all of them
with both line paths. A secondary Cosserat rod path with SO(3) rotation DOFs
handles the one standalone finite-EI topology in which both line ends are
prescribed; its tests carry the `cosserat` CTest label.

Not provided: torsion, nonlinear cross-section laws, rotational endpoint motion of
finite-EI lines other than through end connections, and vortex-induced vibration.
Requests for unsupported features stop with a named error.

## Core and coupling shells

One solver core serves three callers:

1. the **standalone driver** (`app/cabledyn.f90`, released as
   `CableDyn_driver.exe`), which reads a deck, solves it, and writes the outputs;
2. an **OpenFAST module** (OpenFAST is maintained by NLR, the National Laboratory of
   the Rockies, formerly NREL) selected with `CompMooring = 5` (and `MooringMod = 5` in
   FAST.Farm), in the role of MoorDyn-F; and
3. a **C interface** for CFD solvers and custom co-simulation, in the role of
   MoorDyn-C, also used by the `cabledyn` Python package.

The coupled callers share one **coupling boundary**: coupled-point position,
velocity, and acceleration in (with orientation and angular rates for 6-DOF host
nodes); force (and moment) on each coupled node and analytic load derivatives out;
fluid kinematics from the host or from the deck environment. The core contains no
host-specific logic. The contract is in
[doc/coupling_boundary.md](doc/coupling_boundary.md).

The core is a finite-element line-object solver: a cable is one End-A-to-End-B
object built from ordered sections. `POINTS`, `BODIES`, and `RODS` rows of the
MoorDyn-style deck map to the objects below where the mapping is physically
defined; other MoorDyn topology is rejected. `CableDyn_DeckDriver` parses the deck,
owns the body and rod runtimes, runs every standalone route, and is the deck
initialiser for the OpenFAST aggregate and the C API.

## Numerical formulation

### EI = 0 element

`CableDyn_CableElem` is a two-node, positions-only element with axial strain
energy and its exact geometric tangent:

```text
T   = EA · (ℓ/L₀ − 1)
K_e = (EA/L₀) t⊗t + (T/ℓ)(I − t⊗t)          (material + geometric)
```

with consistent mass `(ρ_A L₀ / 6)·[[2I, I], [I, 2I]]`. In tension-only mode a
compressed element carries no force or material stiffness; dynamics are
tension-only, and the static initial condition is the tension-only equilibrium
(a compression-capable Newton iteration is used only as a solver stage). The static solver
(`CableDyn_Static`) is Newton with an Armijo line search and load continuation,
seeded by the extensible catenary of `CableDyn_Catenary`. Dynamics
(`CableDyn_Dynamic`) use generalised-α. `CableDyn_Model` wraps one line with its
hydrodynamics, constitutive state, and friction anchors, and `CableDyn_System`
owns several lines with their 3-DOF points.

### Finite-EI cubic-Hermite element

`CableDyn_HermiteCable` carries `[r(3), m(3)]` per node with `m = ∂r/∂s`; the
centreline is the cubic-Hermite interpolant, giving 12 DOFs per element. The
stored energy is

```text
U = ∫ ( ½ EA ε² + ½ EI κ² ) ds ,   ε = |r'| − 1 ,   κ² = |r' × r''|² / |r'|⁶
```

integrated by Gauss–Legendre quadrature (four points by default; axial and bending
orders selectable from 1 to 6). The internal force `∂U/∂q` and tangent `∂²U/∂q²`
are closed form and symmetric to round-off, and are checked against finite
differences in the tests.

The element is the geometrically exact Kirchhoff-rod formulation of Boyer et al.
(2011) with the C¹ Hermite interpolation of Meier, Popp and Wall (2015). Without
rotation DOFs it avoids the `|θ| < π` rotation-vector chart, the bending/axial
conditioning split at small `EI`, and the curvature limit of linear interpolation.

The static solver (`CableDyn_HermiteCableStatic`) is a damped Newton iteration
with `EI` and buoyancy continuation from the exact `EI = 0` catenary, consistent
self-weight, penalty seabed contact, mesh sequencing and adaptive meshing, and a
dimensionless residual norm. The dynamic solver (`CableDyn_HermiteCableDynamic`)
solves `M q̈ + f_int = f_ext` by generalised-α with constant consistent mass,
prescribed support motion, backtracking Newton from the constant-acceleration or
Newmark predictor, Morison loads integrated over the deformed element, and
adaptive step subdivision.

**Performance.** Both Hermite solvers assemble directly into LAPACK band storage
(half-bandwidth 11), apply Dirichlet conditions in-band, and allocate workspace
once, so a dynamic step performs no heap allocation. With OpenMP, meshes of at
least 32 elements evaluate element tangents in parallel and scatter them serially
in element order, so results do not depend on the thread count. Independent lines
advance concurrently. A standalone step on smooth motion starts from the previous
step's factorised tangent and refreshes it when the residual contraction weakens;
optional modified Newton also reuses it within a step.

**End connections.** An `END CONNECTIONS` row gives a finite-EI line end a
rotational spring or a clamp relative to its support (`CableDyn_EndConnection`).
Both act on the tangent **direction** only; the tangent magnitude carries the
axial stretch and stays free. A finite stiffness is the spring `U = k θ²/2` on the
angle between the tangent and the connection direction. `Rigid` is an exact
constraint, not a penalty: the two transverse components of the end tangent are
removed and only its magnitude along the connection direction is solved, in
statics and in dynamics. The connection direction turns with the supporting
vessel, body, or rod, and the connection moment (`m × ∂U/∂m` for a spring, the
transverse end reaction for a clamp) is returned to it with the end force.

**Discrete attachments.** `ATTACHMENTS` rows place buoyancy modules and clumps
(mass, displaced volume, normal and axial drag area, added-mass coefficient) on a
finite-EI line, one at a time or as `first:pitch:last` series. Each attachment
is lumped at its nearest node. The static solve starts from the attachment weight
smeared over the adjacent elements and moves it onto the nodes by homotopy, with
the current drag iterated to a fixed point. In dynamics the node carries the mass
plus added mass, the net weight, fluid inertia, and quadratic drag normal and
along the local tangent, with their Jacobians. `EQUIVALENT BUOYANCY` remains the
smeared alternative.

### Secondary Cosserat path

`CableDyn_Cosserat*` and `CableDyn_SO3` implement a rod with centreline `r(s, t)`
and orientation `Λ(s, t) ∈ SO(3)`, with material strains (Simo 1985)

```text
Γ(s) = Λᵀ ∂r/∂s − Λ₀ᵀ ∂r₀/∂s      (axial + shear)
K(s) = T_m(θ) ∂θ/∂s               (material curvature)
```

using the rotation vector on `|θ| < π` (states outside are rejected). Two-node
linear elements use two-point Gauss integration for axial strain, bending, and
twist, and one-point integration for shear. The closed-form force and tangent are
checked in the tests against the second-order automatic differentiation of
`CableDyn_AD`. `CableDyn_FiniteEIModel` is the lifecycle wrapper the deck driver
uses for the both-ends-prescribed topology; `CableDyn_CosseratEMC` provides an
opt-in energy-conserving integrator (library use only).

### Axial constitutive models

Selected per line type in the deck. Each stateful model updates its internal state
once per converged step (`CableDyn_Model`) and rolls back with the kinematic state
on failure.

- **Viscoelastic** (`CableDyn_Viscoelastic`, MoorDyn `ElasticMod = 2/3`): a fast
  Kelvin–Voigt branch (`EA_D` ∥ `BA_D`) in series with a slow Kelvin–Voigt branch
  (`EA_1` ∥ `BA_s`), which reduces to the standard linear solid when `BA_D = 0`.
  The slow-branch stretch `dl_1` is eliminated in closed form by backward Euler
  inside the implicit step. Mode 3 evaluates a mean-load-dependent `EA_D`. A
  zero-rate initial partition makes the static equilibrium an exact dynamic fixed
  point.
- **Syrope** (`CableDyn_Syrope`): an original-working-curve strain–tension table
  split into an exponential fast spring `ε_fast(T) = ln(1 + (β/α)T)/β` (stiffness
  `α + βT`) and a slow strain, with working curves regenerated from the running
  maximum tension. With `BA = BA_s|BA_d`, the line tension is
  `T_mean + BA_s·dε_slow/dt`; the slow state advances by a bracketed
  backward-Euler solve with `ε_slow ≥ 0`. Supported on single-section taut
  `EI = 0` lines.

### Time integration

Chung–Hulbert generalised-α on both paths, parameterised by the spectral radius
`ρ∞` (deck option `rhoInf`, default 0.4; the `EI = 0` and Cosserat library default
is 0.8, and the Hermite solvers take it as an argument):

```text
α_m = (2ρ∞ − 1)/(ρ∞ + 1)    α_f = ρ∞/(ρ∞ + 1)
β   = (1 − α_m + α_f)²/4    γ   = 1/2 − α_m + α_f
```

The effective tangent is `(1 − α_m)/(β Δt²) M + (1 − α_f) K_q +
(1 − α_f) γ/(β Δt) K_v`. Deck defaults: relative tolerance 1e-8, absolute
1e-14, 30 iterations, 12 backtracks. A non-converged step, or on the Hermite path
an under-resolved one, is repeated by internal subdivision (4, 16, … up to
`recovery_max_substeps`) along a C² quintic boundary trajectory that ends on the
host time. On `EI = 0` lines `CD_Step_Model` also re-solves a converged step in
`max(4, ceil(turn/ei0_substep_angle))` sub-steps on the same trajectory when a
taut segment turned by more than `ei0_substep_angle` or a slack segment snapped
taut while the step does not resolve its axial wave (`ei0_substeps auto`, the
default; at most `ei0_substep_max`). It restores the committed kinematics and
constitutive and friction states first (`commit_state_copy`, the one list of
that state in `CableDyn_Model`) and keeps the plain step when a sub-step fails.
The sub-steps of a recovered step, the halves of a line-system step halved by
`CD_Step_System`, and the lines attached to the objects of the monolithic
body/point step are taken as given.

### Bodies, rods, and points

The object runtimes live in `CableDyn_DeckDriver`; `CableDyn_RigidKinematics`
maps a rigid pose to attached-point kinematics, point loads to a wrench, and
advances rigid states on SO(3).

- **`Rigid6` bodies** have six DOFs (position and a rotation matrix), mass,
  inertia, centre of gravity, displaced volume, hydrostatic restoring
  (`C33`/`C44`/`C55`), drag, added mass, and external loads. `Coupled`/`Vessel`
  bodies are driven by the host or a motion file. A `Point3` body is stepped as
  the free point it is attached at.
- **Rods** are rigid cylinders: **free** (six DOFs), **fixed**, **pinned** (End A
  held at a pin, three rotations), **coupled/vessel** (prescribed), **fixed to a
  body** (lumped into the body's mass, inertia, hydrodynamics, and seabed loads),
  or **pinned to a body** (own rotations about a body pin). A zero-length rod
  (`NumSegs 0`) becomes one point of the matching kind.
- **Points** are `Fixed`, `Coupled`/`Vessel`, `Free`, or `Connect`, or attached to
  a body (`Body<N>`) or a rod end. Free and Connect points with mass and volume
  are the clump weights and buoys, with lumped drag and added mass.

A deck that combines families (bodies with free points, rods with bodies, or
finite-EI cables beside bodies, rods, or dynamic points) runs on one multibody
march: its `EI = 0` lines form one `CD_SystemType` with the object attachment
points as coupled points, and each finite-EI cable is a Hermite line whose End A
is driven like a coupled fairlead by its object. Other decks take the
single-family route that fits them.

**Static equilibrium** (`bodyIC static`, the default). Free bodies (six unknowns),
free rods (five, no spin), pinned rods (two rotations), and free points (three)
that carry lines are solved together for zero net force and moment under weight,
buoyancy, hydrostatics, steady-current drag, seabed contact, and the end forces of
their lines, each line re-solved to its own static equilibrium at every trial
pose. The Jacobian uses the analytic condensed stiffness of every attached line,
`K_c = K_ee − K_ei K_ii⁻¹ K_ie` from its banded tangent, mapped through the
attachment arms. The iteration is a trust-region Newton with a Levenberg–Marquardt
and finite-difference fallback, rotation steps limited to 0.25 rad, and a
rotations-held restart. A converged pose must be stable: the symmetric part of the
restoring Jacobian must pass a Cholesky test, otherwise the solve stops by name
(`bodyIC deck` starts from the deck pose instead). A finite-EI line enters this
solve through its axial stiffness and weight; a clamped or elastic End A adds the
Hermite end force and connection moment through fixed-point passes.

**Dynamics.** With `bodyScheme monolithic` (the default) bodies, rods, and free
points step in one implicit generalised-α step with their lines. The unknowns are
the object accelerations (six per body, three per pinned rod, six per free rod,
three per point). Each Newton iteration moves the attachment points to their
Newmark end state, steps every `EI = 0` line from the step-entry state with that
end motion, and adds the line's condensed dynamic end tangent to the object
Jacobian; cables clamped to an object are re-stepped at every iteration and add
their force and moment. Objects use their own generalised-α levels: bodies and
rods the non-dissipative trapezoidal rule (`α_m = α_f`, `β = 1/4`, `γ = 1/2`),
points the lines' levels, and each line applies its object's levels at the DOFs the
object drives.
A step that does not converge is halved recursively. `bodySubstep accuracy` (the
default) divides a coupling step so that the stiffest estimated body–mooring
frequency satisfies `ω Δt ≤ 0.28`; `bodySubstep none` takes `dtM` as given.

The staggered scheme (`bodyScheme staggered`) is a central-difference predictor
for the objects, a line step with the objects' end motion, and an acceleration
corrector, sub-stepped for `ω Δt ≤ 0.4`. It is used when named, for decks with a
motion file or a `FAILURE` section, and in coupled OpenFAST runs.

### Environment

`CableDyn_Hydro` provides Morison drag (normal `½ρ d C_dn |u_n| u_n`, tangential
`½ρ πd C_dt |u_t| u_t`), added mass `ρA[C_an(I − tt) + C_at tt]`, Froude–Krylov
and fluid inertia `ρA[(1 + C_an) a_n + (1 + C_at) a_t]`, wetted-fraction buoyancy,
Airy waves (dispersion relation solved by bisection), Wheeler stretching (rejected
when the trough reaches the bed), a 200-component JONSWAP sea with seeded random
phases and bin-jittered frequencies (`WaveSeed`), arbitrary component tables,
N-level current profiles, and the SeaState `CurrMod = 1` steady current. Fluid
kinematics reach the loads through the coupling boundary, so a host-supplied field
replaces the internal one without changing the load code.

- **Spectral and multi-train seas** (`CableDyn_WaveSpectra`): up to 16 wave trains,
  each regular or spectral (JONSWAP, ISSC/Pierson–Moskowitz, Torsethaugen,
  Ochi–Hubble) with its own heading and an optional cos-2s spreading exponent
  (`D(θ) = K(s) cos^2s(θ − θ_p)`). Each train is discretised into equal-width
  frequency bins per direction bin, with a random frequency inside each bin and a
  random phase from the seeded generator. All components are summed with one
  Wheeler mapping against the total surface elevation.
- **Stream-function waves** (`CableDyn_StreamWave`): regular nonlinear waves by the
  Fourier method of Rienecker and Fenton (20 terms by default, up to 60), solved
  by Newton from a linear wave. The field is exact up to the free surface, so no
  stretching applies.
- **WaterKin** files and MoorDyn-C wave modes supply precomputed kinematics.
- **Vessel motion** (`CableDyn_Vessel`): a vessel is a rigid body with a reference
  point and a rotation `R = Rz(ψ) Ry(θ) Rx(φ)` (the OrcaFlex convention). Its
  coupled points and end connections move with it from a 6-DOF motion record or
  from a displacement RAO table: the complex RAO is interpolated in wave period and
  relative heading and applied to every component of the deck's linear waves.

### Seabed contact and friction

`CableDyn_SeabedContact` defines a C¹ normal penalty law (linear beyond a 1 µm
blend); `CableDyn_Bathymetry` provides bilinear gridded bathymetry with slope
terms in the tangent, and the contact on a sloped patch acts along the surface
normal. Nodal stiffness is `kBot · d · L₀` and damping `cBot · d · L₀` (downward
approach only).

Friction on a line node is a stick-slip spring of the nodal normal stiffness to
an anchor, capped at `μ` times the normal reaction; at each committed state a
sliding spring's anchor moves to the capacity distance behind the node, so the
force carries into the next step and holds at rest. The anchors are committed
state: they roll back with a failed step and are part of the snapshots and the
OpenFAST checkpoint. With `frictionMuAxial` and `frictionMuLateral` the capacity
depends on the slip direction relative to the horizontal line axis (the OrcaFlex
axial and normal coefficients); an equal pair is the isotropic law. In a deck
current the static solve holds the line with smoothly capped friction springs from
its still-water laid shape and seeds the anchors with their forces. All terms have
analytic Jacobians.

### Modal analysis

`CableDyn_Modal` computes the lowest natural frequencies and mode shapes of a line
about its static equilibrium, `K φ = ω² M φ`, over the free DOFs, with `K` the
static tangent (element stiffness and linearised seabed contact) and `M` the
consistent mass plus Morison added mass. `K` and `M` are assembled in symmetric
band storage. A shift-invert block Lanczos iteration on the banded Cholesky factor
of `K` gives the eigenvalues, certified by a Sturm count of `K - σM` (LAPACK
`DSBGVX` takes short lines, an indefinite or singular `K`, and an uncertified run),
and inverse iteration on the banded pencil gives each mode shape, so the cost
grows with line length rather than with its square. Dense `DSYGV` is kept as the
test reference. Both line paths are supported (`nModes`). A finite-EI line's
modes (`CD_Modal_Hermite_Line`) take its end connections and attachments from the
dynamic model, and a line restrained in torsion adds the twist angle of every
node: its lumped polar inertia and the second variation of the nodal-twist energy
(`CD_HermiteCable_Dyn_Twist_Hessian`) in a band of 7 DOFs per node.

### Outputs

The line-end force (`FairTen`, `AnchTen`) is the magnitude of the force the line
exerts on its end point: the end element's internal force (tension with axial
damping, plus bending shear on a finite-EI line) and the end node's share of the
submerged weight, seabed contact, and drag at the actual velocity, without the end
node's inertia. At rest it is the static end reaction, so the static and dynamic
routes agree at the initial condition. `CableDyn_RangeOutput` keeps per-node range
envelopes (minimum, maximum, and mean from `RangeStart`) of position, tension,
curvature, bending moment, declination, and seabed clearance, and evaluates
touchdown-point channels (arc length, position, layback, and excursion) where the
centreline crosses the contact height.

## Coupled OpenFAST module

`src/openfast/CableDyn_OF.f90` is the OpenFAST module (`CompMooring = 5`), built
only inside an OpenFAST source tree. It drives `CableDyn_OpenFAST_Aggregate`, a
facade that composes one deck's `EI = 0` mooring system
(`CableDyn_OpenFAST_FMF` over `CableDyn_OpenFAST`), one
`CableDyn_OpenFAST_HermiteFMF` per finite-EI cable, and the `Coupled`/`Vessel`
bodies and rods, which are 6-DOF host nodes (orientation and angular rates in,
force and moment out). `CableDyn_OpenFAST_Mesh` and `CableDyn_OpenFAST_Types` keep
the exchange buildable and testable without OpenFAST.

- **Own time step.** The mooring advances at its own `dtM` (a whole number of
  glue steps; 0.1 s when the deck has none). Between mooring steps the host sees
  the committed loads as a zero-order hold, and output channels are recomputed only
  after a new commit.
- **Host fluid.** When SeaState declares waves or a current, every mooring step
  samples velocity, acceleration, and surface elevation at the line nodes'
  committed positions and holds them for the step.
- **State mirror.** The authoritative state lives in the module instance, and
  `x%states` carries a mirror of it: line node velocities and positions, finite-EI
  cable DOFs, constitutive states (`dl_1`, Syrope), friction anchors, the committed
  boundary kinematics of the coupled ends, and body and rod states.
  Checkpoint/restart, correction iterations, and the framework metadata use the
  mirror; a restart rebuilds the model from the packed deck and the mirror, which
  then overrides the restored input mesh at the coupled ends.
- **Scope.** Correction iterations, quasi-static linearisation, FAST.Farm shared
  moorings (`MooringMod = 5`), line failures, and active line-length control are
  supported. Combinations that are not supported coupled stop with a named error;
  [doc/capabilities.rst](doc/capabilities.rst) lists them.

## Runtime services

- **LAPACK** (`CableDyn_Linalg`): band solves (`DGBSV`, `DGBSVX`,
  `DGBTRF`/`DGBTRS`) for every system; a dense block is solved in band storage.
- **BLAS threads** (`cabledyn_blas.c`): CableDyn's systems are small and banded,
  so the BLAS runs single-threaded unless `CABLEDYN_BLAS_THREADS` says otherwise.
  Windows GNU builds load `openblas.dll` at run time, on the first model
  initialisation, so its thread pool is sized by that policy; a missing runtime
  fails there with a message naming the library.
- **File names** (`CableDyn_PathIO`, `cabledyn_path.c`): names are UTF-8 inside the
  program. On Windows the command line is read from the wide API, reserved device
  names are refused, over-long paths use short or extended-length spellings, and
  each output root holds an exclusive lock for the run. The release executables
  carry `app/utf8_code_page.manifest`, which makes UTF-8 the process code page, so
  the Fortran runtime opens any name as written; a GNU build falls back to 8.3
  short names for characters outside the system ANSI code page.
- **Run-time profile** (`CableDyn_Profile`): with `CABLEDYN_PROFILE` set, the standalone
  driver charges its wall time to the phase that is running. Every time march marks where its
  fluid update, step, checks, output and progress report begin, so a run that stops with an
  error keeps its time in the phase it stopped in. The driver counts the `EI = 0` line steps and
  Newton iterations in `CD_Step_Model`, and reports them with the finite-EI step counters of
  `CableDyn_HermiteCableDynamic`. Unarmed, each mark is one test of a flag.
- **C-ABI handles** (`cabledyn_mutex.c`): the handle registry is guarded by a
  spin-yield lock and deck initialisation by an input lock; operating on a handle
  while closing it from another thread is outside the API contract.

## Source layout

```text
src/
  Foundation:
    CableDyn_Precision.f90     wp = SELECTED_REAL_KIND(15, 307), constants, finiteness tests
    CableDyn_Linalg.f90        LAPACK band solves (DGBSV, DGBSVX, DGBTRF/DGBTRS)
    CableDyn_Conventions.f90   OrcaFlex direction vectors and line-end and body rotations
    CableDyn_Banner.f90        startup banner
    CableDyn_PathIO.f90        UTF-8 arguments and file names, device check, output lock
    cabledyn_path.c            Windows name conversion, reserved devices, lock file
    cabledyn_blas.c            BLAS thread policy; run-time OpenBLAS loading (Windows GNU)
    cabledyn_mutex.c           C-ABI registry and initialisation locks
    cabledyn_crt_locale.c      MinGW-w64 guard for libgfortran's locale restore
    CableDyn_FatalReport.f90   abnormal-end report of the driver (time reached)
    CableDyn_Profile.f90       opt-in run-time profile of the driver (CABLEDYN_PROFILE)
    cabledyn_fatal.c           interrupt, fault and stack-overflow handlers of the driver

  EI = 0 cable path:
    CableDyn_Mesh.f90          connectivity, property, and DOF-partition validation
    CableDyn_CableElem.f90     element force, tangent, tension
    CableDyn_Assemble.f90      global assembly (dense and banded), consistent mass
    CableDyn_Loads.f90         submerged weight, equivalent buoyancy, distributed loads, seabed
    CableDyn_Line.f90          composite multi-section line objects
    CableDyn_Catenary.f90      analytical elastic catenary seed
    CableDyn_Static.f90        static Newton/Armijo with continuation, current, friction
    CableDyn_Damping.f90       axial (BA) damping
    CableDyn_Dynamic.f90       generalised-α step with prescribed motion
    CableDyn_Model.f90         persistent single-line model (hydro, constitutive, friction)
    CableDyn_System.f90        multi-line system with 3-DOF points and coupled exchange

  Axial constitutive models:
    CableDyn_Viscoelastic.f90  series-Kelvin viscoelastic law (ElasticMod 2/3)
    CableDyn_Syrope.f90        polyester working-curve model

  Finite-EI cubic-Hermite path:
    CableDyn_HermiteCable.f90         element force, tangent, mass, curvature
    CableDyn_HermiteCableStatic.f90   static solve, continuation, mesh sequencing
    CableDyn_HermiteCableDynamic.f90  generalised-α dynamics, hydrodynamics, contact,
                                      friction, attachments
    CableDyn_EndConnection.f90        end bending spring, rigid end basis, end moment

  Environment and seabed:
    CableDyn_Hydro.f90         Morison loads, Airy and JONSWAP waves, currents
    CableDyn_WaveSpectra.f90   spectra, spreading, and multi-train seas
    CableDyn_StreamWave.f90    stream-function regular nonlinear waves
    CableDyn_WaveMath.f90      block sine/cosine, exponential and lane sums of the wave kinematics
    CableDyn_Vessel.f90        vessel kinematics, 6-DOF motion, displacement RAOs
    CableDyn_SeabedContact.f90 C1 normal contact and stick-slip friction laws
    CableDyn_Bathymetry.f90    gridded bathymetry

  Objects and analysis:
    CableDyn_RigidKinematics.f90  rigid pose to point kinematics, wrenches, SO(3) advance
    CableDyn_Modal.f90            banded generalised eigenproblem about the static state
    CableDyn_RangeOutput.f90      range graphs and touchdown-point channels

  Secondary Cosserat path (not part of the validated product):
    CableDyn_SO3.f90, CableDyn_Cosserat.f90, CableDyn_CosseratAssemble.f90,
    CableDyn_CosseratStatic.f90, CableDyn_CosseratDynamic.f90, CableDyn_FiniteEIModel.f90
    CableDyn_CosseratEMC.f90   energy-conserving Cosserat integrator (used by tests only)
    CableDyn_FiniteEIStatic.f90  grounded Cosserat static solve (used by tests only)
    CableDyn_HermiteArch.f90   cubic-Hermite arch centreline, converted to a Cosserat
                               position and rotation-vector seed for lazy-wave lines
    CableDyn_AD.f90            second-order automatic differentiation (test reference)

  Coupling:
    CableDyn_OpenFAST.f90            lifecycle shell over CableDyn_System
    CableDyn_OpenFAST_FMF.f90        module-form wrapper of the EI = 0 shell
    CableDyn_OpenFAST_HermiteFMF.f90 module-form lifecycle of one finite-EI cable
    CableDyn_OpenFAST_Aggregate.f90  lines, cables, host bodies and rods, channels
    CableDyn_OpenFAST_Mesh.f90       point-mesh exchange adapter
    CableDyn_OpenFAST_Types.f90      registry-style exchange, parameter, and state types
    CableDyn_Registry.txt            compact registry of those types
    CableDyn_CAPI.f90, CableDyn_CAPI.h  C interface
    cabledyn.def, .exp, .map         exported C-ABI symbols (Windows, macOS, GNU ld)

  Input and drivers:
    CableDyn_DeckDriver.f90    deck parser, standalone routes, bodies and rods, outputs,
                               and deck initialisation for the aggregate and the C API
    CableDyn_Driver.f90        keyword single-line static driver (tests)
    CableDyn_CoupledPlatform.f90  platform-and-mooring static solve (tests)

  openfast/                    OpenFAST module (built only inside an OpenFAST tree):
    CableDyn_OF.f90            CompMooring = 5 module
    CableDyn_Registry.txt      OpenFAST registry; CableDyn_Types.f90 is generated from it
    CableDyn_OF_Driver.f90     standalone driver of the registry module
```

`app/cabledyn.f90` is the standalone driver (see
[doc/driver_format.md](doc/driver_format.md)); a source build names it `cabledyn`,
and the Windows release `CableDyn_driver.exe`. `app/utf8_code_page.manifest` is `app/utf8_code_page.manifest`
its Windows manifest. `integration/openfast/` holds the patch series and scripts
that add CableDyn to a pinned OpenFAST revision. The Windows release links
`CableDyn_driver.exe` and `openfast.exe` statically against the Intel/MSVC
runtimes and the reference LAPACK/BLAS compiled with the same IFX (`openfast.exe`
takes the routines that build omits from the MKL of the OpenFAST solution); they
import only Windows system DLLs.

## Public interfaces

- **Command line**: `CableDyn_driver.exe <deck.dat> <out_root>`, or
  `cabledyn <deck.dat> <out_root>` from a source build (see
  [doc/cli.rst](doc/cli.rst)).
- **Fortran modules**: `CableDyn_Model` (one `EI = 0` line) and `CableDyn_System`
  (several lines with points) expose `Init` / `Step` / query / `End` over the
  coupling boundary; `CableDyn_OpenFAST_HermiteFMF` (one finite-EI cable) and
  `CableDyn_OpenFAST_Aggregate` (a whole deck) expose the module-form `Init` /
  `UpdateStates` / `CalcOutput` / `End`.
- **OpenFAST module** (`Init`, `UpdateStates`, `CalcOutput`, `End`, Jacobians) with
  point meshes as in MoorDyn-F; see [Coupled OpenFAST module](#coupled-openfast-module).
- **C interface** (ABI 1): a create/init/step/close lifecycle with translational
  coupled-point kinematics in and forces and analytic derivative matrices out. ABI
  minor extension 1 (`CableDyn_GetAbiMinor() ≥ 1`) adds in-process object queries
  (object counts and ids, line node and segment values, point, body, and rod
  states, and any output channel through `CableDyn_EvalChannel`), which return
  what the matching output channel reports for the same state. Minor extension 2
  (`≥ 2`) adds the host-coupling calls: `CableDyn_InitDeckAt` (the statics solved
  at the host's coupled-point positions), `CableDyn_SaveState` /
  `CableDyn_RestoreState` (a one-slot deep copy of the model object for outer
  correctors) and `CableDyn_GetCoupledLayout` (see [doc/capi.rst](doc/capi.rst)).
- **Python** (`python/cabledyn`): runs the driver, reads and post-processes
  outputs, edits decks, runs studies, and binds the C interface through ctypes
  with a pinned ABI version. With its object views and snapshots it is designed
  to serve as the scripting back end of tools built on CableDyn, such as batch
  studies or a graphical front end.

## Numerical conventions

- **Precision**: IEEE double, `wp = SELECTED_REAL_KIND(15, 307)`.
- **Linear algebra**: banded LAPACK; dense `DSYGV`/`DSYEV` only for test references
  and small (4 × 4) eigenproblems.
- **Parallelism**: OpenMP element evaluation with deterministic serial scatter.

## References

- Boyer, F., De Nayer, G., Leroyer, A. & Visonneau, M. (2011). Geometrically
  exact Kirchhoff beam theory: application to cable dynamics. *J. Comput.
  Nonlinear Dyn.* **6**(4), 041004.
- Meier, C., Popp, A. & Wall, W. A. (2015). A locking-free finite element
  formulation and reduced models for geometrically exact Kirchhoff rods.
  *Comput. Methods Appl. Mech. Engrg.* **290**, 314–341.
- Chung, J. & Hulbert, G. M. (1993). A time integration algorithm for structural
  dynamics with improved numerical dissipation: the generalized-α method.
  *J. Appl. Mech.* **60**(2), 371–375.
- Simo, J. C. (1985). A finite strain beam formulation. The three-dimensional
  dynamic problem. Part I. *Comput. Methods Appl. Mech. Engrg.* **49**, 55–70.
- Rienecker, M. M. & Fenton, J. D. (1981). A Fourier approximation method for
  steady water waves. *J. Fluid Mech.* **104**, 119–137.

The full list with DOIs is in [doc/references.rst](doc/references.rst).
