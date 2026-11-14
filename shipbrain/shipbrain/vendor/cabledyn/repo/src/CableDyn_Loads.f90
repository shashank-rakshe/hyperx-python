! File: src/CableDyn_Loads.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Loads
  !! External loads for the positions-only EI=0 cable path: submerged weight,
  !! consistent distributed-load assembly, and the penalty seabed normal reaction.
  !! Provides:
  !!   - the submerged weight per unit length
  !!   - the consistent distributed-load assembly
  !!   - the penalty seabed normal force and its tangent
  !!
  !! Conventions match CableDyn_Assemble (column-major nodes(3,n_nodes), 1-based
  !! elem_conn(2,n_elem), node `nd` owns global DOFs `3*nd-2 : 3*nd`). Sign
  !! conventions: gravity acts -z, buoyancy +z, the seabed is the plane z = z_floor with
  !! the C1 normal contact law of CD_Seabed_Normal_Law at penetration z_floor - z and an
  !! upward (+z) penalty reaction. No solver here -- these are pure load builders.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_All_Finite, CD_Is_Finite
  USE CableDyn_SeabedContact, ONLY: CD_Seabed_Normal_Law
  USE CableDyn_Mesh, ONLY: CD_Validate_Connectivity
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Submerged_Weight
  PUBLIC :: CD_Equivalent_Buoyant_Section
  PUBLIC :: CD_Assemble_Distributed_Load
  PUBLIC :: CD_Seabed_Penalty_Load

  ! CD_Seabed_Penalty_Load takes the per-node penalty stiffness k_n as either a
  ! scalar (uniform line) or an (n_nodes,) array -- a composite line whose touchdown
  ! nodes have different tributary diameter*segment_length gives each contact node
  ! its own stiffness.
  INTERFACE CD_Seabed_Penalty_Load
    MODULE PROCEDURE seabed_penalty_uniform
    MODULE PROCEDURE seabed_penalty_pernode
  END INTERFACE CD_Seabed_Penalty_Load

