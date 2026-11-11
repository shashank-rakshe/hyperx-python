! File: src/CableDyn_OpenFAST_Mesh.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_OpenFAST_Mesh
  !! Point-mesh adapter for the OpenFAST-facing CableDyn shell.
  !!
  !! This module corresponds to doc/coupling_boundary.md. It provides a
  !! standalone Fortran mesh exchange layer that mirrors the point-to-point
  !! kinematic/load transfer needed by the OpenFAST module boundary while keeping
  !! CableDyn buildable without linking to OpenFAST internals.
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  USE CableDyn_Precision, ONLY: wp, CD_ZERO
  USE CableDyn_RigidKinematics, ONLY: CD_Rigid_Points_From_Body, CD_Rigid_Wrench_From_Point_Loads, CD_RIGID_OK
  USE CableDyn_OpenFAST, ONLY: CD_FAST_ModuleType, CD_FAST_UpdateStates, CD_FAST_CalcOutput, &
                               CD_FAST_NCoupledDOF, CD_FAST_OK, CD_FAST_BADINPUT, CD_FAST_NOT_INITIALIZED, &
                               CD_FAST_ALLOCFAIL
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_FAST_PointMeshType
  PUBLIC :: CD_FAST_Init_PointMesh
  PUBLIC :: CD_FAST_End_PointMesh
  PUBLIC :: CD_FAST_PointMesh_IsInitialized
  PUBLIC :: CD_FAST_Set_PointMesh_State
  PUBLIC :: CD_FAST_Get_PointMesh_State
  PUBLIC :: CD_FAST_Set_PointMesh_From_Body
  PUBLIC :: CD_FAST_UpdateStates_From_PointMesh
  PUBLIC :: CD_FAST_CalcOutput_To_PointMesh
  PUBLIC :: CD_FAST_CalcBodyWrench_From_PointMesh

  INTEGER, PARAMETER, PUBLIC :: CD_FAST_MESH_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_FAST_MESH_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_FAST_MESH_SOLVEFAIL = 2
  INTEGER, PARAMETER, PUBLIC :: CD_FAST_MESH_NOT_INITIALIZED = 3
  INTEGER, PARAMETER, PUBLIC :: CD_FAST_MESH_ALLOCFAIL = 4

  TYPE :: CD_FAST_PointMeshType
    !! Reusable point mesh and flat vector workspace for coupled OpenFAST exchange.
    INTEGER :: n_point = 0
    REAL(wp), ALLOCATABLE :: position(:, :)
    REAL(wp), ALLOCATABLE :: velocity(:, :)
    REAL(wp), ALLOCATABLE :: acceleration(:, :)
    REAL(wp), ALLOCATABLE :: load(:, :)
    REAL(wp), ALLOCATABLE :: q_coupled(:)
    REAL(wp), ALLOCATABLE :: v_coupled(:)
    REAL(wp), ALLOCATABLE :: a_coupled(:)
    REAL(wp), ALLOCATABLE :: coupled_loads(:)
  END TYPE CD_FAST_PointMeshType

