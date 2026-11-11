! File: src/CableDyn_OpenFAST_Types.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_OpenFAST_Types
  !! Registry-ready OpenFAST-facing CableDyn type surface.
  !!
  !! This module corresponds to doc/coupling_boundary.md and mirrors the
  !! OpenFAST module split between input, output, parameter, continuous-state,
  !! discrete-state, constraint-state, and other-state objects. The current
  !! implementation is intentionally compact: the coupled exchange vectors are
  !! allocatable arrays that can be lifted directly into an OpenFAST registry file.
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  USE CableDyn_Precision, ONLY: wp, CD_ZERO
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_InitInputType
  PUBLIC :: CD_InitOutputType
  PUBLIC :: CD_InputType
  PUBLIC :: CD_OutputType
  PUBLIC :: CD_ParameterType
  PUBLIC :: CD_ContinuousStateType
  PUBLIC :: CD_DiscreteStateType
  PUBLIC :: CD_ConstraintStateType
  PUBLIC :: CD_OtherStateType
  PUBLIC :: CD_OpenFAST_Types_InitExchange
  PUBLIC :: CD_OpenFAST_Types_EndExchange
  PUBLIC :: CD_OpenFAST_Types_InitStates
  PUBLIC :: CD_OpenFAST_Types_EndStates
  PUBLIC :: CD_OpenFAST_Types_CopyInput
  PUBLIC :: CD_OpenFAST_Types_CopyOutput
  PUBLIC :: CD_OpenFAST_Types_CopyParameters
  PUBLIC :: CD_OpenFAST_Types_CopyContinuousState
  PUBLIC :: CD_OpenFAST_Types_CopyConstraintState
  PUBLIC :: CD_OpenFAST_Types_CopyDiscreteState
  PUBLIC :: CD_OpenFAST_Types_CopyOtherState

  INTEGER, PARAMETER, PUBLIC :: CD_TYPES_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_TYPES_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_TYPES_ALLOCFAIL = 2

  TYPE :: CD_InitInputType
    !! OpenFAST initialization input exchange.
    INTEGER :: n_coupled_dof = 0
    REAL(wp) :: dt = CD_ZERO
    REAL(wp) :: gravity = 9.80665_wp
    REAL(wp) :: rho_water = 1025.0_wp
  END TYPE CD_InitInputType

  TYPE :: CD_InitOutputType
    !! OpenFAST initialization output exchange.
    INTEGER :: n_lines = 0
    INTEGER :: n_coupled_dof = 0
  END TYPE CD_InitOutputType

  TYPE :: CD_InputType
    !! Coupled kinematics supplied by OpenFAST.
    REAL(wp), ALLOCATABLE :: q_coupled(:)
    REAL(wp), ALLOCATABLE :: v_coupled(:)
    REAL(wp), ALLOCATABLE :: a_coupled(:)
  END TYPE CD_InputType

  TYPE :: CD_OutputType
    !! Coupled loads and tight-coupling linearization blocks returned to OpenFAST.
    REAL(wp), ALLOCATABLE :: coupled_loads(:)
    REAL(wp), ALLOCATABLE :: added_mass(:, :)
    REAL(wp), ALLOCATABLE :: dload_dq(:, :)
    REAL(wp), ALLOCATABLE :: dload_dv(:, :)
    REAL(wp), ALLOCATABLE :: dload_da(:, :)
  END TYPE CD_OutputType

  TYPE :: CD_ParameterType
    !! Stable OpenFAST parameter block for the current lifecycle shell.
    INTEGER :: n_lines = 0
    INTEGER :: n_coupled_dof = 0
    REAL(wp) :: dt = CD_ZERO
    REAL(wp) :: gravity = 9.80665_wp
    REAL(wp) :: rho_water = 1025.0_wp
  END TYPE CD_ParameterType

  TYPE :: CD_ContinuousStateType
    !! OpenFAST continuous-state exchange. The line states are owned by
    !! CableDyn_System in the current tight-coupling shell.
    REAL(wp), ALLOCATABLE :: x(:)
    REAL(wp), ALLOCATABLE :: xd(:)
  END TYPE CD_ContinuousStateType

  TYPE :: CD_DiscreteStateType
    !! OpenFAST discrete-state exchange reserved for controller/event state.
    INTEGER :: reserved = 0
  END TYPE CD_DiscreteStateType

  TYPE :: CD_ConstraintStateType
    !! OpenFAST constraint-state exchange reserved for algebraic coupling.
    REAL(wp), ALLOCATABLE :: z(:)
  END TYPE CD_ConstraintStateType

  TYPE :: CD_OtherStateType
    !! OpenFAST other-state exchange for counters and convergence metadata.
    INTEGER :: last_num_iter = 0
    LOGICAL :: last_converged = .TRUE.
    LOGICAL :: last_stalled = .FALSE.
  END TYPE CD_OtherStateType