CONTAINS

  SUBROUTINE CD_Submerged_Weight(mass_per_length, diameter, rho_water, gravity, w, ErrStat, ErrMsg)
    !! Per-element net-downward submerged weight per unstretched metre [N/m]:
    !!   w = (mass_per_length - rho_water * pi/4 * diameter^2) * gravity.
    !! Returned with its physical sign (a net-buoyant section gives w < 0); whether
    !! to reject buoyancy is a solver-path decision, not a load-assembly one, so
    !! this routine does not fail closed on w <= 0.
    REAL(wp), INTENT(IN)  :: mass_per_length(:)   !! dry mass per unstretched metre [kg/m] (>= 0)
    REAL(wp), INTENT(IN)  :: diameter(:)          !! hydrodynamic diameter [m] (> 0)
    REAL(wp), INTENT(IN)  :: rho_water            !! water density [kg/m^3] (> 0)
    REAL(wp), INTENT(IN)  :: gravity              !! gravitational acceleration [m/s^2] (> 0)
    REAL(wp), INTENT(OUT) :: w(:)                 !! submerged weight per length [N/m] (n_elem)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER  :: n_elem, e
    REAL(wp), PARAMETER :: QUARTER_PI = 0.785398163397448309616_wp   ! pi/4

    w = CD_ZERO
    ErrStat = 0
    ErrMsg = ''
    n_elem = SIZE(mass_per_length)
    IF (SIZE(diameter) /= n_elem .OR. SIZE(w) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'mass_per_length, diameter, w must share shape (n_elem)')
      RETURN
    END IF
    IF (.NOT. scalar_ok(rho_water) .OR. rho_water <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'rho_water must be finite and positive')
      RETURN
    END IF
    IF (.NOT. scalar_ok(gravity) .OR. gravity <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(mass_per_length) .OR. ANY(mass_per_length < CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'mass_per_length must be finite and non-negative')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(diameter) .OR. ANY(diameter <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'diameter must be finite and positive')
      RETURN
    END IF

    DO e = 1, n_elem
      w(e) = (mass_per_length(e) - rho_water*QUARTER_PI*diameter(e)**2)*gravity
    END DO
  END SUBROUTINE CD_Submerged_Weight

  SUBROUTINE CD_Equivalent_Buoyant_Section(submerged_weight, diameter, rho_water, gravity, mass_per_length, &
                                           ErrStat, ErrMsg)
    !! Convert an equivalent buoyant cable section into the same per-element
    !! properties used everywhere else in the EI=0 line path.
    !!
    !! submerged_weight is the target net DOWNWARD submerged weight per unstretched
    !! metre [N/m]. Use a negative value for an equivalent buoyant section. The
    !! returned dry mass per length satisfies
    !!   CD_Submerged_Weight(mass_per_length, diameter, rho_water, gravity) = submerged_weight.
    REAL(wp), INTENT(IN) :: submerged_weight(:)   !! target net downward submerged weight [N/m]
    REAL(wp), INTENT(IN) :: diameter(:)           !! equivalent hydrodynamic diameter [m]
    REAL(wp), INTENT(IN) :: rho_water             !! water density [kg/m^3] (> 0)
    REAL(wp), INTENT(IN) :: gravity               !! gravitational acceleration [m/s^2] (> 0)
    REAL(wp), INTENT(OUT) :: mass_per_length(:)   !! equivalent dry mass per length [kg/m]
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n_elem, e
    REAL(wp), PARAMETER :: QUARTER_PI = 0.785398163397448309616_wp

    mass_per_length = CD_ZERO
    ErrStat = 0
    ErrMsg = ''
    n_elem = SIZE(submerged_weight)
    IF (SIZE(diameter) /= n_elem .OR. SIZE(mass_per_length) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'submerged_weight, diameter, mass_per_length must share shape')
      RETURN
    END IF
    IF (.NOT. scalar_ok(rho_water) .OR. rho_water <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'rho_water must be finite and positive')
      RETURN
    END IF
    IF (.NOT. scalar_ok(gravity) .OR. gravity <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(submerged_weight)) THEN
      CALL fail(ErrStat, ErrMsg, 'submerged_weight must be finite')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(diameter) .OR. ANY(diameter <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'diameter must be finite and positive')
      RETURN
    END IF

    DO e = 1, n_elem
      mass_per_length(e) = rho_water*QUARTER_PI*diameter(e)**2 + submerged_weight(e)/gravity
      IF (.NOT. CD_Is_Finite(mass_per_length(e)) .OR. mass_per_length(e) < CD_ZERO) THEN
        mass_per_length = CD_ZERO
        CALL fail(ErrStat, ErrMsg, 'equivalent section would require negative dry mass per length')
        RETURN
      END IF
    END DO
  END SUBROUTINE CD_Equivalent_Buoyant_Section

  SUBROUTINE CD_Assemble_Distributed_Load(elem_conn, l0, load_per_length, f, ErrStat, ErrMsg)
    !! Assemble the consistent nodal force from a per-element spatial force density.
    !! Each element contributes ``0.5 * L0 * load_per_length(:,e)`` to BOTH its end
    !! nodes (the lumped consistent load of a 2-node linear element). n_nodes is
    !! taken from ``f``'s shape. A gravity load is this with
    !! ``load_per_length(:,e) = [0, 0, -w(e)]``.
    INTEGER, INTENT(IN)  :: elem_conn(:, :)        !! (2, n_elem), 1-based
    REAL(wp), INTENT(IN)  :: l0(:)                  !! (n_elem) unstretched lengths (> 0)
    REAL(wp), INTENT(IN)  :: load_per_length(:, :)  !! (3, n_elem) force density [N/m]
    REAL(wp), INTENT(OUT) :: f(:)                   !! (3 n_nodes) consistent nodal load
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER  :: n_nodes, n_elem, e, a, b, ia, ib
    REAL(wp) :: share(3)

    f = CD_ZERO
    ErrStat = 0
    ErrMsg = ''
    IF (SIZE(elem_conn, 1) /= 2) THEN
      CALL fail(ErrStat, ErrMsg, 'elem_conn must have shape (2, n_elem)')
      RETURN
    END IF
    IF (MOD(SIZE(f), 3) /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'f must have shape (3 n_nodes)')
      RETURN
    END IF
    n_nodes = SIZE(f)/3
    n_elem = SIZE(elem_conn, 2)
    CALL CD_Validate_Connectivity(elem_conn, n_nodes, n_elem, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    IF (SIZE(l0) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'l0 must have shape (n_elem)')
      RETURN
    END IF
    IF (SIZE(load_per_length, 1) /= 3 .OR. SIZE(load_per_length, 2) /= n_elem) THEN
      CALL fail(ErrStat, ErrMsg, 'load_per_length must have shape (3, n_elem)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'l0 must be finite and positive')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(load_per_length)) THEN
      CALL fail(ErrStat, ErrMsg, 'load_per_length must be finite')
      RETURN
    END IF

    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      share = 0.5_wp*l0(e)*load_per_length(:, e)
      ia = 3*a - 2
      ib = 3*b - 2
      f(ia:ia + 2) = f(ia:ia + 2) + share
      f(ib:ib + 2) = f(ib:ib + 2) + share
    END DO
  END SUBROUTINE CD_Assemble_Distributed_Load

  SUBROUTINE seabed_penalty_uniform(nodes, k_n, z_floor, f, k_resid, ErrStat, ErrMsg)
    !! Penalty seabed normal reaction with a UNIFORM (scalar) per-node stiffness.
    !! Generic via CD_Seabed_Penalty_Load; see seabed_assemble for the physics +
    !! the active-set rationale.
    REAL(wp), INTENT(IN)  :: nodes(:, :)        !! (3, n_nodes)
    REAL(wp), INTENT(IN)  :: k_n                !! uniform penalty stiffness [N/m] (> 0)
    REAL(wp), INTENT(IN)  :: z_floor            !! seabed plane elevation [m]
    REAL(wp), INTENT(OUT) :: f(:)               !! (3 n_nodes) contact force
    REAL(wp), INTENT(OUT) :: k_resid(:, :)      !! (3 n_nodes, 3 n_nodes) -d(f)/dq
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp), ALLOCATABLE :: kn(:)

    f = CD_ZERO
    k_resid = CD_ZERO
    ErrStat = 0
    ErrMsg = ''
    IF (.NOT. scalar_ok(k_n) .OR. k_n <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'k_n must be finite and positive')
      RETURN
    END IF
    ALLOCATE (kn(SIZE(nodes, 2)), source=k_n)   ! broadcast the scalar to per-node
    CALL seabed_assemble(nodes, kn, z_floor, f, k_resid, ErrStat, ErrMsg)
  END SUBROUTINE seabed_penalty_uniform

  SUBROUTINE seabed_penalty_pernode(nodes, k_n, z_floor, f, k_resid, ErrStat, ErrMsg)
    !! Penalty seabed normal reaction with a PER-NODE (n_nodes,) stiffness array --
    !! the composite-line case (each touchdown node its own tributary stiffness).
    !! Generic via CD_Seabed_Penalty_Load.
    REAL(wp), INTENT(IN)  :: nodes(:, :)        !! (3, n_nodes)
    REAL(wp), INTENT(IN)  :: k_n(:)             !! (n_nodes) per-node stiffness [N/m] (> 0)
    REAL(wp), INTENT(IN)  :: z_floor            !! seabed plane elevation [m]
    REAL(wp), INTENT(OUT) :: f(:)               !! (3 n_nodes) contact force
    REAL(wp), INTENT(OUT) :: k_resid(:, :)      !! (3 n_nodes, 3 n_nodes) -d(f)/dq
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    f = CD_ZERO
    k_resid = CD_ZERO
    CALL seabed_assemble(nodes, k_n, z_floor, f, k_resid, ErrStat, ErrMsg)
  END SUBROUTINE seabed_penalty_pernode

  SUBROUTINE seabed_assemble(nodes, k_n, z_floor, f, k_resid, ErrStat, ErrMsg)
    !! Shared core: penalty seabed reaction with a per-node stiffness k_n(n_nodes).
    !! Per node i with elevation z_i = nodes(3,i) and signed gap g_i = z_floor - z_i,
    !! the normal reaction follows the shared C1 touchdown law from
    !! CableDyn_SeabedContact.
    !! ``f`` is the contact force to ADD to the external load. ``k_resid`` is the
    !! residual-Jacobian contribution -d(f)/dq for R = f_int - f_ext - f_contact
    !! (so the caller adds it to K_t).
    REAL(wp), INTENT(IN)  :: nodes(:, :)
    REAL(wp), INTENT(IN)  :: k_n(:)
    REAL(wp), INTENT(IN)  :: z_floor
    REAL(wp), INTENT(OUT) :: f(:)
    REAL(wp), INTENT(OUT) :: k_resid(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER  :: n_nodes, i, iz
    REAL(wp) :: gap, tangent

    f = CD_ZERO
    k_resid = CD_ZERO
    ErrStat = 0
    ErrMsg = ''
    IF (SIZE(nodes, 1) /= 3) THEN
      CALL fail(ErrStat, ErrMsg, 'nodes must have shape (3, n_nodes)')
      RETURN
    END IF
    n_nodes = SIZE(nodes, 2)
    IF (SIZE(f) /= 3*n_nodes .OR. SIZE(k_resid, 1) /= 3*n_nodes &
        .OR. SIZE(k_resid, 2) /= 3*n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'f / k_resid shapes inconsistent with nodes')
      RETURN
    END IF
    IF (SIZE(k_n) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'k_n must be a scalar or have shape (n_nodes)')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(nodes)) THEN
      CALL fail(ErrStat, ErrMsg, 'node coordinates must be finite')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(k_n) .OR. ANY(k_n <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'k_n must be finite and positive')
      RETURN
    END IF
    IF (.NOT. scalar_ok(z_floor)) THEN
      CALL fail(ErrStat, ErrMsg, 'z_floor must be finite')
      RETURN
    END IF

    DO i = 1, n_nodes
      gap = z_floor - nodes(3, i)        ! signed gap; > 0 strictly below the floor
      iz = 3*i                           ! z DOF of node i (1-based)
      CALL CD_Seabed_Normal_Law(gap, k_n(i), f(iz), tangent)
      k_resid(iz, iz) = tangent
    END DO
  END SUBROUTINE seabed_assemble

  ! --------------------------------------------------------------------------- !
  ! private helpers (topology validation is shared via CableDyn_Mesh)           !
  ! --------------------------------------------------------------------------- !

  LOGICAL FUNCTION scalar_ok(x) RESULT(ok)
    REAL(wp), INTENT(IN) :: x
    ok = CD_Is_Finite(x)
  END FUNCTION scalar_ok

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    ErrStat = 1
    ErrMsg = 'CableDyn_Loads: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Loads