CONTAINS

  SUBROUTINE CD_FAST_Init_PointMesh(mesh, n_point, ErrStat, ErrMsg)
    !! Allocate a point mesh and its flat coupled-vector workspace.
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh
    INTEGER, INTENT(IN) :: n_point
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_FAST_PointMeshType) :: next_mesh
    INTEGER :: alloc_stat
    INTEGER :: n_dof

    ErrStat = CD_FAST_MESH_OK
    ErrMsg = ''
    IF (n_point < 0) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: n_point must be non-negative'
      RETURN
    END IF
    ! Guard 3*n_point in INT64 before it is formed: a corrupted/huge n_point would
    ! otherwise wrap the default-integer DOF count and under-size the allocations.
    IF (3_INT64*INT(n_point, INT64) > INT(HUGE(n_dof), INT64)) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: n_point too large; 3*n_point overflows the DOF count'
      RETURN
    END IF
    n_dof = 3*n_point
    ALLOCATE (next_mesh%position(3, n_point), next_mesh%velocity(3, n_point), &
              next_mesh%acceleration(3, n_point), next_mesh%load(3, n_point), &
              next_mesh%q_coupled(n_dof), next_mesh%v_coupled(n_dof), &
              next_mesh%a_coupled(n_dof), next_mesh%coupled_loads(n_dof), STAT=alloc_stat)
    IF (alloc_stat /= 0) THEN
      ErrStat = CD_FAST_MESH_ALLOCFAIL
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point-mesh allocation failed'
      RETURN
    END IF
    next_mesh%n_point = n_point
    next_mesh%position = CD_ZERO
    next_mesh%velocity = CD_ZERO
    next_mesh%acceleration = CD_ZERO
    next_mesh%load = CD_ZERO
    next_mesh%q_coupled = CD_ZERO
    next_mesh%v_coupled = CD_ZERO
    next_mesh%a_coupled = CD_ZERO
    next_mesh%coupled_loads = CD_ZERO
    CALL CD_FAST_End_PointMesh(mesh)
    ! Move the freshly-allocated components in rather than an intrinsic derived-type assignment,
    ! which would re-allocate every component again without STAT and could abort under memory
    ! pressure after the old mesh was already discarded.
    mesh%n_point = next_mesh%n_point
    CALL MOVE_ALLOC(next_mesh%position, mesh%position)
    CALL MOVE_ALLOC(next_mesh%velocity, mesh%velocity)
    CALL MOVE_ALLOC(next_mesh%acceleration, mesh%acceleration)
    CALL MOVE_ALLOC(next_mesh%load, mesh%load)
    CALL MOVE_ALLOC(next_mesh%q_coupled, mesh%q_coupled)
    CALL MOVE_ALLOC(next_mesh%v_coupled, mesh%v_coupled)
    CALL MOVE_ALLOC(next_mesh%a_coupled, mesh%a_coupled)
    CALL MOVE_ALLOC(next_mesh%coupled_loads, mesh%coupled_loads)
  END SUBROUTINE CD_FAST_Init_PointMesh

  SUBROUTINE CD_FAST_End_PointMesh(mesh)
    !! Release point mesh storage. Idempotent by design.
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh

    mesh%n_point = 0
    IF (ALLOCATED(mesh%position)) DEALLOCATE (mesh%position)
    IF (ALLOCATED(mesh%velocity)) DEALLOCATE (mesh%velocity)
    IF (ALLOCATED(mesh%acceleration)) DEALLOCATE (mesh%acceleration)
    IF (ALLOCATED(mesh%load)) DEALLOCATE (mesh%load)
    IF (ALLOCATED(mesh%q_coupled)) DEALLOCATE (mesh%q_coupled)
    IF (ALLOCATED(mesh%v_coupled)) DEALLOCATE (mesh%v_coupled)
    IF (ALLOCATED(mesh%a_coupled)) DEALLOCATE (mesh%a_coupled)
    IF (ALLOCATED(mesh%coupled_loads)) DEALLOCATE (mesh%coupled_loads)
  END SUBROUTINE CD_FAST_End_PointMesh

  LOGICAL FUNCTION CD_FAST_PointMesh_IsInitialized(mesh) RESULT(is_initialized)
    !! Return true when all point-mesh exchange arrays are allocated.
    TYPE(CD_FAST_PointMeshType), INTENT(IN) :: mesh

    is_initialized = mesh%n_point >= 0 .AND. ALLOCATED(mesh%position) .AND. ALLOCATED(mesh%velocity) .AND. &
                     ALLOCATED(mesh%acceleration) .AND. ALLOCATED(mesh%load) .AND. &
                     ALLOCATED(mesh%q_coupled) .AND. ALLOCATED(mesh%v_coupled) .AND. &
                     ALLOCATED(mesh%a_coupled) .AND. ALLOCATED(mesh%coupled_loads)
  END FUNCTION CD_FAST_PointMesh_IsInitialized

  SUBROUTINE CD_FAST_Set_PointMesh_State(mesh, position, velocity, acceleration, ErrStat, ErrMsg)
    !! Copy point kinematics into the point mesh.
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh
    REAL(wp), INTENT(IN) :: position(:, :), velocity(:, :), acceleration(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_FAST_MESH_OK
    ErrMsg = ''
    IF (.NOT. CD_FAST_PointMesh_IsInitialized(mesh)) THEN
      ErrStat = CD_FAST_MESH_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point mesh is not initialized'
      RETURN
    END IF
    IF (.NOT. point_shape_matches(mesh, position) .OR. .NOT. point_shape_matches(mesh, velocity) .OR. &
        .NOT. point_shape_matches(mesh, acceleration)) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point kinematic arrays must have shape (3,n_point)'
      RETURN
    END IF
    mesh%position = position
    mesh%velocity = velocity
    mesh%acceleration = acceleration
  END SUBROUTINE CD_FAST_Set_PointMesh_State

  SUBROUTINE CD_FAST_Get_PointMesh_State(mesh, position, velocity, acceleration, load, ErrStat, ErrMsg)
    !! Copy point-mesh kinematics and loads into caller-owned arrays.
    TYPE(CD_FAST_PointMeshType), INTENT(IN) :: mesh
    REAL(wp), INTENT(OUT) :: position(:, :), velocity(:, :), acceleration(:, :), load(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    position = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    load = CD_ZERO
    ErrStat = CD_FAST_MESH_OK
    ErrMsg = ''
    IF (.NOT. CD_FAST_PointMesh_IsInitialized(mesh)) THEN
      ErrStat = CD_FAST_MESH_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point mesh is not initialized'
      RETURN
    END IF
    IF (.NOT. point_shape_matches(mesh, position) .OR. .NOT. point_shape_matches(mesh, velocity) .OR. &
        .NOT. point_shape_matches(mesh, acceleration) .OR. .NOT. point_shape_matches(mesh, load)) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point output arrays must have shape (3,n_point)'
      RETURN
    END IF
    position = mesh%position
    velocity = mesh%velocity
    acceleration = mesh%acceleration
    load = mesh%load
  END SUBROUTINE CD_FAST_Get_PointMesh_State

  SUBROUTINE CD_FAST_Set_PointMesh_From_Body(mesh, body_q, body_v, body_a, offsets_body, ErrStat, ErrMsg)
    !! Fill point-mesh kinematics from a rigid platform state and body-frame offsets.
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh
    REAL(wp), INTENT(IN) :: body_q(6), body_v(6), body_a(6)
    REAL(wp), INTENT(IN) :: offsets_body(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    ErrStat = CD_FAST_MESH_OK
    ErrMsg = ''
    IF (.NOT. CD_FAST_PointMesh_IsInitialized(mesh)) THEN
      ErrStat = CD_FAST_MESH_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point mesh is not initialized'
      RETURN
    END IF
    IF (SIZE(offsets_body, 1) /= 3 .OR. SIZE(offsets_body, 2) /= mesh%n_point) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: offsets_body must have shape (3,n_point)'
      RETURN
    END IF
    CALL CD_Rigid_Points_From_Body(body_q, body_v, body_a, offsets_body, mesh%q_coupled, mesh%v_coupled, &
                                   mesh%a_coupled, es, em)
    IF (es /= CD_RIGID_OK) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: '//TRIM(em)
      RETURN
    END IF
    CALL unpack_state(mesh)
  END SUBROUTINE CD_FAST_Set_PointMesh_From_Body

  SUBROUTINE CD_FAST_UpdateStates_From_PointMesh(self, mesh, ErrStat, ErrMsg, output_probe)
    !! Transfer point-mesh kinematics into the OpenFAST-facing CableDyn shell. output_probe is
    !! reserved for a caller that owns and restores a complete outer state mirror.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: output_probe
    LOGICAL :: is_output_probe

    IF (.NOT. mesh_matches_module(self, mesh, ErrStat, ErrMsg)) RETURN
    is_output_probe = .FALSE.
    IF (PRESENT(output_probe)) is_output_probe = output_probe
    CALL pack_state(mesh)
    CALL CD_FAST_UpdateStates(self, mesh%q_coupled, mesh%v_coupled, mesh%a_coupled, ErrStat, ErrMsg, &
                              output_probe=is_output_probe)
    CALL map_fast_status(ErrStat, ErrMsg)
  END SUBROUTINE CD_FAST_UpdateStates_From_PointMesh

  SUBROUTINE CD_FAST_CalcOutput_To_PointMesh(self, mesh, ErrStat, ErrMsg)
    !! Calculate CableDyn loads and scatter them onto the point mesh.
    TYPE(CD_FAST_ModuleType), INTENT(INOUT) :: self
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    IF (.NOT. mesh_matches_module(self, mesh, ErrStat, ErrMsg)) RETURN
    mesh%load = CD_ZERO
    mesh%coupled_loads = CD_ZERO
    CALL CD_FAST_CalcOutput(self, mesh%coupled_loads, ErrStat, ErrMsg)
    CALL map_fast_status(ErrStat, ErrMsg)
    IF (ErrStat /= CD_FAST_MESH_OK) RETURN
    CALL unpack_load(mesh)
  END SUBROUTINE CD_FAST_CalcOutput_To_PointMesh

  SUBROUTINE CD_FAST_CalcBodyWrench_From_PointMesh(mesh, body_q, offsets_body, body_wrench, ErrStat, ErrMsg)
    !! Map point-mesh loads to one rigid-body wrench in global components.
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh
    REAL(wp), INTENT(IN) :: body_q(6)
    REAL(wp), INTENT(IN) :: offsets_body(:, :)
    REAL(wp), INTENT(OUT) :: body_wrench(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(1024) :: em

    body_wrench = CD_ZERO
    ErrStat = CD_FAST_MESH_OK
    ErrMsg = ''
    IF (.NOT. CD_FAST_PointMesh_IsInitialized(mesh)) THEN
      ErrStat = CD_FAST_MESH_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point mesh is not initialized'
      RETURN
    END IF
    IF (SIZE(offsets_body, 1) /= 3 .OR. SIZE(offsets_body, 2) /= mesh%n_point) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: offsets_body must have shape (3,n_point)'
      RETURN
    END IF
    CALL pack_load(mesh)
    CALL CD_Rigid_Wrench_From_Point_Loads(body_q, offsets_body, mesh%coupled_loads, body_wrench, es, em)
    IF (es /= CD_RIGID_OK) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: '//TRIM(em)
    END IF
  END SUBROUTINE CD_FAST_CalcBodyWrench_From_PointMesh

  LOGICAL FUNCTION mesh_matches_module(self, mesh, ErrStat, ErrMsg) RESULT(matches)
    TYPE(CD_FAST_ModuleType), INTENT(IN) :: self
    TYPE(CD_FAST_PointMeshType), INTENT(IN) :: mesh
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: fast_stat, n_coupled
    CHARACTER(1024) :: fast_msg

    matches = .FALSE.
    ErrStat = CD_FAST_MESH_OK
    ErrMsg = ''
    IF (.NOT. CD_FAST_PointMesh_IsInitialized(mesh)) THEN
      ErrStat = CD_FAST_MESH_NOT_INITIALIZED
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point mesh is not initialized'
      RETURN
    END IF
    n_coupled = CD_FAST_NCoupledDOF(self, fast_stat, fast_msg)
    IF (fast_stat /= CD_FAST_OK) THEN
      ErrStat = map_fast_code(fast_stat)
      ErrMsg = 'CableDyn_OpenFAST_Mesh: '//TRIM(fast_msg)
      RETURN
    END IF
    IF (n_coupled /= 3*mesh%n_point) THEN
      ErrStat = CD_FAST_MESH_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Mesh: point count does not match coupled DOF count'
      RETURN
    END IF
    matches = .TRUE.
  END FUNCTION mesh_matches_module

  PURE LOGICAL FUNCTION point_shape_matches(mesh, values) RESULT(matches)
    TYPE(CD_FAST_PointMeshType), INTENT(IN) :: mesh
    REAL(wp), INTENT(IN) :: values(:, :)

    matches = SIZE(values, 1) == 3 .AND. SIZE(values, 2) == mesh%n_point
  END FUNCTION point_shape_matches

  SUBROUTINE pack_state(mesh)
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh

    INTEGER :: i, base

    DO i = 1, mesh%n_point
      base = 3*(i - 1)
      mesh%q_coupled(base + 1:base + 3) = mesh%position(:, i)
      mesh%v_coupled(base + 1:base + 3) = mesh%velocity(:, i)
      mesh%a_coupled(base + 1:base + 3) = mesh%acceleration(:, i)
    END DO
  END SUBROUTINE pack_state

  SUBROUTINE unpack_state(mesh)
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh

    INTEGER :: i, base

    DO i = 1, mesh%n_point
      base = 3*(i - 1)
      mesh%position(:, i) = mesh%q_coupled(base + 1:base + 3)
      mesh%velocity(:, i) = mesh%v_coupled(base + 1:base + 3)
      mesh%acceleration(:, i) = mesh%a_coupled(base + 1:base + 3)
    END DO
  END SUBROUTINE unpack_state

  SUBROUTINE pack_load(mesh)
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh

    INTEGER :: i, base

    DO i = 1, mesh%n_point
      base = 3*(i - 1)
      mesh%coupled_loads(base + 1:base + 3) = mesh%load(:, i)
    END DO
  END SUBROUTINE pack_load

  SUBROUTINE unpack_load(mesh)
    TYPE(CD_FAST_PointMeshType), INTENT(INOUT) :: mesh

    INTEGER :: i, base

    DO i = 1, mesh%n_point
      base = 3*(i - 1)
      mesh%load(:, i) = mesh%coupled_loads(base + 1:base + 3)
    END DO
  END SUBROUTINE unpack_load

  SUBROUTINE map_fast_status(ErrStat, ErrMsg)
    INTEGER, INTENT(INOUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg

    IF (ErrStat == CD_FAST_OK) THEN
      ErrStat = CD_FAST_MESH_OK
    ELSE
      ErrStat = map_fast_code(ErrStat)
      ErrMsg = 'CableDyn_OpenFAST_Mesh: '//TRIM(ErrMsg)
    END IF
  END SUBROUTINE map_fast_status

  PURE INTEGER FUNCTION map_fast_code(FastStat) RESULT(MeshStat)
    INTEGER, INTENT(IN) :: FastStat

    SELECT CASE (FastStat)
    CASE (CD_FAST_OK)
      MeshStat = CD_FAST_MESH_OK
    CASE (CD_FAST_BADINPUT)
      MeshStat = CD_FAST_MESH_BADINPUT
    CASE (CD_FAST_NOT_INITIALIZED)
      MeshStat = CD_FAST_MESH_NOT_INITIALIZED
    CASE (CD_FAST_ALLOCFAIL)
      MeshStat = CD_FAST_MESH_ALLOCFAIL
    CASE DEFAULT
      MeshStat = CD_FAST_MESH_SOLVEFAIL
    END SELECT
  END FUNCTION map_fast_code

END MODULE CableDyn_OpenFAST_Mesh