CONTAINS

  SUBROUTINE CD_OpenFAST_Types_InitExchange(input, output, params, n_coupled_dof, ErrStat, ErrMsg)
    !! Allocate the OpenFAST coupled exchange vectors.
    TYPE(CD_InputType), INTENT(INOUT) :: input
    TYPE(CD_OutputType), INTENT(INOUT) :: output
    TYPE(CD_ParameterType), INTENT(INOUT) :: params
    INTEGER, INTENT(IN) :: n_coupled_dof
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_InputType) :: next_input
    TYPE(CD_OutputType) :: next_output
    INTEGER :: alloc_stat

    ErrStat = CD_TYPES_OK
    ErrMsg = ''
    IF (n_coupled_dof < 0) THEN
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: n_coupled_dof must be non-negative'
      RETURN
    END IF
    ! The added_mass / dload_d{q,v,a} matrices are n_coupled_dof^2; guard that product
    ! in INT64 so a corrupted/huge count cannot overflow the n*n size computation
    ! (any physical coupled-DOF count is orders of magnitude below this cap).
    IF (INT(n_coupled_dof, INT64)*INT(n_coupled_dof, INT64) > INT(HUGE(n_coupled_dof), INT64)) THEN
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: n_coupled_dof too large; n_coupled_dof^2 overflows'
      RETURN
    END IF
    ALLOCATE (next_input%q_coupled(n_coupled_dof), next_input%v_coupled(n_coupled_dof), &
              next_input%a_coupled(n_coupled_dof), next_output%coupled_loads(n_coupled_dof), &
              next_output%added_mass(n_coupled_dof, n_coupled_dof), &
              next_output%dload_dq(n_coupled_dof, n_coupled_dof), &
              next_output%dload_dv(n_coupled_dof, n_coupled_dof), &
              next_output%dload_da(n_coupled_dof, n_coupled_dof), STAT=alloc_stat)
    IF (alloc_stat /= 0) THEN
      CALL set_alloc_fail('exchange', ErrStat, ErrMsg)
      RETURN
    END IF
    next_input%q_coupled = CD_ZERO
    next_input%v_coupled = CD_ZERO
    next_input%a_coupled = CD_ZERO
    next_output%coupled_loads = CD_ZERO
    next_output%added_mass = CD_ZERO
    next_output%dload_dq = CD_ZERO
    next_output%dload_dv = CD_ZERO
    next_output%dload_da = CD_ZERO
    CALL CD_OpenFAST_Types_EndExchange(input, output)
    ! Move the freshly-allocated components in instead of an intrinsic derived-type assignment,
    ! which would re-allocate every allocatable component again without STAT (an OOM there aborts
    ! instead of returning CD_TYPES_ALLOCFAIL).
    CALL MOVE_ALLOC(next_input%q_coupled, input%q_coupled)
    CALL MOVE_ALLOC(next_input%v_coupled, input%v_coupled)
    CALL MOVE_ALLOC(next_input%a_coupled, input%a_coupled)
    CALL MOVE_ALLOC(next_output%coupled_loads, output%coupled_loads)
    CALL MOVE_ALLOC(next_output%added_mass, output%added_mass)
    CALL MOVE_ALLOC(next_output%dload_dq, output%dload_dq)
    CALL MOVE_ALLOC(next_output%dload_dv, output%dload_dv)
    CALL MOVE_ALLOC(next_output%dload_da, output%dload_da)
    params%n_coupled_dof = n_coupled_dof
  END SUBROUTINE CD_OpenFAST_Types_InitExchange

  SUBROUTINE CD_OpenFAST_Types_EndExchange(input, output)
    !! Release coupled exchange vectors. Idempotent by design.
    TYPE(CD_InputType), INTENT(INOUT) :: input
    TYPE(CD_OutputType), INTENT(INOUT) :: output

    IF (ALLOCATED(input%q_coupled)) DEALLOCATE (input%q_coupled)
    IF (ALLOCATED(input%v_coupled)) DEALLOCATE (input%v_coupled)
    IF (ALLOCATED(input%a_coupled)) DEALLOCATE (input%a_coupled)
    IF (ALLOCATED(output%coupled_loads)) DEALLOCATE (output%coupled_loads)
    IF (ALLOCATED(output%added_mass)) DEALLOCATE (output%added_mass)
    IF (ALLOCATED(output%dload_dq)) DEALLOCATE (output%dload_dq)
    IF (ALLOCATED(output%dload_dv)) DEALLOCATE (output%dload_dv)
    IF (ALLOCATED(output%dload_da)) DEALLOCATE (output%dload_da)
  END SUBROUTINE CD_OpenFAST_Types_EndExchange

  SUBROUTINE CD_OpenFAST_Types_InitStates(continuous, constraint, n_continuous, n_constraint, ErrStat, ErrMsg)
    !! Allocate OpenFAST state vectors owned by the registry-facing type surface.
    TYPE(CD_ContinuousStateType), INTENT(INOUT) :: continuous
    TYPE(CD_ConstraintStateType), INTENT(INOUT) :: constraint
    INTEGER, INTENT(IN) :: n_continuous, n_constraint
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_ContinuousStateType) :: next_continuous
    TYPE(CD_ConstraintStateType) :: next_constraint
    INTEGER :: alloc_stat

    ErrStat = CD_TYPES_OK
    ErrMsg = ''
    IF (n_continuous < 0 .OR. n_constraint < 0) THEN
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: state sizes must be non-negative'
      RETURN
    END IF
    ALLOCATE (next_continuous%x(n_continuous), next_continuous%xd(n_continuous), &
              next_constraint%z(n_constraint), STAT=alloc_stat)
    IF (alloc_stat /= 0) THEN
      CALL set_alloc_fail('state', ErrStat, ErrMsg)
      RETURN
    END IF
    next_continuous%x = CD_ZERO
    next_continuous%xd = CD_ZERO
    next_constraint%z = CD_ZERO
    CALL CD_OpenFAST_Types_EndStates(continuous, constraint)
    CALL MOVE_ALLOC(next_continuous%x, continuous%x)
    CALL MOVE_ALLOC(next_continuous%xd, continuous%xd)
    CALL MOVE_ALLOC(next_constraint%z, constraint%z)
  END SUBROUTINE CD_OpenFAST_Types_InitStates

  SUBROUTINE CD_OpenFAST_Types_EndStates(continuous, constraint)
    !! Release OpenFAST state vectors. Idempotent by design.
    TYPE(CD_ContinuousStateType), INTENT(INOUT) :: continuous
    TYPE(CD_ConstraintStateType), INTENT(INOUT) :: constraint

    IF (ALLOCATED(continuous%x)) DEALLOCATE (continuous%x)
    IF (ALLOCATED(continuous%xd)) DEALLOCATE (continuous%xd)
    IF (ALLOCATED(constraint%z)) DEALLOCATE (constraint%z)
  END SUBROUTINE CD_OpenFAST_Types_EndStates

  SUBROUTINE CD_OpenFAST_Types_CopyInput(src, dst, ErrStat, ErrMsg)
    !! Deep-copy the input exchange record.
    TYPE(CD_InputType), INTENT(IN) :: src
    TYPE(CD_InputType), INTENT(INOUT) :: dst
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_InputType) :: next_dst
    INTEGER :: alloc_stat
    INTEGER :: n

    ErrStat = CD_TYPES_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src%q_coupled) .AND. .NOT. ALLOCATED(src%v_coupled) .AND. &
        .NOT. ALLOCATED(src%a_coupled)) THEN
      CALL end_input(dst)
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(src%q_coupled) .AND. ALLOCATED(src%v_coupled) .AND. ALLOCATED(src%a_coupled))) THEN
      CALL end_input(dst)
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: input copy requires q/v/a to be allocated together'
      RETURN
    END IF
    n = SIZE(src%q_coupled)
    IF (SIZE(src%v_coupled) /= n .OR. SIZE(src%a_coupled) /= n) THEN
      CALL end_input(dst)
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: input copy vector sizes must match'
      RETURN
    END IF
    ALLOCATE (next_dst%q_coupled(n), next_dst%v_coupled(n), next_dst%a_coupled(n), STAT=alloc_stat)
    IF (alloc_stat /= 0) THEN
      CALL set_alloc_fail('input copy', ErrStat, ErrMsg)
      RETURN
    END IF
    next_dst%q_coupled = src%q_coupled
    next_dst%v_coupled = src%v_coupled
    next_dst%a_coupled = src%a_coupled
    CALL end_input(dst)
    CALL MOVE_ALLOC(next_dst%q_coupled, dst%q_coupled)
    CALL MOVE_ALLOC(next_dst%v_coupled, dst%v_coupled)
    CALL MOVE_ALLOC(next_dst%a_coupled, dst%a_coupled)
  END SUBROUTINE CD_OpenFAST_Types_CopyInput

  SUBROUTINE CD_OpenFAST_Types_CopyOutput(src, dst, ErrStat, ErrMsg)
    !! Deep-copy the output exchange and linearization record.
    TYPE(CD_OutputType), INTENT(IN) :: src
    TYPE(CD_OutputType), INTENT(INOUT) :: dst
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_OutputType) :: next_dst
    INTEGER :: alloc_stat
    INTEGER :: n

    ErrStat = CD_TYPES_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src%coupled_loads) .AND. .NOT. ALLOCATED(src%added_mass) .AND. &
        .NOT. ALLOCATED(src%dload_dq) .AND. .NOT. ALLOCATED(src%dload_dv) .AND. &
        .NOT. ALLOCATED(src%dload_da)) THEN
      CALL end_output(dst)
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(src%coupled_loads) .AND. ALLOCATED(src%added_mass) .AND. &
               ALLOCATED(src%dload_dq) .AND. ALLOCATED(src%dload_dv) .AND. ALLOCATED(src%dload_da))) THEN
      CALL end_output(dst)
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: output copy requires all arrays to be allocated together'
      RETURN
    END IF
    n = SIZE(src%coupled_loads)
    IF (.NOT. square_shape(src%added_mass, n) .OR. .NOT. square_shape(src%dload_dq, n) .OR. &
        .NOT. square_shape(src%dload_dv, n) .OR. .NOT. square_shape(src%dload_da, n)) THEN
      CALL end_output(dst)
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: output copy matrix sizes must match coupled_loads'
      RETURN
    END IF
    ALLOCATE (next_dst%coupled_loads(n), next_dst%added_mass(n, n), next_dst%dload_dq(n, n), &
              next_dst%dload_dv(n, n), next_dst%dload_da(n, n), STAT=alloc_stat)
    IF (alloc_stat /= 0) THEN
      CALL set_alloc_fail('output copy', ErrStat, ErrMsg)
      RETURN
    END IF
    next_dst%coupled_loads = src%coupled_loads
    next_dst%added_mass = src%added_mass
    next_dst%dload_dq = src%dload_dq
    next_dst%dload_dv = src%dload_dv
    next_dst%dload_da = src%dload_da
    CALL end_output(dst)
    CALL MOVE_ALLOC(next_dst%coupled_loads, dst%coupled_loads)
    CALL MOVE_ALLOC(next_dst%added_mass, dst%added_mass)
    CALL MOVE_ALLOC(next_dst%dload_dq, dst%dload_dq)
    CALL MOVE_ALLOC(next_dst%dload_dv, dst%dload_dv)
    CALL MOVE_ALLOC(next_dst%dload_da, dst%dload_da)
  END SUBROUTINE CD_OpenFAST_Types_CopyOutput

  SUBROUTINE CD_OpenFAST_Types_CopyParameters(src, dst)
    !! Copy scalar parameter data.
    TYPE(CD_ParameterType), INTENT(IN) :: src
    TYPE(CD_ParameterType), INTENT(OUT) :: dst

    dst = src
  END SUBROUTINE CD_OpenFAST_Types_CopyParameters

  SUBROUTINE CD_OpenFAST_Types_CopyContinuousState(src, dst, ErrStat, ErrMsg)
    !! Deep-copy continuous-state vectors.
    TYPE(CD_ContinuousStateType), INTENT(IN) :: src
    TYPE(CD_ContinuousStateType), INTENT(INOUT) :: dst
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_ContinuousStateType) :: next_dst
    INTEGER :: alloc_stat
    INTEGER :: n

    ErrStat = CD_TYPES_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src%x) .AND. .NOT. ALLOCATED(src%xd)) THEN
      CALL end_continuous(dst)
      RETURN
    END IF
    IF (.NOT. (ALLOCATED(src%x) .AND. ALLOCATED(src%xd))) THEN
      CALL end_continuous(dst)
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: continuous-state copy requires x/xd together'
      RETURN
    END IF
    n = SIZE(src%x)
    IF (SIZE(src%xd) /= n) THEN
      CALL end_continuous(dst)
      ErrStat = CD_TYPES_BADINPUT
      ErrMsg = 'CableDyn_OpenFAST_Types: continuous-state vector sizes must match'
      RETURN
    END IF
    ALLOCATE (next_dst%x(n), next_dst%xd(n), STAT=alloc_stat)
    IF (alloc_stat /= 0) THEN
      CALL set_alloc_fail('continuous-state copy', ErrStat, ErrMsg)
      RETURN
    END IF
    next_dst%x = src%x
    next_dst%xd = src%xd
    CALL end_continuous(dst)
    CALL MOVE_ALLOC(next_dst%x, dst%x)
    CALL MOVE_ALLOC(next_dst%xd, dst%xd)
  END SUBROUTINE CD_OpenFAST_Types_CopyContinuousState

  SUBROUTINE CD_OpenFAST_Types_CopyConstraintState(src, dst, ErrStat, ErrMsg)
    !! Deep-copy constraint-state vectors.
    TYPE(CD_ConstraintStateType), INTENT(IN) :: src
    TYPE(CD_ConstraintStateType), INTENT(INOUT) :: dst
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_ConstraintStateType) :: next_dst
    INTEGER :: alloc_stat

    ErrStat = CD_TYPES_OK
    ErrMsg = ''
    IF (.NOT. ALLOCATED(src%z)) THEN
      IF (ALLOCATED(dst%z)) DEALLOCATE (dst%z)
      RETURN
    END IF
    ALLOCATE (next_dst%z(SIZE(src%z)), STAT=alloc_stat)
    IF (alloc_stat /= 0) THEN
      CALL set_alloc_fail('constraint-state copy', ErrStat, ErrMsg)
      RETURN
    END IF
    next_dst%z = src%z
    IF (ALLOCATED(dst%z)) DEALLOCATE (dst%z)
    CALL MOVE_ALLOC(next_dst%z, dst%z)
  END SUBROUTINE CD_OpenFAST_Types_CopyConstraintState

  SUBROUTINE CD_OpenFAST_Types_CopyDiscreteState(src, dst)
    !! Copy scalar discrete-state data.
    TYPE(CD_DiscreteStateType), INTENT(IN) :: src
    TYPE(CD_DiscreteStateType), INTENT(OUT) :: dst

    dst = src
  END SUBROUTINE CD_OpenFAST_Types_CopyDiscreteState

  SUBROUTINE CD_OpenFAST_Types_CopyOtherState(src, dst)
    !! Copy scalar other-state data.
    TYPE(CD_OtherStateType), INTENT(IN) :: src
    TYPE(CD_OtherStateType), INTENT(OUT) :: dst

    dst = src
  END SUBROUTINE CD_OpenFAST_Types_CopyOtherState

  PURE LOGICAL FUNCTION square_shape(values, n) RESULT(ok)
    REAL(wp), INTENT(IN) :: values(:, :)
    INTEGER, INTENT(IN) :: n

    ok = SIZE(values, 1) == n .AND. SIZE(values, 2) == n
  END FUNCTION square_shape

  SUBROUTINE end_input(input)
    TYPE(CD_InputType), INTENT(INOUT) :: input

    IF (ALLOCATED(input%q_coupled)) DEALLOCATE (input%q_coupled)
    IF (ALLOCATED(input%v_coupled)) DEALLOCATE (input%v_coupled)
    IF (ALLOCATED(input%a_coupled)) DEALLOCATE (input%a_coupled)
  END SUBROUTINE end_input

  SUBROUTINE end_output(output)
    TYPE(CD_OutputType), INTENT(INOUT) :: output

    IF (ALLOCATED(output%coupled_loads)) DEALLOCATE (output%coupled_loads)
    IF (ALLOCATED(output%added_mass)) DEALLOCATE (output%added_mass)
    IF (ALLOCATED(output%dload_dq)) DEALLOCATE (output%dload_dq)
    IF (ALLOCATED(output%dload_dv)) DEALLOCATE (output%dload_dv)
    IF (ALLOCATED(output%dload_da)) DEALLOCATE (output%dload_da)
  END SUBROUTINE end_output

  SUBROUTINE end_continuous(continuous)
    TYPE(CD_ContinuousStateType), INTENT(INOUT) :: continuous

    IF (ALLOCATED(continuous%x)) DEALLOCATE (continuous%x)
    IF (ALLOCATED(continuous%xd)) DEALLOCATE (continuous%xd)
  END SUBROUTINE end_continuous

  SUBROUTINE set_alloc_fail(context, ErrStat, ErrMsg)
    CHARACTER(*), INTENT(IN) :: context
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_TYPES_ALLOCFAIL
    ErrMsg = 'CableDyn_OpenFAST_Types: '//TRIM(context)//' allocation failed'
  END SUBROUTINE set_alloc_fail

END MODULE CableDyn_OpenFAST_Types
