! File: src/CableDyn_OpenFAST_FMF.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_OpenFAST_FMF
  !! Standalone OpenFAST-style module-form wrapper over the CableDyn shell.
  !!
  !! This module corresponds to doc/coupling_boundary.md. It assembles the
  !! current registry-style types, point-mesh adapter, and lifecycle shell into a
  !! single Init/UpdateStates/CalcOutput/End object graph. The generated OpenFAST
  !! binding must preserve this behavior when it is linked against OpenFAST types.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_MIN_TIME_STEP
  USE CableDyn_Model, ONLY: CD_ModelType
  USE CableDyn_System, ONLY: CD_SystemType, CD_SystemPointType, CD_LineEndpointBinding, CD_Get_System_PointBlocks, &
                             CD_System_NDynamicPoints, &
                             CD_POINT_COUPLED, CD_SYSTEM_OK, CD_System_Snapshot, CD_System_Restore
  USE CableDyn_OpenFAST, ONLY: CD_FAST_ModuleType, CD_FAST_Init_From_Points, CD_FAST_End, CD_FAST_NLines, &
                               CD_FAST_NCoupledDOF, CD_FAST_Step, CD_FAST_CalcOutputDerivatives, CD_FAST_OK, &
                               CD_FAST_BADINPUT, CD_FAST_NOT_INITIALIZED, CD_FAST_ALLOCFAIL, CD_FAST_GetCoupledMotion, &
                               CD_FAST_UpdatePointFluidFields, CD_FAST_IsInitialized
  USE CableDyn_OpenFAST_Types, ONLY: CD_InitInputType, CD_InitOutputType, CD_InputType, CD_OutputType, &
                                     CD_ParameterType, CD_ContinuousStateType, CD_DiscreteStateType, &
                                     CD_ConstraintStateType, CD_OtherStateType, CD_OpenFAST_Types_InitExchange, &
                                     CD_OpenFAST_Types_EndExchange, CD_OpenFAST_Types_InitStates, &
                                     CD_OpenFAST_Types_EndStates, CD_TYPES_OK, CD_TYPES_BADINPUT, &
                                     CD_TYPES_ALLOCFAIL
  USE CableDyn_OpenFAST_Mesh, ONLY: CD_FAST_PointMeshType, CD_FAST_Init_PointMesh, CD_FAST_End_PointMesh, &
                                    CD_FAST_Set_PointMesh_State, CD_FAST_Get_PointMesh_State, &
                                    CD_FAST_UpdateStates_From_PointMesh, CD_FAST_CalcOutput_To_PointMesh, &
                                    CD_FAST_CalcBodyWrench_From_PointMesh, CD_FAST_MESH_OK, &
                                    CD_FAST_MESH_BADINPUT, CD_FAST_MESH_NOT_INITIALIZED, CD_FAST_MESH_ALLOCFAIL
  USE CableDyn_DeckDriver, ONLY: CD_Init_Deck_System, CD_DECKDRV_OK, CD_DECKDRV_BADINPUT
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_FMF_ModuleType
  PUBLIC :: CD_FMF_Init_From_Points
  PUBLIC :: CD_FMF_Init_From_Deck
  PUBLIC :: CD_FMF_Init_From_System
  PUBLIC :: CD_FMF_UpdateStates
  PUBLIC :: CD_FMF_UpdateStates_Moving
  PUBLIC :: CD_FMF_UpdatePointFluidFields
  PUBLIC :: CD_FMF_Step
  PUBLIC :: CD_FMF_Step_Moving
  PUBLIC :: CD_FMF_Snapshot
  PUBLIC :: CD_FMF_Restore
  PUBLIC :: CD_FMF_CalcOutput
  PUBLIC :: CD_FMF_CalcOutputDerivatives
  PUBLIC :: CD_FMF_CalcBodyWrench
  PUBLIC :: CD_FMF_GetPointMesh
  PUBLIC :: CD_FMF_NMovingPoints
  PUBLIC :: CD_FMF_NDynamicPoints
  PUBLIC :: CD_FMF_Refresh_PointMesh
  PUBLIC :: CD_FMF_GetMovingPointMesh
  PUBLIC :: CD_FMF_End
  PUBLIC :: CD_FMF_IsInitialized

  INTEGER, PARAMETER, PUBLIC :: CD_FMF_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_FMF_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_FMF_SOLVEFAIL = 2
  INTEGER, PARAMETER, PUBLIC :: CD_FMF_NOT_INITIALIZED = 3
  INTEGER, PARAMETER, PUBLIC :: CD_FMF_ALLOCFAIL = 4

  TYPE :: CD_FMF_ModuleType
    !! OpenFAST-style module-form owner for standalone coupling tests.
    TYPE(CD_FAST_ModuleType) :: fast
    TYPE(CD_InitInputType) :: init_input
    TYPE(CD_InitOutputType) :: init_output
    TYPE(CD_InputType) :: u
    TYPE(CD_OutputType) :: y
    TYPE(CD_ParameterType) :: p
    TYPE(CD_ContinuousStateType) :: x
    TYPE(CD_DiscreteStateType) :: xd
    TYPE(CD_ConstraintStateType) :: z
    TYPE(CD_OtherStateType) :: other
    TYPE(CD_FAST_PointMeshType) :: point_mesh
    !> Host-prescribed (moving) 3-DOF blocks of the coupled vector: the
    !> Coupled/Vessel boundary the host owns. Fixed anchors remain in the coupled
    !> vector but are held internally; Free/Connect points integrate internally.
    !> (Coupled bodies/rods join this set when they land on the system path.)
    INTEGER, ALLOCATABLE :: moving_blocks(:)
    !> Full-size scratch for the moving-surface gather/scatter (no per-step allocation).
    REAL(wp), ALLOCATABLE :: mv_pos(:, :), mv_vel(:, :), mv_acc(:, :), mv_load(:, :)
    !> Snapshot of the exposed step metadata (other%last_*) for the stage-then-commit
    !> contract: a failed step attempt updates these before its rollback, and inspection
    !> logic must see the step-START metadata after a staged restore, not the failed
    !> attempt's.
    INTEGER :: snap_last_num_iter = 0
    LOGICAL :: snap_last_converged = .FALSE.
    LOGICAL :: snap_last_stalled = .FALSE.
    LOGICAL :: initialized = .FALSE.
  END TYPE CD_FMF_ModuleType

