<!-- SPDX-License-Identifier: Apache-2.0 -->

# Source module map

This page is for readers of the Fortran source in `src/`. It lists the modules, grouped by
subsystem, with their roles. The programming interfaces for users are documented in {doc}`capi` and
{doc}`api_python`.

CableDyn is a static/dynamic core library (`cabledyn_core`) plus coupling shells, the standalone
driver executable, and a CTest suite. Modules are named `CableDyn_[Function]`; public procedures
follow `CD_[Action]_[Object]`.

## Foundation

```{list-table}
:header-rows: 1
:widths: 34 66

* - Module
  - Role
* - `CableDyn_Precision`
  - the working precision `wp` and shared numeric constants
* - `CableDyn_Banner`
  - the startup identity banner of the standalone driver
* - `CableDyn_Linalg`
  - banded `DGBSV` wrappers (factor / solve / solve-factored) and dense helpers
* - `CableDyn_AD`
  - forward second-order automatic differentiation used to check analytic tangents
* - `CableDyn_RigidKinematics`
  - rigid-body transforms and motion/load mappings shared by the deck and coupling routes
* - `CableDyn_Conventions`
  - the frame, sign, and unit conventions of {doc}`conventions`, in code
```

## Finite-EI cubic-Hermite path

```{list-table}
:header-rows: 1
:widths: 34 66

* - Module
  - Role
* - `CableDyn_HermiteArch`
  - cubic-Hermite centreline evaluation and the arch seed for net-buoyant (lazy-wave) lines
* - `CableDyn_HermiteCable`
  - the 12-DOF position + material-tangent element: closed-form energy, `fint`, `Kt`,
    curvature, and consistent mass
* - `CableDyn_HermiteCableStatic`
  - damped-Newton static solve with EI / buoyancy continuation and mesh sequencing
* - `CableDyn_HermiteCableDynamic`
  - generalised-α dynamics with prescribed motion and the full Morison load set
* - `CableDyn_EndConnection`
  - the `END CONNECTIONS` end-bending spring and the transverse basis for rigid ends
```

## `EI = 0` cable path

```{list-table}
:header-rows: 1
:widths: 34 66

* - Module
  - Role
* - `CableDyn_Mesh`, `CableDyn_CableElem`
  - the positions-only cable mesh and element
* - `CableDyn_Assemble`, `CableDyn_Loads`
  - global internal-force / tangent assembly and distributed loads
* - `CableDyn_Static`, `CableDyn_Catenary`
  - Newton/Armijo static solve and the analytic catenary seed
* - `CableDyn_Dynamic`, `CableDyn_Damping`
  - generalised-α dynamics and MoorDyn axial (`BA`) damping
* - `CableDyn_Viscoelastic`, `CableDyn_Syrope`
  - stateful synthetic-rope constitutive updates, forces, and consistent tangents
* - `CableDyn_Line`, `CableDyn_Model`, `CableDyn_System`
  - composite multi-section lines, the model container, and multi-line systems
```

## Secondary Cosserat path

The rotation-DOF Cosserat rod path (CTest label `cosserat`) is a separate, verified library path;
no deck route runs on it (a finite-EI line with two moving ends runs on the cubic-Hermite route).

```{list-table}
:header-rows: 1
:widths: 34 66

* - Module
  - Role
* - `CableDyn_SO3`
  - SO(3) primitives (exp / log / dexp) for finite rotations
* - `CableDyn_Cosserat`, `CableDyn_CosseratAssemble`
  - the geometrically exact 6-DOF/node rod element and its global assembly
* - `CableDyn_CosseratStatic`
  - Newton/Armijo static solve
* - `CableDyn_CosseratDynamic`, `CableDyn_CosseratEMC`
  - generalised-α dynamics and an energy-conserving integrator option
* - `CableDyn_FiniteEIModel`, `CableDyn_FiniteEIStatic`
  - the Cosserat-path line model and its grounded static equilibrium
```

## Hydrodynamics and contact

