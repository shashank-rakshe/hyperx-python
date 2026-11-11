.. SPDX-License-Identifier: Apache-2.0

Coupling: OpenFAST and CFD
==========================

CableDyn is one caller-agnostic solver core behind a single coupling boundary, with a thin
shell per target. The core knows nothing about its caller; that separation is the central
architectural decision. The formal contract — kinematics in, loads out, with frames, units,
and cadence — is specified in :doc:`coupling_boundary`.

OpenFAST module (``CompMooring = 5``)
-------------------------------------

CableDyn has a mooring module for OpenFAST v5 (OpenFAST is maintained by NLR, the National
Laboratory of the Rockies, formerly NREL), selected with ``CompMooring = 5``, that coexists with
stock MoorDyn (``CompMooring = 3``) in an OpenFAST build carrying the CableDyn module. The
IEA-15MW VolturnUS-S UMaine model runs coupled end to end with ``EI = 0`` catenary moorings and
a finite-EI dynamic power cable in one deck (:doc:`tutorial_openfast`; the comparisons are in
:doc:`validation`).

At initialisation the module announces itself the standard OpenFAST way, identifies the parsed deck
inventory, and prints an unconditional converged-static fairlead report for every line. The report
includes effective tension, the global force on the fairlead, and the inclination, declination, and
azimuth of the line end as defined in :doc:`conventions`. It is independent of the deck ``OUTPUTS``
selection, while requested channels are printed in a separate block. This makes the active model and
angle convention visible directly in an OpenFAST run log. The module covers MoorDyn-F's coupled
integration surface: coupled time-domain analysis at a 0.1 s CableDyn step by default (with deck
``dtM`` control), a nonzero initial platform displacement (``PtfmInit``), glue correction iterations
(``NumCrctn > 0``), SeaState wave/current kinematics on the moorings and finite-EI cables,
checkpoint-restart, linearisation with the line dynamics (the line, cable and twist states, as
MoorDyn-F's; see :doc:`openfast`), FAST.Farm farm-level shared moorings
(``Mod_SharedMooring = 5``), coupled ``Rigid6`` 6-DOF rigid bodies (buoyancy,
``C33``/``C44``/``C55`` hydrostatic restoring, restart state, and SeaState drag / Froude-Krylov /
added-mass), including MoorDyn-F's coupled pinned bodies (``CoupledPinned``, force only), coupled
``Point3`` buoys (buoyancy and SeaState drag / Froude-Krylov / added-mass), and
coupled rigid rods with host-driven endpoints, correction rewind, checkpoint state, and two-point
Gauss SeaState sampling, including MoorDyn-F's coupled pinned rods (``CoupledPinned``, force only)
and rods pinned to a fixed point.

The input/output Jacobian is a partial derivative in both kinds of run. During an ordinary
nonlinear OpenFAST run, CableDyn returns the direct-feedthrough derivative at fixed committed
internal state, which is the derivative OpenFAST's algebraic input/output solve requires. During
formal linearisation (``Linearize = True``) the line and cable degrees of freedom, and the twist
angles of a line restrained in torsion, are continuous states, and ``A``, ``B``, ``C`` and ``D``
are partial derivatives of the line dynamics at the operating point; the static mooring stiffness
is their zero-frequency reduction ``D − C A⁻¹ B``, not a derivative CableDyn returns. Changing
``NumCrctn`` does not change either contract.

.. admonition:: Remaining integration surface
   :class: warning

   Outside that surface the module fails closed — a clear fatal error, never a silent wrong
   answer — on:

   - any ``CONTROL`` section in FAST.Farm (active ServoDyn control, ``CableDeltaL``, of
     ``EI = 0`` lines and finite-EI cables is supported in a single-turbine model), a
     command outside MoorDyn-F's bounds or one that would make a controlled segment
     non-positive, and ``CONTROL`` of a finite-EI cable under ``False alpha_force_blend``,
   - coupled ``Rigid6`` bodies and rods in a FAST.Farm deck,
   - a deck with both bodies (Rigid6 or Point3) and rods, a rod fixed to a body included,
   - deck ``waves``/``wavetrain`` OPTIONS (the host SeaState supplies the waves), and a deck
     ``current`` except as a steady current on a single-turbine, pure ``EI = 0`` deck without
     Rigid6 bodies or rods in a SeaState without waves or current (a WaterKin ``CurrentMod 1``
     table remains available), and
   - fluid-source combinations that the nodewise SeaState field cannot separate without double
     counting.

   ``Point3`` buoyancy and fluid loads are supported, but an imported restoring model that is not
   represented by those terms remains rejected. See :doc:`capabilities` for the route matrix. For
   an unsupported workflow, use stock MoorDyn (``CompMooring = 3``) in the same binary.

Standalone binaries
~~~~~~~~~~~~~~~~~~~~

The Windows release carries ``CableDyn_driver.exe`` and a CableDyn-enabled
``openfast.exe`` as non-OpenMP, statically linked x64 files. Neither needs an adjacent
compiler, BLAS, OpenMP, or C/C++ runtime DLL. A model can still request an external
ServoDyn controller such as ``DISCON.dll``; that is a model-specific plugin rather than a
dependency of CableDyn or ``openfast.exe``. The release build is described in
:doc:`installation`; end-user setup and a complete coupled walkthrough are in :doc:`openfast`.
The release compiler is pinned to IFX 2025.3 or newer, and both CableDyn and stock-MoorDyn
OpenFAST paths must pass separate smoke cases. A successful CableDyn case alone does not qualify
the executable as a drop-in OpenFAST replacement. The packaged OpenFAST executable is built from
the upstream Visual Studio ``Release|x64`` solution target (the same build family used for the
official Windows release), with CableDyn installed as a normal solution module; it is not a
CMake-built approximation of that executable.

C binding (``CableDyn_CAPI``)
-----------------------------

The second shell is a standalone C-style binding (``CableDyn_CAPI``), couplable to CFD solvers
such as STAR-CCM+ and OpenFOAM the way MoorDyn-C is. It consumes the same coupling boundary as
the OpenFAST shell, so the two shells are one core with a thin adapter per target, not two
codebases.

The coupling boundary
---------------------

Both shells pass coupled-point kinematics and nodal or point fluid fields in and structural
loads out across one defined boundary, so the line's hydrodynamic response is computed
identically regardless of caller. Loads follow the sign convention of :doc:`conventions` (force
exerted by the cable on the coupled object, global frame). The full contract is in
:doc:`coupling_boundary`.

For user-facing setup rather than architecture, use :doc:`openfast` (coupled execution),
:doc:`capi` (embedding), or :doc:`python` (automation and in-process access).