CONTAINS

  SUBROUTINE CD_FMF_Init_From_Points(self, models, points, bindings, dt, ErrStat, ErrMsg)
    !! Initialize the standalone module-form wrapper from point-bound line models.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    TYPE(CD_ModelType), INTENT(IN) :: models(:)
    TYPE(CD_SystemPointType), INTENT(IN) :: points(:)
    TYPE(CD_LineEndpointBinding), INTENT(IN) :: bindings(:)
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_FMF_ModuleType) :: candidate
    INTEGER :: es, n_coupled
    CHARACTER(1024) :: em

    ErrStat = CD_FMF_OK
    ErrMsg = ''
    IF (.NOT. (dt > CD_ZERO)) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: dt must be positive'
      RETURN
    END IF
    IF (dt < CD_MIN_TIME_STEP) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: dt is below the smallest time step, 1e-100 s: the time '// &
               'integration divides by dt^2'
      RETURN
    END IF
    candidate%init_input%n_coupled_dof = 0
    candidate%init_input%dt = dt
    CALL CD_FAST_Init_From_Points(candidate%fast, models, points, bindings, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    n_coupled = CD_FAST_NCoupledDOF(candidate%fast, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    IF (MOD(n_coupled, 3) /= 0) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: coupled DOF count must be divisible by 3'
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL finalize_exchange_after_system_init(candidate, n_coupled, dt, candidate%init_input%gravity, &
                                             candidate%init_input%rho_water, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) THEN
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL build_moving_blocks(candidate, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) THEN
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL CD_FMF_End(self, es, em)
    self = candidate
    CALL CD_FMF_End(candidate, es, em)
  END SUBROUTINE CD_FMF_Init_From_Points

  SUBROUTINE CD_FMF_Init_From_Deck(self, deck_path, dt, ErrStat, ErrMsg, env_gravity, env_rho_water, env_wtrdpth)
    !! Initialize the standalone module-form wrapper from a supported EI=0 deck.
    !! env_gravity / env_rho_water / env_wtrdpth: the coupled host's environment,
    !! passed through to the deck system (host values override deck-declared ones).
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    CHARACTER(*), INTENT(IN) :: deck_path
    REAL(wp), INTENT(IN) :: dt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: env_gravity, env_rho_water, env_wtrdpth

    TYPE(CD_FMF_ModuleType) :: candidate
    REAL(wp) :: deck_dt, gravity, rho_water
    INTEGER :: es, n_coupled
    CHARACTER(1024) :: em

    ErrStat = CD_FMF_OK
    ErrMsg = ''
    IF (.NOT. (dt > CD_ZERO)) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: dt must be positive'
      RETURN
    END IF
    IF (dt < CD_MIN_TIME_STEP) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: dt is below the smallest time step, 1e-100 s: the time '// &
               'integration divides by dt^2'
      RETURN
    END IF
    candidate%init_input%dt = dt
    ! The host marches the coupled system (CD_FMF_Step at the caller's dt), so the
    ! deck's own dtM/TMax standalone-marching pairing is advisory here. Absent
    ! optionals propagate to the deck driver as absent.
    CALL CD_Init_Deck_System(deck_path, candidate%fast%system, deck_dt, gravity, rho_water, es, em, &
                             caller_driven=.TRUE., env_gravity=env_gravity, env_rho_water=env_rho_water, &
                             env_wtrdpth=env_wtrdpth)
    IF (es /= CD_DECKDRV_OK) THEN
      CALL map_deck_status(es, em, ErrStat, ErrMsg)
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    n_coupled = CD_FAST_NCoupledDOF(candidate%fast, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL finalize_exchange_after_system_init(candidate, n_coupled, dt, gravity, rho_water, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) THEN
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL build_moving_blocks(candidate, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) THEN
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL CD_FMF_End(self, es, em)
    self = candidate
    CALL CD_FMF_End(candidate, es, em)
  END SUBROUTINE CD_FMF_Init_From_Deck

  SUBROUTINE CD_FMF_Init_From_System(self, system, dt, gravity, rho_water, ErrStat, ErrMsg)
    !! Initialize the module-form wrapper from an already-built EI=0 CableDyn system.
    !! This is the CD_FMF_Init_From_Deck path with the parse/build step lifted out: the
    !! caller (the OpenFAST aggregate, which partitions a mixed deck into its EI=0 subset)
    !! supplies a system built by init_deck_system_from_parsed, and this routine wraps it
    !! with the identical exchange/point-mesh/moving-surface finalization. gravity /
    !! rho_water are the environment the system was built under (they populate the
    !! parameter/init records, matching the deck path). The system is deep-copied in; the
    !! caller retains ownership of its own copy.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    TYPE(CD_SystemType), INTENT(IN) :: system
    REAL(wp), INTENT(IN) :: dt, gravity, rho_water
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_FMF_ModuleType) :: candidate
    INTEGER :: es, n_coupled
    CHARACTER(1024) :: em

    ErrStat = CD_FMF_OK
    ErrMsg = ''
    IF (.NOT. (dt > CD_ZERO)) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: dt must be positive'
      RETURN
    END IF
    IF (dt < CD_MIN_TIME_STEP) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: dt is below the smallest time step, 1e-100 s: the time '// &
               'integration divides by dt^2'
      RETURN
    END IF
    candidate%init_input%dt = dt
    candidate%fast%system = system
    IF (.NOT. CD_FAST_IsInitialized(candidate%fast)) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: supplied system is not initialized'
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    n_coupled = CD_FAST_NCoupledDOF(candidate%fast, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL finalize_exchange_after_system_init(candidate, n_coupled, dt, gravity, rho_water, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) THEN
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL build_moving_blocks(candidate, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) THEN
      CALL cleanup_failed_init(candidate)
      RETURN
    END IF
    CALL CD_FMF_End(self, es, em)
    self = candidate
    CALL CD_FMF_End(candidate, es, em)
  END SUBROUTINE CD_FMF_Init_From_System

  SUBROUTINE CD_FMF_UpdateStates(self, position, velocity, acceleration, ErrStat, ErrMsg, output_probe)
    !! Transfer host point-mesh kinematics into CableDyn through the module form. output_probe is
    !! reserved for a caller that owns and restores a complete outer state mirror.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: output_probe

    INTEGER :: es
    LOGICAL :: is_output_probe
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    is_output_probe = .FALSE.
    IF (PRESENT(output_probe)) is_output_probe = output_probe
    CALL CD_FAST_Set_PointMesh_State(self%point_mesh, position, velocity, acceleration, es, em)
    IF (es /= CD_FAST_MESH_OK) THEN
      CALL map_mesh_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    CALL CD_FAST_UpdateStates_From_PointMesh(self%fast, self%point_mesh, es, em, output_probe=is_output_probe)
    IF (es /= CD_FAST_MESH_OK) THEN
      CALL map_mesh_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    self%u%q_coupled = self%point_mesh%q_coupled
    self%u%v_coupled = self%point_mesh%v_coupled
    self%u%a_coupled = self%point_mesh%a_coupled
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_UpdateStates

  SUBROUTINE CD_FMF_UpdatePointFluidFields(self, fluid_velocity, fluid_acceleration, waterline_z, fluid_density, &
                                           ErrStat, ErrMsg)
    !! Transfer host fluid kinematics into the point-hydro fields used by Free/Connect points.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: fluid_velocity(:, :), fluid_acceleration(:, :), waterline_z(:), fluid_density
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_FAST_UpdatePointFluidFields(self%fast, fluid_velocity, fluid_acceleration, waterline_z, fluid_density, &
                                        es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_UpdatePointFluidFields

  SUBROUTINE CD_FMF_Step(self, dt, position, velocity, acceleration, converged, stalled, n_iter, ErrStat, ErrMsg)
    !! Transfer host point-mesh kinematics and advance one CableDyn time step.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: dt
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. (dt > CD_ZERO)) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: step dt must be positive'
      RETURN
    END IF
    IF (dt < CD_MIN_TIME_STEP) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: dt is below the smallest time step, 1e-100 s: the time '// &
               'integration divides by dt^2'
      RETURN
    END IF
    CALL CD_FAST_Set_PointMesh_State(self%point_mesh, position, velocity, acceleration, es, em)
    IF (es /= CD_FAST_MESH_OK) THEN
      CALL map_mesh_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    CALL pack_point_mesh_state(self)
    CALL CD_FAST_Step(self%fast, dt, self%u%q_coupled, self%u%v_coupled, self%u%a_coupled, converged, stalled, &
                      n_iter, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      ! FAILURE ATOMICITY includes the facade: the failed t+dt kinematics were
      ! transferred into the point mesh BEFORE the solve, while the system's own states
      ! rolled back inside the failed step -- re-derive the mesh from those committed
      ! states so the mesh readers never see the failed kinematics (best effort on this
      ! error path: the step's own error stays the reported one).
      CALL refresh_point_mesh_state(self, es, em)
      RETURN
    END IF
    ! Commit the public convergence metadata only with a successful system step.
    ! CD_FAST_Step is state-atomic on failure, so exposing the rejected attempt's
    ! counters here would leave the facade inconsistent with its restored state.
    self%other%last_num_iter = n_iter
    self%other%last_converged = converged
    self%other%last_stalled = stalled
    CALL refresh_point_mesh_state(self, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_Step

  SUBROUTINE CD_FMF_CalcOutput(self, ErrStat, ErrMsg)
    !! Calculate loads at the current point-mesh state and store them in y and mesh.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_FAST_CalcOutput_To_PointMesh(self%fast, self%point_mesh, es, em)
    IF (es /= CD_FAST_MESH_OK) THEN
      CALL map_mesh_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    self%y%coupled_loads = self%point_mesh%coupled_loads
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_CalcOutput

  SUBROUTINE CD_FMF_CalcOutputDerivatives(self, eps_fd, ErrStat, ErrMsg)
    !! Calculate loads and tight-coupling derivative blocks at the current input state.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: eps_fd
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_FAST_CalcOutputDerivatives(self%fast, self%u%q_coupled, self%u%v_coupled, self%u%a_coupled, eps_fd, &
                                       self%y%coupled_loads, self%y%dload_dq, self%y%dload_dv, self%y%dload_da, &
                                       self%y%added_mass, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    CALL CD_FAST_CalcOutput_To_PointMesh(self%fast, self%point_mesh, es, em)
    IF (es /= CD_FAST_MESH_OK) THEN
      CALL map_mesh_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_CalcOutputDerivatives

  SUBROUTINE CD_FMF_CalcBodyWrench(self, body_q, offsets_body, body_wrench, ErrStat, ErrMsg)
    !! Map the current point-mesh loads to a single rigid-body wrench.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: body_q(6)
    REAL(wp), INTENT(IN) :: offsets_body(:, :)
    REAL(wp), INTENT(OUT) :: body_wrench(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    body_wrench = CD_ZERO
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_FAST_CalcBodyWrench_From_PointMesh(self%point_mesh, body_q, offsets_body, body_wrench, es, em)
    IF (es /= CD_FAST_MESH_OK) THEN
      CALL map_mesh_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_CalcBodyWrench

  SUBROUTINE CD_FMF_GetPointMesh(self, position, velocity, acceleration, load, ErrStat, ErrMsg)
    !! Copy the current point-mesh state and loads out of the module form.
    TYPE(CD_FMF_ModuleType), INTENT(IN) :: self
    REAL(wp), INTENT(OUT) :: position(:, :), velocity(:, :), acceleration(:, :), load(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    position = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    load = CD_ZERO
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_FAST_Get_PointMesh_State(self%point_mesh, position, velocity, acceleration, load, es, em)
    IF (es /= CD_FAST_MESH_OK) THEN
      CALL map_mesh_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_GetPointMesh

  SUBROUTINE build_moving_blocks(self, ErrStat, ErrMsg)
    !! Identify the host-prescribed (moving) 3-DOF blocks of the coupled vector:
    !! the Coupled/Vessel points. Fixed anchors stay in the coupled vector but are
    !! held by the solver at their initial positions; Free/Connect points are
    !! integrated internally -- neither belongs to the host. A system without a
    !! stored points table (Init_From_Points) is fully host-prescribed. Also sizes
    !! the full-vector scratch used by the moving gather/scatter.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER, ALLOCATABLE :: blocks(:)
    INTEGER :: i, k, n_all, es, istat
    CHARACTER(1024) :: em

    ErrStat = CD_FMF_OK
    ErrMsg = ''
    IF (ALLOCATED(self%moving_blocks)) DEALLOCATE (self%moving_blocks)
    n_all = CD_FAST_NCoupledDOF(self%fast, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    n_all = n_all/3
    CALL CD_Get_System_PointBlocks(self%fast%system, blocks, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(em)
      RETURN
    END IF
    IF (.NOT. ALLOCATED(blocks)) THEN
      ALLOCATE (self%moving_blocks(n_all), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = CD_FMF_ALLOCFAIL
        ErrMsg = 'CableDyn_OpenFAST_FMF: moving-block allocation failed'
        RETURN
      END IF
      self%moving_blocks = [(i, i=1, n_all)]
    ELSE
      k = 0
      DO i = 1, SIZE(blocks)
        IF (self%fast%system%points(blocks(i))%point_type == CD_POINT_COUPLED) k = k + 1
      END DO
      ALLOCATE (self%moving_blocks(k), STAT=istat)
      IF (istat /= 0) THEN
        ErrStat = CD_FMF_ALLOCFAIL
        ErrMsg = 'CableDyn_OpenFAST_FMF: moving-block allocation failed'
        RETURN
      END IF
      k = 0
      DO i = 1, SIZE(blocks)
        IF (self%fast%system%points(blocks(i))%point_type == CD_POINT_COUPLED) THEN
          k = k + 1
          self%moving_blocks(k) = i
        END IF
      END DO
    END IF
    IF (ALLOCATED(self%mv_pos)) DEALLOCATE (self%mv_pos)
    IF (ALLOCATED(self%mv_vel)) DEALLOCATE (self%mv_vel)
    IF (ALLOCATED(self%mv_acc)) DEALLOCATE (self%mv_acc)
    IF (ALLOCATED(self%mv_load)) DEALLOCATE (self%mv_load)
    ALLOCATE (self%mv_pos(3, n_all), self%mv_vel(3, n_all), self%mv_acc(3, n_all), self%mv_load(3, n_all), &
              STAT=istat)
    IF (istat /= 0) THEN
      ErrStat = CD_FMF_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_FMF: moving-surface scratch allocation failed'
      RETURN
    END IF
  END SUBROUTINE build_moving_blocks

  INTEGER FUNCTION CD_FMF_NMovingPoints(self, ErrStat, ErrMsg) RESULT(n)
    !! Number of host-prescribed (Coupled/Vessel) points in the coupled boundary.
    TYPE(CD_FMF_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    n = 0
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. ALLOCATED(self%moving_blocks)) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: moving-point set was not built at init'
      RETURN
    END IF
    n = SIZE(self%moving_blocks)
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END FUNCTION CD_FMF_NMovingPoints

  SUBROUTINE CD_FMF_GetMovingPointMesh(self, position, velocity, acceleration, load, ErrStat, ErrMsg)
    !! Copy the state and loads of the host-prescribed (moving) points only.
    !! Arrays are shaped (3, n_moving) in moving-set order.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(OUT) :: position(:, :), velocity(:, :), acceleration(:, :), load(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, b

    position = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    load = CD_ZERO
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. moving_surface_ready(self, ErrStat, ErrMsg)) RETURN
    IF (SIZE(position, 2) /= SIZE(self%moving_blocks) .OR. SIZE(velocity, 2) /= SIZE(self%moving_blocks) .OR. &
        SIZE(acceleration, 2) /= SIZE(self%moving_blocks) .OR. SIZE(load, 2) /= SIZE(self%moving_blocks) .OR. &
        SIZE(position, 1) /= 3 .OR. SIZE(velocity, 1) /= 3 .OR. SIZE(acceleration, 1) /= 3 .OR. &
        SIZE(load, 1) /= 3) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: moving-point arrays must be shaped (3, n_moving)'
      RETURN
    END IF
    CALL CD_FMF_GetPointMesh(self, self%mv_pos, self%mv_vel, self%mv_acc, self%mv_load, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) RETURN
    DO i = 1, SIZE(self%moving_blocks)
      b = self%moving_blocks(i)
      position(:, i) = self%mv_pos(:, b)
      velocity(:, i) = self%mv_vel(:, b)
      acceleration(:, i) = self%mv_acc(:, b)
      load(:, i) = self%mv_load(:, b)
    END DO
  END SUBROUTINE CD_FMF_GetMovingPointMesh

  SUBROUTINE CD_FMF_UpdateStates_Moving(self, position, velocity, acceleration, ErrStat, ErrMsg, output_probe)
    !! Transfer host kinematics for the moving (Coupled/Vessel) points only. The
    !! remaining coupled blocks keep their current values -- Fixed anchors hold
    !! their initial positions with zero rates, Free/Connect points keep their
    !! internally integrated state.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: output_probe

    INTEGER :: i, b
    LOGICAL :: is_output_probe

    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    is_output_probe = .FALSE.
    IF (PRESENT(output_probe)) is_output_probe = output_probe
    IF (.NOT. moving_surface_ready(self, ErrStat, ErrMsg)) RETURN
    IF (SIZE(position, 2) /= SIZE(self%moving_blocks) .OR. SIZE(velocity, 2) /= SIZE(self%moving_blocks) .OR. &
        SIZE(acceleration, 2) /= SIZE(self%moving_blocks) .OR. SIZE(position, 1) /= 3 .OR. &
        SIZE(velocity, 1) /= 3 .OR. SIZE(acceleration, 1) /= 3) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: moving-point arrays must be shaped (3, n_moving)'
      RETURN
    END IF
    CALL CD_FMF_GetPointMesh(self, self%mv_pos, self%mv_vel, self%mv_acc, self%mv_load, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) RETURN
    DO i = 1, SIZE(self%moving_blocks)
      b = self%moving_blocks(i)
      self%mv_pos(:, b) = position(:, i)
      self%mv_vel(:, b) = velocity(:, i)
      self%mv_acc(:, b) = acceleration(:, i)
    END DO
    CALL CD_FMF_UpdateStates(self, self%mv_pos, self%mv_vel, self%mv_acc, ErrStat, ErrMsg, &
                             output_probe=is_output_probe)
  END SUBROUTINE CD_FMF_UpdateStates_Moving

  SUBROUTINE CD_FMF_Step_Moving(self, dt, position, velocity, acceleration, converged, stalled, n_iter, ErrStat, ErrMsg)
    !! Transfer host kinematics for the moving (Coupled/Vessel) points and advance
    !! one CableDyn time step; the other coupled blocks keep their current values
    !! (Fixed anchors held, Free/Connect internally integrated).
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    REAL(wp), INTENT(IN) :: dt
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    LOGICAL, INTENT(OUT) :: converged, stalled
    INTEGER, INTENT(OUT) :: n_iter, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: i, b

    converged = .FALSE.
    stalled = .FALSE.
    n_iter = 0
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    IF (.NOT. moving_surface_ready(self, ErrStat, ErrMsg)) RETURN
    IF (SIZE(position, 2) /= SIZE(self%moving_blocks) .OR. SIZE(velocity, 2) /= SIZE(self%moving_blocks) .OR. &
        SIZE(acceleration, 2) /= SIZE(self%moving_blocks) .OR. SIZE(position, 1) /= 3 .OR. &
        SIZE(velocity, 1) /= 3 .OR. SIZE(acceleration, 1) /= 3) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: moving-point arrays must be shaped (3, n_moving)'
      RETURN
    END IF
    CALL CD_FMF_GetPointMesh(self, self%mv_pos, self%mv_vel, self%mv_acc, self%mv_load, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FMF_OK) RETURN
    DO i = 1, SIZE(self%moving_blocks)
      b = self%moving_blocks(i)
      self%mv_pos(:, b) = position(:, i)
      self%mv_vel(:, b) = velocity(:, i)
      self%mv_acc(:, b) = acceleration(:, i)
    END DO
    CALL CD_FMF_Step(self, dt, self%mv_pos, self%mv_vel, self%mv_acc, converged, stalled, n_iter, ErrStat, ErrMsg)
  END SUBROUTINE CD_FMF_Step_Moving

  SUBROUTINE CD_FMF_Snapshot(self, ErrStat, ErrMsg)
    !! Capture the committed system state for the aggregate stage-then-commit contract
    !! (delegates to CD_System_Snapshot; see its note on why the per-line rollback
    !! buffers cannot serve this role after a substep-fallback success).
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_System_Snapshot(self%fast%system, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: snapshot failed: '//TRIM(em)
      RETURN
    END IF
    self%snap_last_num_iter = self%other%last_num_iter
    self%snap_last_converged = self%other%last_converged
    self%snap_last_stalled = self%other%last_stalled
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_Snapshot

  SUBROUTINE CD_FMF_Restore(self, ErrStat, ErrMsg)
    !! Restore the committed system state from the last CD_FMF_Snapshot (fails closed
    !! without a valid snapshot), then RE-DERIVE the facade point mesh from the restored
    !! system -- a step attempt has already transferred the failed t+dt kinematics into
    !! the mesh (CD_FMF_Step sets the mesh before solving), and the mesh readers
    !! (CD_FMF_GetPointMesh / GetMovingPointMesh) serve positions and velocities FROM
    !! the mesh, so restoring the system alone would leave the facade stale. The
    !! re-derive is the same refresh the successful step path runs (single source of
    !! truth: the system).
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: es
    CHARACTER(1024) :: em
    IF (.NOT. require_initialized(self, ErrStat, ErrMsg)) RETURN
    CALL CD_System_Restore(self%fast%system, es, em)
    IF (es /= CD_SYSTEM_OK) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: restore failed: '//TRIM(em)
      RETURN
    END IF
    CALL refresh_point_mesh_state(self, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    ! the exposed step metadata rolls back with the state: inspection logic must see
    ! the step-start values, not the failed attempt's
    self%other%last_num_iter = self%snap_last_num_iter
    self%other%last_converged = self%snap_last_converged
    self%other%last_stalled = self%snap_last_stalled
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_Restore

  LOGICAL FUNCTION moving_surface_ready(self, ErrStat, ErrMsg) RESULT(ok)
    TYPE(CD_FMF_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ok = ALLOCATED(self%moving_blocks) .AND. ALLOCATED(self%mv_pos)
    IF (ok) THEN
      ErrStat = CD_FMF_OK
      ErrMsg = ''
    ELSE
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: moving-point set was not built at init'
    END IF
  END FUNCTION moving_surface_ready

  SUBROUTINE CD_FMF_End(self, ErrStat, ErrMsg)
    !! Release all module-form resources. Idempotent by design.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL CD_FAST_End(self%fast, es, em)
    CALL CD_FAST_End_PointMesh(self%point_mesh)
    CALL CD_OpenFAST_Types_EndExchange(self%u, self%y)
    CALL CD_OpenFAST_Types_EndStates(self%x, self%z)
    IF (ALLOCATED(self%moving_blocks)) DEALLOCATE (self%moving_blocks)
    IF (ALLOCATED(self%mv_pos)) DEALLOCATE (self%mv_pos)
    IF (ALLOCATED(self%mv_vel)) DEALLOCATE (self%mv_vel)
    IF (ALLOCATED(self%mv_acc)) DEALLOCATE (self%mv_acc)
    IF (ALLOCATED(self%mv_load)) DEALLOCATE (self%mv_load)
    self%init_input = CD_InitInputType()
    self%init_output = CD_InitOutputType()
    self%p = CD_ParameterType()
    self%xd = CD_DiscreteStateType()
    self%other = CD_OtherStateType()
    self%initialized = .FALSE.
    ErrStat = CD_FMF_OK
    ErrMsg = ''
  END SUBROUTINE CD_FMF_End

  LOGICAL FUNCTION CD_FMF_IsInitialized(self) RESULT(is_initialized)
    !! Query whether the module-form wrapper owns an initialized shell.
    TYPE(CD_FMF_ModuleType), INTENT(IN) :: self

    is_initialized = self%initialized
  END FUNCTION CD_FMF_IsInitialized

  LOGICAL FUNCTION require_initialized(self, ErrStat, ErrMsg) RESULT(ok)
    TYPE(CD_FMF_ModuleType), INTENT(IN) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ok = self%initialized
    IF (ok) THEN
      ErrStat = CD_FMF_OK
      ErrMsg = ''
    ELSE
      ErrStat = CD_FMF_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_FMF: module is not initialized'
    END IF
  END FUNCTION require_initialized

  SUBROUTINE cleanup_failed_init(self)
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self

    INTEGER :: es
    CHARACTER(1024) :: em

    CALL CD_FMF_End(self, es, em)
  END SUBROUTINE cleanup_failed_init

  SUBROUTINE finalize_exchange_after_system_init(self, n_coupled, dt, gravity, rho_water, ErrStat, ErrMsg)
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(IN) :: n_coupled
    REAL(wp), INTENT(IN) :: dt, gravity, rho_water
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es, n_point, li
    CHARACTER(1024) :: em

    ErrStat = CD_FMF_OK
    ErrMsg = ''
    ! Viscoelastic (ElasticMod > 1) AND Syrope lines are both supported on the coupled
    ! facade now: the glue checkpoint mirror carries their per-element history states
    ! (viscoelastic dl_1; Syrope slow-spring static strain + running-maximum tension) via
    ! CableDyn_OF pack_state_mirror / reload_interiors_ary, and the in-process System
    ! snapshot carries them too, so both the aggregate checkpoint path and the pure-FMF
    ! interior reload restore the constitutive partition exactly. Syrope build sub-cases
    ! the standalone builder still rejects (seabed/hydro, composite, finite-EI) fail
    ! closed upstream at the deck build, not here.
    !
    ! A single line carrying BOTH viscoelastic and Syrope elements is constructible at the
    ! model level but not via a deck (Syrope lines are single-section), and the glue mirror
    ! stacks each constitutive tail at the same per-line offset -- so reject a mixed
    ! stateful line here to keep the checkpoint mirror unambiguous (fail closed, never a
    ! silent overlap).
    DO li = 1, self%fast%system%n_lines
      IF (self%fast%system%lines(li)%has_viscoelastic .AND. self%fast%system%lines(li)%has_syrope) THEN
        ErrStat = CD_FMF_BADINPUT
        ErrMsg = 'CableDyn_OpenFAST_FMF: a coupled line cannot mix viscoelastic and Syrope '// &
                 'elements (the checkpoint mirror carries one constitutive history per line)'
        RETURN
      END IF
    END DO
    IF (MOD(n_coupled, 3) /= 0) THEN
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: coupled DOF count must be divisible by 3'
      RETURN
    END IF
    n_point = n_coupled/3
    self%init_input%n_coupled_dof = n_coupled
    self%init_input%dt = dt
    self%init_input%gravity = gravity
    self%init_input%rho_water = rho_water
    CALL CD_OpenFAST_Types_InitExchange(self%u, self%y, self%p, n_coupled, es, em)
    IF (es /= CD_TYPES_OK) THEN
      CALL map_types_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    CALL CD_OpenFAST_Types_InitStates(self%x, self%z, 0, 0, es, em)
    IF (es /= CD_TYPES_OK) THEN
      CALL map_types_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    CALL CD_FAST_Init_PointMesh(self%point_mesh, n_point, es, em)
    IF (es /= CD_FAST_MESH_OK) THEN
      CALL map_mesh_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    self%p%n_lines = CD_FAST_NLines(self%fast, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    self%p%n_coupled_dof = n_coupled
    self%p%dt = dt
    self%p%gravity = gravity
    self%p%rho_water = rho_water
    self%init_output%n_lines = self%p%n_lines
    self%init_output%n_coupled_dof = n_coupled
    self%other%last_num_iter = 0
    self%other%last_converged = .TRUE.
    self%other%last_stalled = .FALSE.
    ! Seed the exchange input (self%u) and the point mesh from the initialized system geometry,
    ! so a caller that queries the initial point mesh or requests initial linearization before
    ! the first UpdateStates sees the real deck/point positions rather than the zero-filled
    ! allocations from CD_OpenFAST_Types_InitExchange / CD_FAST_Init_PointMesh.
    CALL refresh_point_mesh_state(self, es, em)
    IF (es /= CD_FAST_OK) THEN
      CALL map_fast_status(es, em, ErrStat, ErrMsg)
      RETURN
    END IF
    self%initialized = .TRUE.
  END SUBROUTINE finalize_exchange_after_system_init

  SUBROUTINE pack_point_mesh_state(self)
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self

    INTEGER :: p, base

    DO p = 1, self%point_mesh%n_point
      base = 3*(p - 1)
      self%point_mesh%q_coupled(base + 1:base + 3) = self%point_mesh%position(:, p)
      self%point_mesh%v_coupled(base + 1:base + 3) = self%point_mesh%velocity(:, p)
      self%point_mesh%a_coupled(base + 1:base + 3) = self%point_mesh%acceleration(:, p)
    END DO
    self%u%q_coupled = self%point_mesh%q_coupled
    self%u%v_coupled = self%point_mesh%v_coupled
    self%u%a_coupled = self%point_mesh%a_coupled
  END SUBROUTINE pack_point_mesh_state

  SUBROUTINE refresh_point_mesh_state(self, ErrStat, ErrMsg)
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: p, base

    CALL CD_FAST_GetCoupledMotion(self%fast, self%u%q_coupled, self%u%v_coupled, self%u%a_coupled, ErrStat, ErrMsg)
    IF (ErrStat /= CD_FAST_OK) RETURN
    DO p = 1, self%point_mesh%n_point
      base = 3*(p - 1)
      self%point_mesh%q_coupled(base + 1:base + 3) = self%u%q_coupled(base + 1:base + 3)
      self%point_mesh%v_coupled(base + 1:base + 3) = self%u%v_coupled(base + 1:base + 3)
      self%point_mesh%a_coupled(base + 1:base + 3) = self%u%a_coupled(base + 1:base + 3)
      self%point_mesh%position(:, p) = self%point_mesh%q_coupled(base + 1:base + 3)
      self%point_mesh%velocity(:, p) = self%point_mesh%v_coupled(base + 1:base + 3)
      self%point_mesh%acceleration(:, p) = self%point_mesh%a_coupled(base + 1:base + 3)
    END DO
  END SUBROUTINE refresh_point_mesh_state

  SUBROUTINE map_fast_status(FastStat, FastMsg, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: FastStat
    CHARACTER(*), INTENT(IN) :: FastMsg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    SELECT CASE (FastStat)
    CASE (CD_FAST_OK)
      ErrStat = CD_FMF_OK
      ErrMsg = ''
    CASE (CD_FAST_BADINPUT)
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(FastMsg)
    CASE (CD_FAST_NOT_INITIALIZED)
      ErrStat = CD_FMF_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(FastMsg)
    CASE (CD_FAST_ALLOCFAIL)
      ErrStat = CD_FMF_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(FastMsg)
    CASE DEFAULT
      ErrStat = CD_FMF_SOLVEFAIL
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(FastMsg)
    END SELECT
  END SUBROUTINE map_fast_status

  SUBROUTINE map_deck_status(DeckStat, DeckMsg, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: DeckStat
    CHARACTER(*), INTENT(IN) :: DeckMsg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    SELECT CASE (DeckStat)
    CASE (CD_DECKDRV_OK)
      ErrStat = CD_FMF_OK
      ErrMsg = ''
    CASE (CD_DECKDRV_BADINPUT)
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(DeckMsg)
    CASE DEFAULT
      ErrStat = CD_FMF_SOLVEFAIL
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(DeckMsg)
    END SELECT
  END SUBROUTINE map_deck_status

  SUBROUTINE map_mesh_status(MeshStat, MeshMsg, ErrStat, ErrMsg)
    INTEGER, INTENT(IN) :: MeshStat
    CHARACTER(*), INTENT(IN) :: MeshMsg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    SELECT CASE (MeshStat)
    CASE (CD_FAST_MESH_OK)
      ErrStat = CD_FMF_OK
      ErrMsg = ''
    CASE (CD_FAST_MESH_BADINPUT)
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(MeshMsg)
    CASE (CD_FAST_MESH_NOT_INITIALIZED)
      ErrStat = CD_FMF_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(MeshMsg)
    CASE (CD_FAST_MESH_ALLOCFAIL)
      ErrStat = CD_FMF_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(MeshMsg)
    CASE DEFAULT
      ErrStat = CD_FMF_SOLVEFAIL
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(MeshMsg)
    END SELECT
  END SUBROUTINE map_mesh_status

  SUBROUTINE map_types_status(TypesStat, TypesMsg, ErrStat, ErrMsg)
    !! Map a registry-facing CableDyn_OpenFAST_Types status onto the FMF status space, preserving
    !! the distinct allocation failure (resource exhaustion) rather than collapsing it to bad input.
    INTEGER, INTENT(IN) :: TypesStat
    CHARACTER(*), INTENT(IN) :: TypesMsg
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    SELECT CASE (TypesStat)
    CASE (CD_TYPES_OK)
      ErrStat = CD_FMF_OK
      ErrMsg = ''
    CASE (CD_TYPES_BADINPUT)
      ErrStat = CD_FMF_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(TypesMsg)
    CASE (CD_TYPES_ALLOCFAIL)
      ErrStat = CD_FMF_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(TypesMsg)
    CASE DEFAULT
      ErrStat = CD_FMF_SOLVEFAIL
      ErrMsg = 'CableDyn_OpenFAST_FMF: '//TRIM(TypesMsg)
    END SELECT
  END SUBROUTINE map_types_status

  SUBROUTINE CD_FMF_Refresh_PointMesh(self, ErrStat, ErrMsg)
    !! Re-derive the facade point mesh from the CURRENT system state -- for callers
    !! that mutate the system underneath the facade (a checkpoint reload restoring the
    !! coupled vector and point store): the moving-step path seeds its full coupled
    !! surface from this mesh, so a stale mesh would feed pre-restore Free/Connect
    !! values back into the system.
    TYPE(CD_FMF_ModuleType), INTENT(INOUT) :: self
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_FMF_OK
    ErrMsg = ''
    IF (.NOT. self%initialized) THEN
      ErrStat = CD_FMF_BADINPUT; ErrMsg = 'CD_FMF_Refresh_PointMesh: module not initialised'; RETURN
    END IF
    CALL refresh_point_mesh_state(self, ErrStat, ErrMsg)
  END SUBROUTINE CD_FMF_Refresh_PointMesh

  INTEGER FUNCTION CD_FMF_NDynamicPoints(self) RESULT(n)
    !! Number of DYNAMIC (Free/Connect) points the wrapped system integrates itself.
    !! 0 for an uninitialized module.
    TYPE(CD_FMF_ModuleType), INTENT(IN) :: self
    n = 0
    IF (.NOT. self%initialized) RETURN
    n = CD_System_NDynamicPoints(self%fast%system)
  END FUNCTION CD_FMF_NDynamicPoints

END MODULE CableDyn_OpenFAST_FMF