```{list-table}
:header-rows: 1
:widths: 34 66

* - Module
  - Role
* - `CableDyn_Hydro`
  - Morison drag / added mass / Froude–Krylov and the wave and current fields
* - `CableDyn_WaveSpectra`
  - wave spectra (JONSWAP, Pierson–Moskowitz/ISSC, Torsethaugen, Ochi–Hubble), directional
    spreading and multi-train seas of the standalone deck
* - `CableDyn_StreamWave`
  - regular nonlinear waves by the stream-function (Fourier) method
* - `CableDyn_WaveMath`
  - the phase sines and cosines and depth exponentials of the wave kinematics, in vectorised
    blocks
* - `CableDyn_Bathymetry`
  - the seabed elevation field
* - `CableDyn_SeabedContact`
  - penalty normal contact and the seabed friction laws (static friction spring, stick-slip spring)
```

## Coupled bodies and platform

```{list-table}
:header-rows: 1
:widths: 34 66

* - Module
  - Role
* - `CableDyn_CoupledPlatform`
  - the 6-DOF platform + mooring coupled static solve
```

## Coupling shells

The exchange contract is in {doc}`coupling_boundary`.

```{list-table}
:header-rows: 1
:widths: 34 66

* - Module
  - Role
* - `CableDyn_OpenFAST`, `CableDyn_OpenFAST_Types`, `CableDyn_OpenFAST_Mesh`
  - the OpenFAST lifecycle shell, registry-style types, and point-mesh mapping
* - `CableDyn_OpenFAST_FMF`, `CableDyn_OpenFAST_HermiteFMF`, `CableDyn_OpenFAST_Aggregate`
  - the module-form lifecycle for the `EI = 0` and finite-EI paths and multi-line aggregation
* - `CableDyn` (`src/openfast/CableDyn_OF.f90`), `CableDyn_Types`
  - the `CompMooring = 5` host module built inside an OpenFAST tree (OpenFAST is maintained by
    NLR, the National Laboratory of the Rockies, formerly NREL) and its registry-generated types
* - `src/openfast/CableDyn_OF_Driver.f90`
  - a standalone driver program for that module, built in the OpenFAST tree for module-level
    regression cases
* - `CableDyn_CAPI`
  - the ISO C binding for CFD and custom coupling
```

## Drivers

```{list-table}
:header-rows: 1
:widths: 34 66

* - Module
  - Role
* - `CableDyn_DeckDriver`
  - the sectioned `.dat` parser, route selection, static/dynamic execution, and output writer
    (see {doc}`driver_format`)
* - `CableDyn_Driver`
  - single-line static solve entry points used by the test suite
* - `CableDyn_Vessel`
  - rigid-body vessel kinematics for `vesselMotion` and `vesselRAO` prescribed motion
* - `CableDyn_RangeOutput`
  - along-arc range graphs (`.Line<L>.range.out`) and the touchdown-point (`TDP<L>`) channels
* - `CableDyn_Modal`
  - modal analysis about the static equilibrium (`nModes`, `<root>.modes.out`)
* - `CableDyn_PathIO`
  - UTF-8 file names converted to the spelling the Fortran runtime opens exactly
* - `CableDyn_FatalReport`
  - the driver's report of an interrupt or a fatal fault, with the simulated time of the last committed step
```

## C helper sources

```{list-table}
:header-rows: 1
:widths: 34 66

* - Source
  - Role
* - `cabledyn_blas.c`
  - the BLAS thread-count policy and, in Windows GNU builds, run-time loading of OpenBLAS
* - `cabledyn_path.c`
  - file-name services for the Fortran I/O layer (the counterpart of `CableDyn_PathIO`)
* - `cabledyn_mutex.c`
  - process-local locks of the C ABI (handle registry and deck initialisation)
* - `cabledyn_crt_locale.c`
  - a guard around the numeric-locale handling of the MinGW-w64 Fortran runtime
* - `cabledyn_fatal.c`
  - the driver's report of an interrupt or a fatal fault with the simulated time reached (the counterpart of `CableDyn_FatalReport`)
```
