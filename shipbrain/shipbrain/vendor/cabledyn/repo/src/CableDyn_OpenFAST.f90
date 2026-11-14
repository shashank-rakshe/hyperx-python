! File: src/CableDyn_OpenFAST.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_OpenFAST
  !! OpenFAST-facing lifecycle shell for CableDyn. This module corresponds to
  !! doc/coupling_boundary.md and deliberately keeps the first integration
  !! surface thin, stable, and Fortran-native, delegating ownership to CableDyn_System.
  !! Registry-derived OpenFAST types can wrap this shell without coupling directly to
  !! lower-level line internals.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Model, ONLY: CD_ModelType
  USE CableDyn_RigidKinematics, ONLY: CD_Rigid_Points_From_Body, CD_Rigid_Wrench_From_Point_Loads, CD_RIGID_OK
  USE CableDyn_System, ONLY: CD_SystemType, CD_SystemPointType, CD_LineEndpointBinding, &
                             CD_Init_System_From_Models, CD_Init_System_From_Points, &
                             CD_End_System, CD_System_NLines, CD_System_NCoupledDOF, CD_System_NPoints, &
                             CD_Get_System_CoupledMotion, CD_Update_System_CoupledMotion, &
                             CD_Update_System_Point_States, CD_Update_System_Point_Fluid_Fields, &
                             CD_Step_System, CD_Step_System_DynamicPoints, CD_Calc_System_CoupledLoads, &
                             CD_Recompute_System_Acceleration, &
                             CD_Calc_System_CoupledKinematicDerivatives, &
                             CD_Calc_System_CoupledAccelDerivative, &
                             CD_System_Is_Initialized, CD_System_Has_DynamicPoints, CD_SYSTEM_OK, CD_SYSTEM_BADINPUT, &
                             CD_SYSTEM_SOLVEFAIL, CD_SYSTEM_NOT_INITIALIZED, CD_SYSTEM_ALLOCFAIL
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_FAST_ModuleType
  PUBLIC :: CD_FAST_Init_From_Models
  PUBLIC :: CD_FAST_Init_From_Points
  PUBLIC :: CD_FAST_UpdateStates
  PUBLIC :: CD_FAST_UpdateStates_From_Body
  PUBLIC :: CD_FAST_UpdatePointFluidFields
  PUBLIC :: CD_FAST_Step
  PUBLIC :: CD_FAST_CalcOutput
  PUBLIC :: CD_FAST_CalcBodyWrench
  PUBLIC :: CD_FAST_CalcOutputDerivatives
  PUBLIC :: CD_FAST_End
  PUBLIC :: CD_FAST_NCoupledDOF
  PUBLIC :: CD_FAST_NPoints
  PUBLIC :: CD_FAST_NLines
  PUBLIC :: CD_FAST_GetCoupledMotion
  PUBLIC :: CD_FAST_IsInitialized

  INTEGER, PARAMETER, PUBLIC :: CD_FAST_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_FAST_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_FAST_SOLVEFAIL = 2
  INTEGER, PARAMETER, PUBLIC :: CD_FAST_NOT_INITIALIZED = 3
  INTEGER, PARAMETER, PUBLIC :: CD_FAST_ALLOCFAIL = 4

  TYPE :: CD_FAST_ModuleType
    !! Minimal OpenFAST module state holder. The system member owns line models,
    !! point maps, and aggregate coupled motion/load exchange.
    TYPE(CD_SystemType) :: system
    REAL(wp), ALLOCATABLE :: q_work(:)
    REAL(wp), ALLOCATABLE :: v_work(:)
    REAL(wp), ALLOCATABLE :: a_work(:)
    REAL(wp), ALLOCATABLE :: load_work(:)
    ! Step-entry copy of the system point store, reused across steps: a failed
    ! dynamic-point step restores the points to it (the prescribed t+dt kinematics are
    ! committed to the store before the step's own rollback snapshot is taken).
    TYPE(CD_SystemPointType), ALLOCATABLE :: points_entry(:)
  END TYPE CD_FAST_ModuleType

CONTAINS

  SUBROUTINE CD_FAST_Init_From_Models(self, models, ErrStat, ErrMsg, coupled_dof_map)
    !! Initialize from already-built line models and an optional raw coupled map.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    TYPE(CD_ModelType), INTENT(IN) :: models(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: coupled_dof_map(:)

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL CD_Init_System_From_Models(self%system, models, es, em, coupled_dof_map=coupled_dof_map)
    CALL map_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_Init_From_Models

  SUBROUTINE CD_FAST_Init_From_Points(self, models, points, bindings, ErrStat, ErrMsg)
    !! Initialize from product-facing points and line endpoint bindings.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    TYPE(CD_ModelType), INTENT(IN) :: models(:)
    TYPE(CD_SystemPointType), INTENT(IN) :: points(:)
    TYPE(CD_LineEndpointBinding), INTENT(IN) :: bindings(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL CD_Init_System_From_Points(self%system, models, points, bindings, es, em)
    CALL map_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_Init_From_Points

  SUBROUTINE CD_FAST_UpdateStates(self, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg, output_probe)
    !! Update coupled kinematics and recompute internal accelerations. output_probe=.TRUE.
    !! is reserved for a caller that owns a full-state mirror: it overlays prescribed
    !! endpoints only, freezes committed interiors, and requires caller restoration.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: output_probe

    INTEGER :: es
    TYPE(CD_SystemType) :: old_system
    LOGICAL :: is_output_probe
    CHARACTER(1024) :: em

    is_output_probe = .FALSE.
    IF (PRESENT(output_probe)) is_output_probe = output_probe
    IF (.NOT. is_output_probe) old_system = self%system
    CALL CD_Update_System_CoupledMotion(self%system, q_coupled, v_coupled, a_coupled, es, em, &
                                        caller_owns_rollback=is_output_probe)
    IF (es /= CD_SYSTEM_OK) THEN
      IF (.NOT. is_output_probe) self%system = old_system
      CALL map_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ! An output-probe call is the OpenFAST CalcOutput overlay: only prescribed
    ! endpoint q/v/a changes while all interior state, including its committed
    ! generalized-alpha acceleration, must remain frozen. Recomputing every interior
    ! acceleration here was both contrary to that direct-feedthrough contract and the
    ! dominant coupled-runtime cost. The ordinary public update remains fully atomic
    ! and retains the historical acceleration re-derivation.
    IF (.NOT. is_output_probe) THEN
      CALL CD_Recompute_System_Acceleration(self%system, es, em)
      IF (es /= CD_SYSTEM_OK) self%system = old_system
    ELSE
      es = CD_SYSTEM_OK
      em = ''
    END IF
    CALL map_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_UpdateStates

  SUBROUTINE CD_FAST_UpdateStates_From_Body(self, body_q, body_v, body_a, offsets_body, ErrStat, ErrMsg)
    !! Update coupled point kinematics from one rigid-body platform state. This is
    !! the common OpenFAST glue operation for fairlead points attached to a moving
    !! platform; offsets_body columns are fairlead offsets in the platform frame.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: body_q(6), body_v(6), body_a(6)
    REAL(wp), INTENT(IN) :: offsets_body(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, es
    CHARACTER(1024) :: em

    ErrStat = CD_FAST_OK
    ErrMsg = ''
    IF (SIZE(offsets_body, 1) /= 3) THEN
      ErrStat = CD_FAST_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST: offsets_body must have shape (3,n)'
      RETURN
    END IF
    n = 3*SIZE(offsets_body, 2)
    IF (CD_System_NCoupledDOF(self%system, es, em) /= n .OR. es /= CD_SYSTEM_OK) THEN
      CALL map_status(es, em, ErrStat, ErrMsg)
      IF (ErrStat == CD_FAST_OK) THEN
        ErrStat = CD_FAST_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST: rigid-body point count does not match coupled DOF count'
      END IF
      RETURN
    END IF
    CALL ensure_fast_workspace(self, n, need_load=.FALSE., ErrStat=ErrStat, ErrMsg=ErrMsg)
    IF (ErrStat /= CD_FAST_OK) RETURN
    CALL CD_Rigid_Points_From_Body(body_q, body_v, body_a, offsets_body, &
                                   self%q_work(1:n), self%v_work(1:n), self%a_work(1:n), es, em)
    IF (es /= CD_RIGID_OK) THEN
      ErrStat = CD_FAST_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST: '//TRIM(em)
      RETURN
    END IF
    CALL CD_FAST_UpdateStates(self, self%q_work(1:n), self%v_work(1:n), self%a_work(1:n), ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_UpdateStates_From_Body

  SUBROUTINE CD_FAST_UpdatePointFluidFields(self, fluid_velocity, fluid_acceleration, waterline_z, fluid_density, &
                                            ErrStat, ErrMsg)
    !! Update lumped point-fluid kinematics for Free/Connect point hydro.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: fluid_velocity(:, :), fluid_acceleration(:, :), waterline_z(:), fluid_density
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL CD_Update_System_Point_Fluid_Fields(self%system, fluid_velocity, fluid_acceleration, waterline_z, &
                                             fluid_density, es, em)
    CALL map_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_UpdatePointFluidFields

  SUBROUTINE CD_FAST_Step(self, dt, q_coupled, v_coupled, a_coupled, converged, stalled, n_iter, ErrStat, ErrMsg)
    !! Advance the wrapped CableDyn system by one dynamic step using OpenFAST
    !! coupled kinematics as prescribed point motion.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: dt
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    LOGICAL :: has_dynamic
    CHARACTER(1024) :: em

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    has_dynamic = CD_System_Has_DynamicPoints(self%system, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      CALL map_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    IF (has_dynamic) THEN
      ! State atomicity on failure: the prescribed t+dt kinematics are committed to the
      ! point store before the dynamic-point step snapshots it, so the step's own
      ! rollback would restore those t+dt values; restore the step-entry copy instead.
      IF (ALLOCATED(self%system%points)) self%points_entry = self%system%points
      CALL CD_Update_System_Point_States(self%system, q_coupled, v_coupled, a_coupled, es, em)
      IF (es == CD_SYSTEM_OK) CALL CD_Step_System_DynamicPoints(self%system, dt, converged, stalled, n_iter, es, em)
      IF (es /= CD_SYSTEM_OK .AND. ALLOCATED(self%system%points)) self%system%points = self%points_entry
    ELSE
      CALL CD_Step_System(self%system, dt, q_coupled, v_coupled, a_coupled, converged, stalled, n_iter, es, em)
      ! CD_Step_System advances only the lines; commit the prescribed kinematics to the
      ! point store as well, so point queries and Point<N>p* channels report the
      ! committed step rather than the Init positions. It cannot fail after a
      ! successful step (same shape and finiteness checks, no Free/Connect points).
      IF (es == CD_SYSTEM_OK .AND. ALLOCATED(self%system%points)) &
        CALL CD_Update_System_Point_States(self%system, q_coupled, v_coupled, a_coupled, es, em)
    END IF
    CALL map_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_Step

  SUBROUTINE CD_FAST_CalcOutput(self, coupled_loads, ErrStat, ErrMsg)
    !! Calculate aggregate coupled loads for OpenFAST from the current system state.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(OUT) :: coupled_loads(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    coupled_loads = 0.0_wp
    CALL CD_Calc_System_CoupledLoads(self%system, coupled_loads, es, em)
    CALL map_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_CalcOutput

  SUBROUTINE CD_FAST_CalcBodyWrench(self, body_q, offsets_body, body_wrench, ErrStat, ErrMsg)
    !! Calculate aggregate coupled loads and map them to a single rigid-body
    !! platform wrench [Fx,Fy,Fz,Mx,My,Mz] in global components.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: body_q(6)
    REAL(wp), INTENT(IN) :: offsets_body(:, :)
    REAL(wp), INTENT(OUT) :: body_wrench(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, es
    CHARACTER(1024) :: em

    body_wrench = 0.0_wp
    ErrStat = CD_FAST_OK
    ErrMsg = ''
    IF (SIZE(offsets_body, 1) /= 3) THEN
      ErrStat = CD_FAST_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST: offsets_body must have shape (3,n)'
      RETURN
    END IF
    n = 3*SIZE(offsets_body, 2)
    IF (CD_System_NCoupledDOF(self%system, es, em) /= n .OR. es /= CD_SYSTEM_OK) THEN
      CALL map_status(es, em, ErrStat, ErrMsg)
      IF (ErrStat == CD_FAST_OK) THEN
        ErrStat = CD_FAST_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST: rigid-body point count does not match coupled DOF count'
      END IF
      RETURN
    END IF
    CALL ensure_fast_workspace(self, n, need_load=.TRUE., ErrStat=ErrStat, ErrMsg=ErrMsg)
    IF (ErrStat /= CD_FAST_OK) RETURN
    CALL CD_FAST_CalcOutput(self, self%load_work(1:n), ErrStat, ErrMsg)
    IF (ErrStat /= CD_FAST_OK) RETURN
    CALL CD_Rigid_Wrench_From_Point_Loads(body_q, offsets_body, self%load_work(1:n), body_wrench, es, em)
    IF (es /= CD_RIGID_OK) THEN
      ErrStat = CD_FAST_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST: '//TRIM(em)
    END IF
  END SUBROUTINE CD_FAST_CalcBodyWrench

  SUBROUTINE CD_FAST_CalcOutputDerivatives(self, q_coupled, v_coupled, a_coupled, eps_fd, loads, &
                                           dload_dq, dload_dv, dload_da, added_mass, ErrStat, ErrMsg)
    !! Calculate coupled loads and output derivative blocks at a supplied coupled
    !! state. The q/v/a derivative blocks are reduced through the line free DOFs
    !! at the model/system layers, and added_mass = -dload/da. eps_fd is retained
    !! for ABI compatibility and is only validated here.
    !!
    !! STATE CONTRACT (explicit): this is an evaluate-AND-SET operation, not a
    !! side-effect-free query. On every exit path the module state is left at the
    !! SUPPLIED (q_coupled, v_coupled, a_coupled) operating point -- the finite-
    !! difference perturbations used to build the derivative blocks are undone, but
    !! the module's PRE-CALL state is NOT preserved. A caller that needs its prior
    !! state must save it before the call and restore it after.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: q_coupled(:), v_coupled(:), a_coupled(:), eps_fd
    REAL(wp), INTENT(OUT) :: loads(:), dload_dq(:, :), dload_dv(:, :), dload_da(:, :), added_mass(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, es
    CHARACTER(1024) :: em

    ErrStat = CD_FAST_OK
    ErrMsg = ''
    loads = 0.0_wp
    dload_dq = 0.0_wp
    dload_dv = 0.0_wp
    dload_da = 0.0_wp
    added_mass = 0.0_wp
    n = SIZE(q_coupled)
    IF (SIZE(v_coupled) /= n .OR. SIZE(a_coupled) /= n .OR. SIZE(loads) /= n .OR. &
        SIZE(dload_dq, 1) /= n .OR. SIZE(dload_dq, 2) /= n .OR. &
        SIZE(dload_dv, 1) /= n .OR. SIZE(dload_dv, 2) /= n .OR. &
        SIZE(dload_da, 1) /= n .OR. SIZE(dload_da, 2) /= n .OR. &
        SIZE(added_mass, 1) /= n .OR. SIZE(added_mass, 2) /= n) THEN
      ErrStat = CD_FAST_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST: derivative arrays must match n_coupled_dof'
      RETURN
    END IF
    IF (.NOT. (eps_fd >= 0.0_wp)) THEN
      ErrStat = CD_FAST_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST: eps_fd must be non-negative'
      RETURN
    END IF

    CALL CD_FAST_UpdateStates(self, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FAST_OK) RETURN
    CALL CD_FAST_CalcOutput(self, loads, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FAST_OK) THEN
      CALL reset_state_to_operating_point()
      RETURN
    END IF
    CALL CD_Calc_System_CoupledKinematicDerivatives(self%system, dload_dq, dload_dv, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      CALL map_status(es, em, ErrStat, ErrMsg)
      CALL reset_state_to_operating_point()
      RETURN
    END IF
    CALL CD_Calc_System_CoupledAccelDerivative(self%system, dload_da, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      CALL map_status(es, em, ErrStat, ErrMsg)
      CALL reset_state_to_operating_point()
      RETURN
    END IF
    added_mass = -dload_da
    CALL CD_FAST_UpdateStates(self, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)

  CONTAINS

    SUBROUTINE reset_state_to_operating_point()
      !! Leave the module at the SUPPLIED (q,v,a) operating point (per the state
      !! contract above), not at the pre-call state.
      CALL CD_FAST_UpdateStates(self, q_coupled, v_coupled, a_coupled, es, em)
    END SUBROUTINE reset_state_to_operating_point
  END SUBROUTINE CD_FAST_CalcOutputDerivatives

  SUBROUTINE CD_FAST_GetCoupledMotion(self, q_coupled, v_coupled, a_coupled, ErrStat, ErrMsg)
    !! Copy current aggregate coupled motion for glue-code diagnostics.
    TYPE(CD_FAST_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: q_coupled(:), v_coupled(:), a_coupled(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    q_coupled = 0.0_wp
    v_coupled = 0.0_wp
    a_coupled = 0.0_wp
    CALL CD_Get_System_CoupledMotion(self%system, q_coupled, v_coupled, a_coupled, es, em)
    CALL map_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_GetCoupledMotion

  SUBROUTINE CD_FAST_End(self, ErrStat, ErrMsg)
    !! Release all system resources owned by the OpenFAST shell.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL CD_End_System(self%system, es, em)
    CALL clear_fast_workspace(self)
    CALL map_status(es, em, ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_End

  INTEGER FUNCTION CD_FAST_NCoupledDOF(self, ErrStat, ErrMsg) RESULT(n)
    !! Return aggregate coupled exchange size.
    TYPE(CD_FAST_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    n = CD_System_NCoupledDOF(self%system, es, em)
    CALL map_status(es, em, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FAST_OK) n = 0
  END FUNCTION CD_FAST_NCoupledDOF

  INTEGER FUNCTION CD_FAST_NPoints(self, ErrStat, ErrMsg) RESULT(n)
    !! Return the number of stored system points. The point fluid-field update is sized by
    !! this count (one column per stored point), which can exceed CD_FAST_NCoupledDOF/3 when
    !! the system has unbound (output-only) Fixed/Coupled points.
    TYPE(CD_FAST_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    n = CD_System_NPoints(self%system, es, em)
    CALL map_status(es, em, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FAST_OK) n = 0
  END FUNCTION CD_FAST_NPoints

  INTEGER FUNCTION CD_FAST_NLines(self, ErrStat, ErrMsg) RESULT(n)
    !! Return number of line models owned by the shell.
    TYPE(CD_FAST_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    n = CD_System_NLines(self%system, es, em)
    CALL map_status(es, em, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FAST_OK) n = 0
  END FUNCTION CD_FAST_NLines

  LOGICAL FUNCTION CD_FAST_IsInitialized(self) RESULT(is_initialized)
    !! Query-only helper for OpenFAST glue tests.
    TYPE(CD_FAST_ModuleType), INTENT(IN) :: self
    is_initialized = CD_System_Is_Initialized(self%system)
  END FUNCTION CD_FAST_IsInitialized

  SUBROUTINE ensure_fast_workspace(self, n, need_load, ErrStat, ErrMsg)
    !! Resize reusable OpenFAST-shell flat-vector workspace without allocating in
    !! repeated body-motion/body-wrench calls once capacity is established.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(IN) :: n
    LOGICAL, INTENT(IN) :: need_load
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: stat
    LOGICAL :: need_state_workspace, need_load_workspace

    ErrStat = CD_FAST_OK
    ErrMsg = ''
    IF (n < 0) THEN
      ErrStat = CD_FAST_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST: workspace size must be non-negative'
      RETURN
    END IF
    need_state_workspace = .NOT. ALLOCATED(self%q_work)
    IF (.NOT. need_state_workspace) need_state_workspace = SIZE(self%q_work) < n
    IF (need_state_workspace) THEN
      IF (ALLOCATED(self%q_work)) DEALLOCATE (self%q_work)
      IF (ALLOCATED(self%v_work)) DEALLOCATE (self%v_work)
      IF (ALLOCATED(self%a_work)) DEALLOCATE (self%a_work)
      ALLOCATE (self%q_work(n), self%v_work(n), self%a_work(n), STAT=stat)
      IF (stat /= 0) THEN
        CALL clear_fast_workspace(self)
        ErrStat = CD_FAST_ALLOCFAIL
        ErrMsg = 'CableDyn_OpenFAST: workspace allocation failed'
        RETURN
      END IF
    END IF
    IF (n > 0) THEN
      self%q_work(1:n) = 0.0_wp
      self%v_work(1:n) = 0.0_wp
      self%a_work(1:n) = 0.0_wp
    END IF
    IF (need_load) THEN
      need_load_workspace = .NOT. ALLOCATED(self%load_work)
      IF (.NOT. need_load_workspace) need_load_workspace = SIZE(self%load_work) < n
      IF (need_load_workspace) THEN
        IF (ALLOCATED(self%load_work)) DEALLOCATE (self%load_work)
        ALLOCATE (self%load_work(n), STAT=stat)
        IF (stat /= 0) THEN
          CALL clear_fast_workspace(self)
          ErrStat = CD_FAST_ALLOCFAIL
          ErrMsg = 'CableDyn_OpenFAST: load workspace allocation failed'
          RETURN
        END IF
      END IF
      IF (n > 0) self%load_work(1:n) = 0.0_wp
    END IF
  END SUBROUTINE ensure_fast_workspace

  SUBROUTINE clear_fast_workspace(self)
    !! Release reusable shell work arrays. Idempotent and called from CD_FAST_End.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self

    IF (ALLOCATED(self%q_work)) DEALLOCATE (self%q_work)
    IF (ALLOCATED(self%v_work)) DEALLOCATE (self%v_work)
    IF (ALLOCATED(self%a_work)) DEALLOCATE (self%a_work)
    IF (ALLOCATED(self%load_work)) DEALLOCATE (self%load_work)
    IF (ALLOCATED(self%points_entry)) DEALLOCATE (self%points_entry)
  END SUBROUTINE clear_fast_workspace

  SUBROUTINE map_status(SystemStat, SystemMsg, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: SystemStat
    CHARACTER(*), INTENT(IN) :: SystemMsg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    SELECT CASE (SystemStat)
    CASE (CD_SYSTEM_OK)
      ErrStat = CD_FAST_OK
      ErrMsg = ''
    CASE (CD_SYSTEM_BADINPUT)
      ErrStat = CD_FAST_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST: '//TRIM(SystemMsg)
    CASE (CD_SYSTEM_NOT_INITIALIZED)
      ErrStat = CD_FAST_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST: '//TRIM(SystemMsg)
    CASE (CD_SYSTEM_ALLOCFAIL)
      ErrStat = CD_FAST_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST: '//TRIM(SystemMsg)
    CASE DEFAULT
      ErrStat = CD_FAST_SOLVEFAIL
      ErrMsg = 'CableDyn_OpenFAST: '//TRIM(SystemMsg)
    END SELECT
  END SUBROUTINE map_status

END MODULE CableDyn_OpenFAST
