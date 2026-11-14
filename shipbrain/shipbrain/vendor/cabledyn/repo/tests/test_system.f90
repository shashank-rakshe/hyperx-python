! File: tests/test_system.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_system
  !! Lifecycle gate for CableDyn_System, the multi-line persistent owner described
  !! in ARCHITECTURE.md and doc/coupling_boundary.md. This test verifies the
  !! first product-level aggregate boundary: initialized line models become one
  !! system object with compact coupled motion and load exchange.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_End_Model, CD_MODEL_OK, &
                            CD_Get_Model_EndNodeMassDiag
  USE CableDyn_System, ONLY: CD_SystemType, CD_SystemPointType, CD_LineEndpointBinding, &
                             CD_Init_System_From_Models, CD_Init_System_From_Points, CD_End_System, &
                             CD_System_NLines, CD_System_NCoupledDOF, CD_System_Line_NDOF, &
                             CD_System_Line_NElem, CD_Get_System_CoupledMotion, &
                             CD_Get_System_Line_State, CD_Get_System_Line_Tension, &
                             CD_Update_System_CoupledMotion, CD_Step_System, CD_Calc_System_CoupledLoads, &
                             CD_Update_System_Line_External_Loads, CD_Recompute_System_Acceleration, &
                             CD_Update_System_Point_Fluid_Fields, CD_Update_System_Point_States, &
                             CD_Get_System_Point_State, &
                             CD_Step_System_DynamicPoints, CD_Detach_System_LineEnds, &
                             CD_Update_System_Line_SegmentLength, &
                             CD_Get_System_PointBlocks, CD_System_Snapshot, CD_System_Restore, &
                             CD_System_Is_Initialized, CD_SYSTEM_OK, CD_SYSTEM_BADINPUT, &
                             CD_SYSTEM_NOT_INITIALIZED, CD_POINT_FIXED, CD_POINT_COUPLED, &
                             CD_POINT_FREE, CD_POINT_CONNECT, CD_LINE_END_A, CD_LINE_END_B
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_system_lifecycle_and_aggregate_loads()
  CALL case_shared_coupled_point_mapping()
  CALL case_system_aggregate_step()
  CALL case_system_line_step_failure_restores_all_lines()
  CALL case_point_binding_initializer()
  CALL case_dynamic_free_point_step()
  CALL case_dynamic_free_point_massless()
  CALL case_detach_line_ends()
  CALL case_detach_rollback()
  CALL case_segment_length_update_diag()
  CALL case_dynamic_point_prescribed_coupled_motion()
  CALL case_dynamic_point_line_path_prescribed_motion()
  CALL case_dynamic_free_point_hydro()
  CALL case_dynamic_free_point_zero_density_no_hydro()
  CALL case_zero_coupled_map()
  CALL case_system_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_System aggregate lifecycle'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE init_bar(model, x0, x1, ErrStat, ErrMsg)
    !! Initialize one fully coupled one-element bar.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: x0, x1
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 1), fixed(6)
    REAL(wp) :: q0(6), v0(6), l0(1), ea(1), rho_a(1), f_ext(6)

    conn(:, 1) = [1, 2]
    fixed = [1, 2, 3, 4, 5, 6]
    q0 = [x0, 0.0_wp, 0.0_wp, x1, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    l0 = [1.0_wp]
    ea = [100.0_wp]
    rho_a = [5.0_wp]
    f_ext = 0.0_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .TRUE., f_ext, fixed, cfg, ErrStat, ErrMsg)
  END SUBROUTINE init_bar

  SUBROUTINE init_free_bar(model, x0, x1, ErrStat, ErrMsg)
    !! Initialize one fully free one-element bar with no coupled exchange DOFs.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: x0, x1
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, 1), fixed(0)
    REAL(wp) :: q0(6), v0(6), l0(1), ea(1), rho_a(1), f_ext(6)

    conn(:, 1) = [1, 2]
    q0 = [x0, 0.0_wp, 0.0_wp, x1, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    l0 = [1.0_wp]
    ea = [100.0_wp]
    rho_a = [5.0_wp]
    f_ext = 0.0_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .TRUE., f_ext, fixed, cfg, ErrStat, ErrMsg)
  END SUBROUTINE init_free_bar

  SUBROUTINE init_zero_density_pair(system, with_hydro_coeffs, ErrStat, ErrMsg)
    !! Build the same two-bar Free-point system, optionally with inert hydro columns.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    LOGICAL, INTENT(IN) :: with_hydro_coeffs
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    REAL(wp) :: fluid_velocity(3, 3), fluid_acceleration(3, 3), waterline_z(3)
    INTEGER :: es
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, -1.0_wp], mass=10.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    IF (with_hydro_coeffs) THEN
      points(2)%volume = 0.25_wp
      points(2)%cda = 4.0_wp
      points(2)%ca = 2.0_wp
    END IF
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) RETURN
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODEL_OK) THEN
      CALL CD_End_Model(models(1), es, em)
      RETURN
    END IF
    CALL CD_Init_System_From_Points(system, models, points, bindings, ErrStat, ErrMsg)
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)
    IF (ErrStat /= CD_SYSTEM_OK .OR. .NOT. with_hydro_coeffs) RETURN

    fluid_velocity = 0.0_wp
    fluid_acceleration = 0.0_wp
    waterline_z = 0.0_wp
    fluid_velocity(1, 2) = 5.0_wp
    fluid_acceleration(3, 2) = 10.0_wp
    CALL CD_Update_System_Point_Fluid_Fields(system, fluid_velocity, fluid_acceleration, waterline_z, &
                                             0.0_wp, ErrStat, ErrMsg)
  END SUBROUTINE init_zero_density_pair

  SUBROUTINE step_zero_density_pair(system, qout, vout, aout, ErrStat, ErrMsg)
    !! Apply identical initial motion and advance one dynamic-point step.
    TYPE(CD_SystemType), INTENT(INOUT) :: system
    REAL(wp), INTENT(OUT) :: qout(9), vout(9), aout(9)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: q(9), v(9), a(9)
    INTEGER :: n_iter
    LOGICAL :: converged, stalled

    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, -1.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    v(4) = 0.3_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYSTEM_OK) RETURN
    IF (.NOT. converged .OR. stalled) THEN
      ErrStat = CD_SYSTEM_BADINPUT
      ErrMsg = 'zero-density paired step did not converge'
      RETURN
    END IF
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, ErrStat, ErrMsg)
  END SUBROUTINE step_zero_density_pair

  SUBROUTINE case_system_lifecycle_and_aggregate_loads()
    !! Two line models are owned behind one compact system boundary.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    INTEGER :: es, n
    REAL(wp) :: q(12), v(12), a(12), q2(12), v2(12), a2(12), loads(12), f_ext(6)
    CHARACTER(240) :: em

    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'system:init-line-1')
    CALL init_bar(models(2), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'system:init-line-2')
    CALL CD_Init_System_From_Models(system, models, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. CD_System_Is_Initialized(system), 'system:init')
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    n = CD_System_NLines(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 2, 'system:nlines')
    n = CD_System_NCoupledDOF(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 12, 'system:ncoupled')
    n = CD_System_Line_NDOF(system, 1, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 6, 'system:line-ndof')
    n = CD_System_Line_NElem(system, 2, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 1, 'system:line-nelem')

    CALL CD_Get_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'system:get-motion')
    q2 = q
    v2 = 0.0_wp
    a2 = 0.0_wp
    q2(4) = 1.2_wp
    q2(10) = 1.1_wp
    CALL CD_Update_System_CoupledMotion(system, q2, v2, a2, es, em)
    CALL require(es == CD_SYSTEM_OK, 'system:update-motion')
    CALL CD_Get_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(q - q2) < 1.0e-12_wp, 'system:motion-roundtrip')
    CALL CD_Calc_System_CoupledLoads(system, loads, es, em)
    CALL require(es == CD_SYSTEM_OK, 'system:loads')
    CALL require(ABS(loads(1) - 20.0_wp) < 1.0e-12_wp, 'system:line1-left')
    CALL require(ABS(loads(4) + 20.0_wp) < 1.0e-12_wp, 'system:line1-right')
    CALL require(ABS(loads(7) - 10.0_wp) < 1.0e-12_wp, 'system:line2-left')
    CALL require(ABS(loads(10) + 10.0_wp) < 1.0e-12_wp, 'system:line2-right')

    f_ext = 0.0_wp
    f_ext(1) = 5.0_wp
    CALL CD_Update_System_Line_External_Loads(system, 1, f_ext, es, em)
    CALL require(es == CD_SYSTEM_OK, 'system:update-line-load')
    CALL CD_Recompute_System_Acceleration(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'system:recompute')
    CALL CD_Calc_System_CoupledLoads(system, loads, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. ABS(loads(1) - 25.0_wp) < 1.0e-12_wp, 'system:line-load-effect')

    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. .NOT. CD_System_Is_Initialized(system), 'system:end')
  END SUBROUTINE case_system_lifecycle_and_aggregate_loads

  SUBROUTINE case_shared_coupled_point_mapping()
    !! A coupled map collapses line endpoint DOFs onto one shared system point.
    !! Line 1 right endpoint and line 2 left endpoint both map to system DOFs 4:6;
    !! their x-loads sum at the shared point.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    INTEGER :: es, n
    INTEGER :: map(12)
    REAL(wp) :: q(9), v(9), a(9), loads(9)
    CHARACTER(240) :: em

    map = [1, 2, 3, 4, 5, 6, 4, 5, 6, 7, 8, 9]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'shared:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'shared:init-line-2')
    CALL CD_Init_System_From_Models(system, models, es, em, coupled_dof_map=map)
    CALL require(es == CD_SYSTEM_OK, 'shared:init-system')
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    n = CD_System_NCoupledDOF(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 9, 'shared:ncoupled')
    CALL CD_Get_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'shared:get-consistent')
    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.3_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'shared:update-motion')
    CALL CD_Calc_System_CoupledLoads(system, loads, es, em)
    CALL require(es == CD_SYSTEM_OK, 'shared:loads')
    CALL require(ABS(loads(1) - 20.0_wp) < 1.0e-12_wp, 'shared:left-anchor')
    CALL require(ABS(loads(4) + 10.0_wp) < 1.0e-12_wp, 'shared:middle-summed')
    CALL require(ABS(loads(7) + 10.0_wp) < 1.0e-12_wp, 'shared:right-anchor')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'shared:end')
  END SUBROUTINE case_shared_coupled_point_mapping

  SUBROUTINE case_system_aggregate_step()
    !! The system owner can advance all lines with mapped coupled point motion.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    INTEGER :: es, n_iter
    INTEGER :: map(12)
    REAL(wp) :: q(9), v(9), a(9), qout(9), vout(9), aout(9), loads(9)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    map = [1, 2, 3, 4, 5, 6, 4, 5, 6, 7, 8, 9]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'step:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'step:init-line-2')
    CALL CD_Init_System_From_Models(system, models, es, em, coupled_dof_map=map)
    CALL require(es == CD_SYSTEM_OK, 'step:init-system')
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.1_wp, 0.0_wp, 0.0_wp, 2.2_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Step_System(system, 0.01_wp, q, v, a, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'step:advance: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qout - q) < 1.0e-12_wp, 'step:motion-roundtrip')
    CALL CD_Calc_System_CoupledLoads(system, loads, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. ABS(loads(4)) < 1.0e-10_wp, 'step:shared-equilibrated-load')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'step:end')
  END SUBROUTINE case_system_aggregate_step

  SUBROUTINE case_system_line_step_failure_restores_all_lines()
    !! If a later line fails after an earlier line has advanced, the system owner
    !! restores all line q/v/a state from its rollback workspace.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    INTEGER :: es, n_iter
    REAL(wp) :: q(12), v(12), a(12), qref(6), vref(6), aref(6), qout(6), vout(6), aout(6)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'step-rollback:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'step-rollback:init-line-2')
    CALL CD_Init_System_From_Models(system, models, es, em)
    CALL require(es == CD_SYSTEM_OK, 'step-rollback:init-system')
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    CALL CD_Get_System_Line_State(system, 1, qref, vref, aref, es, em)
    CALL require(es == CD_SYSTEM_OK, 'step-rollback:get-line1-before')
    CALL CD_Get_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'step-rollback:get-coupled-before')
    q(4) = 1.2_wp
    v = 0.0_wp
    a = 0.0_wp
    system%lines(2)%f_ext(1) = IEEE_VALUE(system%lines(2)%f_ext(1), IEEE_QUIET_NAN)
    CALL CD_Step_System(system, 0.01_wp, q, v, a, converged, stalled, n_iter, es, em)
    CALL require(es /= CD_SYSTEM_OK .AND. .NOT. converged .AND. .NOT. stalled .AND. n_iter == 0, &
                 'step-rollback:failed-step-status')
    CALL CD_Get_System_Line_State(system, 1, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qout - qref) < 1.0e-12_wp .AND. &
                 nan_max_abs(vout - vref) < 1.0e-12_wp .AND. &
                 nan_max_abs(aout - aref) < 1.0e-12_wp, 'step-rollback:line1-restored')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'step-rollback:end')
  END SUBROUTINE case_system_line_step_failure_restores_all_lines

  SUBROUTINE case_point_binding_initializer()
    !! Product-facing point and endpoint bindings build the shared coupled map.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n
    REAL(wp) :: q(9), v(9), a(9), loads(9)
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_FIXED), &
              CD_SystemPointType(id=20, point_type=CD_POINT_COUPLED), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED)]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'points:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'points:init-line-2')
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'points:init-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    n = CD_System_NCoupledDOF(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 9, 'points:ncoupled')
    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.3_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'points:update-motion')
    CALL CD_Calc_System_CoupledLoads(system, loads, es, em)
    CALL require(es == CD_SYSTEM_OK, 'points:loads')
    CALL require(ABS(loads(4) + 10.0_wp) < 1.0e-12_wp, 'points:shared-load')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'points:end')
  END SUBROUTINE case_point_binding_initializer

  SUBROUTINE case_dynamic_free_point_step()
    !! A Free point owns mass/state and advances from the summed endpoint line load.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    REAL(wp) :: q(9), v(9), a(9), qout(9), vout(9), aout(9)
    REAL(wp) :: qref(3), vref(3), aref(3), qpt(3), vpt(3), apt(3)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, 0.0_wp], mass=10.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'dynpoint:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'dynpoint:init-line-2')
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint:init-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint:preload-motion')
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'dynpoint:step: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint:get-motion')
    CALL require(qout(4) < q(4), 'dynpoint:free-point-moved-under-line-load')
    CALL require(vout(4) < 0.0_wp .AND. aout(4) < 0.0_wp, 'dynpoint:free-point-negative-accel')
    CALL CD_Get_System_Point_State(system, 20, qref, vref, aref, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint:get-point-before-failed-step')
    system%points(2)%force(1) = IEEE_VALUE(system%points(2)%force(1), IEEE_QUIET_NAN)
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es /= CD_SYSTEM_OK .AND. .NOT. converged .AND. .NOT. stalled .AND. n_iter == 0, &
                 'dynpoint:failed-step-status')
    CALL CD_Get_System_Point_State(system, 20, qpt, vpt, apt, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qpt - qref) < 1.0e-12_wp .AND. &
                 nan_max_abs(vpt - vref) < 1.0e-12_wp .AND. &
                 nan_max_abs(apt - aref) < 1.0e-12_wp, 'dynpoint:failed-step-restores-point')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint:end')
  END SUBROUTINE case_dynamic_free_point_step

  SUBROUTINE case_dynamic_free_point_massless()
    !! A MASSLESS Free point advances stably on the attached lines' end-node
    !! consistent-mass diagonal share, treated implicitly (the MoorDyn zero-mass
    !! Connect-junction pattern and the line-failure detach point). The rig is
    !! exact: two tension-only bars (EA=100, l0=1, rho_a=5) with the junction at
    !! x=1.2 -- bar 1 carries T = 100*0.2 = 20 N, bar 2 is slack, and the total
    !! end-node mass is 2*(5*1/3) = 10/3 kg; with bar 1's axial stiffness advanced
    !! implicitly the first-step acceleration is EXACTLY -20/(10/3 + dt^2*100). A
    !! double-counted end-node share would nearly halve it; the pre-fix step divides
    !! by zero. The second step checks the lagged-inertia add-back: the reaction
    !! carries -diag*a_lag, the step removes it, so
    !! a_2 = (-EA*(q_x - 1) - dt*EA*v_x)/(10/3 + dt^2*EA) at the advanced q_x.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    REAL(wp) :: q(9), v(9), a(9), qout(9), vout(9), aout(9)
    REAL(wp) :: md, diag_total, dt, a1, qx, vx, a2
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, 0.0_wp], mass=0.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'massless:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'massless:init-line-2')

    ! Accessor sanity on the exact rig value before the system consumes it.
    CALL CD_Get_Model_EndNodeMassDiag(models(1), 1, md, es, em)
    CALL require(es == CD_MODEL_OK .AND. ABS(md - 5.0_wp/3.0_wp) < 1.0e-14_wp, 'massless:diag-slot-1')
    CALL CD_Get_Model_EndNodeMassDiag(models(1), 2, md, es, em)
    CALL require(es == CD_MODEL_OK .AND. ABS(md - 5.0_wp/3.0_wp) < 1.0e-14_wp, 'massless:diag-slot-2')
    CALL CD_Get_Model_EndNodeMassDiag(models(1), 3, md, es, em)
    CALL require(es /= CD_MODEL_OK, 'massless:diag-bad-slot-fails')

    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'massless:init-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)
    diag_total = 10.0_wp/3.0_wp
    CALL require(ABS(system%points(2)%line_mass_diag - diag_total) < 1.0e-14_wp, 'massless:precomputed-diag')

    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'massless:preload-motion')
    dt = 0.01_wp
    CALL CD_Step_System_DynamicPoints(system, dt, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'massless:step-1: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'massless:get-motion-1')
    ! The taut bar's end-segment axial stiffness EA/l0 = 100 is advanced implicitly
    ! (the slack bar contributes none): effective mass diag + dt^2*100.
    a1 = -100.0_wp*0.2_wp/(diag_total + dt*dt*100.0_wp)
    CALL require(ABS(aout(4) - a1) < 1.0e-9_wp, 'massless:step-1-exact-acceleration')
    vx = dt*a1
    qx = 1.2_wp + dt*vx
    CALL require(ABS(qout(4) - qx) < 1.0e-12_wp .AND. ABS(vout(4) - vx) < 1.0e-12_wp, &
                 'massless:step-1-exact-kinematics')

    ! Step 2: the summed reaction now carries -diag*a_lag with a_lag = a1; the step
    ! must add that product back so the acceleration is the elastic value at the
    ! advanced position (with the implicit stiffness correction -dt*K*v) -- a sign
    ! error here is grossly visible (|error| ~ 2*|a1|).
    CALL CD_Step_System_DynamicPoints(system, dt, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'massless:step-2: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'massless:get-motion-2')
    a2 = (-100.0_wp*(qx - 1.0_wp) - dt*100.0_wp*vx)/(diag_total + dt*dt*100.0_wp)
    CALL require(ABS(aout(4) - a2) < 1.0e-9_wp, 'massless:step-2-lagged-inertia-removed')
    CALL require(ABS(qout(4) - (qx + dt*(vx + dt*a2))) < 1.0e-12_wp, 'massless:step-2-exact-position')

    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'massless:end')
  END SUBROUTINE case_dynamic_free_point_massless

  SUBROUTINE case_detach_line_ends()
    !! Line-failure detach on the reserve-point pre-allocation: an INACTIVE reserve
    !! Free point owns a frozen coupled block from init (the exchange extent already
    !! covers it), and CD_Detach_System_LineEnds moves a listed line end onto it at
    !! the failing point's committed kinematics WITHOUT moving any other block.
    !! Exact physics on the two-bar massless-junction rig: before detach the
    !! junction carries both bars (share 10/3, a1 = -20/(10/3 + dt^2*100)); after
    !! detaching bar 2 the junction keeps only bar 1 (share 5/3), so the same 0.2
    !! stretch gives a = -20/(5/3 + dt^2*100) exactly (bar 1's axial stiffness 100 is
    !! advanced implicitly), and the freed end on the slack bar reads 0.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(5)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    INTEGER, ALLOCATABLE :: blocks(:)
    REAL(wp) :: q(15), v(15), a(15), qout(15), vout(15), aout(15)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, 0.0_wp], mass=0.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=40, point_type=CD_POINT_FREE, q=[0.0_wp, 0.0_wp, 0.0_wp], mass=0.0_wp, &
                                 active=.FALSE.), &
              CD_SystemPointType(id=50, point_type=CD_POINT_FREE, q=[0.0_wp, 0.0_wp, 0.0_wp], mass=0.0_wp, &
                                 active=.FALSE.)]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'detach:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'detach:init-line-2')
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:init-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    ! The reserves own blocks 4-5 from init: extent 15, tiled point blocks.
    CALL require(CD_System_NCoupledDOF(system, es, em) == 15, 'detach:reserved-extent')
    CALL CD_Get_System_PointBlocks(system, blocks, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. SIZE(blocks) == 5 .AND. ALL(blocks == [1, 2, 3, 4, 5]), &
                 'detach:blocks-tile-with-reserve')

    ! Ordering independence: a caller may list reserves ANYWHERE in the points
    ! array (input/ID order); bound points still take the low compact blocks and
    ! reserves the blocks above, so init succeeds and the blocks tile with the
    ! reserves LAST regardless of array position.
    CALL CD_End_System(system, es, em)
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL CD_Init_System_From_Points(system, models, [points(4), points(1), points(2), points(3), points(5)], &
                                    bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:reserve-first-init: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)
    CALL CD_Get_System_PointBlocks(system, blocks, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. SIZE(blocks) == 5 .AND. ALL(blocks == [2, 3, 4, 1, 5]), &
                 'detach:reserve-first-blocks-tile-reserves-last')
    CALL CD_End_System(system, es, em)
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:reinit-after-ordering-check: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    ! Fail-closed battery before any detach.
    CALL CD_Detach_System_LineEnds(system, 20, [2], 99, es, em)
    CALL require(es /= CD_SYSTEM_OK, 'detach:unknown-reserve-fails')
    CALL CD_Detach_System_LineEnds(system, 20, [2], 30, es, em)
    CALL require(es /= CD_SYSTEM_OK, 'detach:active-target-fails')
    CALL CD_Detach_System_LineEnds(system, 20, [1], 40, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:junction-line-1-valid: '//TRIM(em))
    CALL CD_End_System(system, es, em)

    ! Rebuild fresh and run the exact-physics sequence.
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:reinit-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)
    q = 0.0_wp
    q(1:9) = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:preload-motion')

    CALL CD_Detach_System_LineEnds(system, 20, [2], 40, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:detach-line-2: '//TRIM(em))
    CALL require(system%points(4)%active, 'detach:reserve-activated')
    CALL require(nan_max_abs(system%points(4)%q - [1.2_wp, 0.0_wp, 0.0_wp]) < 1.0e-12_wp, &
                 'detach:reserve-at-committed-kinematics')
    CALL require(ABS(system%points(2)%line_mass_diag - 5.0_wp/3.0_wp) < 1.0e-14_wp, 'detach:old-point-diag')
    CALL require(ABS(system%points(4)%line_mass_diag - 5.0_wp/3.0_wp) < 1.0e-14_wp, 'detach:new-point-diag')

    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'detach:post-detach-step: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:get-motion')
    ! Junction (block 2): only bar 1 pulls now -- a = -EA*0.2/(5/3 + dt^2*EA/l0) exactly
    ! (bar 1's axial stiffness is advanced implicitly).
    CALL require(ABS(aout(4) - (-20.0_wp/(5.0_wp/3.0_wp + 0.01_wp))) < 1.0e-9_wp, &
                 'detach:junction-single-bar-exact')
    ! Freed end (block 4): bar 2 is slack (length 0.8 < 1, tension-only) -- no load.
    CALL require(nan_max_abs(aout(10:12)) < 1.0e-9_wp, 'detach:freed-end-slack-zero')
    ! The freed end's block never moved: blocks still tile in init order.
    CALL CD_Get_System_PointBlocks(system, blocks, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. SIZE(blocks) == 5 .AND. ALL(blocks == [1, 2, 3, 4, 5]), &
                 'detach:blocks-stable-after-detach')

    ! Detach the LAST line too: the massless junction is left with no attached
    ! lines and no mass of its own -- the primitive deactivates it, and the next
    ! step must succeed with the second reserve carrying bar 1's share.
    CALL CD_Detach_System_LineEnds(system, 20, [1], 50, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:detach-line-1: '//TRIM(em))
    CALL require(.NOT. system%points(2)%active, 'detach:stripped-massless-junction-deactivated')
    CALL require(system%points(5)%active .AND. &
                 ABS(system%points(5)%line_mass_diag - 5.0_wp/3.0_wp) < 1.0e-14_wp, &
                 'detach:second-reserve-carries-bar-1')
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'detach:step-after-full-strip: '//TRIM(em))
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'detach:end')
  END SUBROUTINE case_detach_line_ends

  SUBROUTINE case_detach_rollback()
    !! A detach fired between CD_System_Snapshot and CD_System_Restore must roll
    !! back COMPLETELY -- point states AND the detach topology (bindings + exchange
    !! map). Post-restore the massless junction carries both bars again, so the
    !! step reads the pre-detach exact acceleration (-6, not the single-bar -12),
    !! and the reserve is inactive with a zero share.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(4)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    REAL(wp) :: q(12), v(12), a(12), qout(12), vout(12), aout(12)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, 0.0_wp], mass=0.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=40, point_type=CD_POINT_FREE, q=[0.0_wp, 0.0_wp, 0.0_wp], mass=0.0_wp, &
                                 active=.FALSE.)]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'rollback:init-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)
    q = 0.0_wp
    q(1:9) = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'rollback:preload-motion')

    CALL CD_System_Snapshot(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'rollback:snapshot: '//TRIM(em))
    CALL CD_Detach_System_LineEnds(system, 20, [2], 40, es, em)
    CALL require(es == CD_SYSTEM_OK, 'rollback:detach: '//TRIM(em))
    CALL CD_System_Restore(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'rollback:restore: '//TRIM(em))

    CALL require(.NOT. system%points(4)%active, 'rollback:reserve-inactive-again')
    CALL require(ABS(system%points(4)%line_mass_diag) <= 0.0_wp, 'rollback:reserve-share-zero')
    CALL require(ABS(system%points(2)%line_mass_diag - 10.0_wp/3.0_wp) < 1.0e-14_wp, &
                 'rollback:junction-share-restored')
    CALL require(ALL([(system%bindings(es)%point_id, es=1, 4)] == [10, 20, 20, 30]), &
                 'rollback:bindings-restored')
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'rollback:step: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'rollback:get-motion')
    CALL require(ABS(aout(4) - (-20.0_wp/(10.0_wp/3.0_wp + 0.01_wp))) < 1.0e-9_wp, &
                 'rollback:pre-detach-exact-acceleration')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'rollback:end')
  END SUBROUTINE case_detach_rollback

  SUBROUTINE case_segment_length_update_diag()
    !! Active line control at the system level: updating a line's element length
    !! through the system wrapper must move the bound massless junction's implicit
    !! end-node share. Exact rig: bars l0=1 (junction share 10/3); paying bar 2 out
    !! to l0=1.2 makes its end share 5*1.2/3 = 2, total 5/3 + 2 = 11/3, and at the
    !! stretched preload (bar 1 T=20, bar 2 slack) the first-step acceleration is
    !! EXACTLY -20/(11/3 + dt^2*100) (bar 1's axial stiffness advanced implicitly).
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    REAL(wp) :: q(9), v(9), a(9), qout(9), vout(9), aout(9)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, 0.0_wp], mass=0.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'seglen-sys:init: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    CALL CD_Update_System_Line_SegmentLength(system, 2, 1, 1.2_wp, 0.0_wp, es, em)
    CALL require(es == CD_SYSTEM_OK, 'seglen-sys:update: '//TRIM(em))
    CALL require(ABS(system%points(2)%line_mass_diag - 11.0_wp/3.0_wp) < 1.0e-14_wp, &
                 'seglen-sys:junction-share-recomputed')

    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'seglen-sys:preload')
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged, 'seglen-sys:step: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'seglen-sys:get')
    CALL require(ABS(aout(4) - (-20.0_wp/(11.0_wp/3.0_wp + 0.01_wp))) < 1.0e-9_wp, 'seglen-sys:exact-acceleration')

    ! fail-closed: bad line index
    CALL CD_Update_System_Line_SegmentLength(system, 9, 1, 1.0_wp, 0.0_wp, es, em)
    CALL require(es /= CD_SYSTEM_OK, 'seglen-sys:bad-line-fails')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'seglen-sys:end')
  END SUBROUTINE case_segment_length_update_diag

  SUBROUTINE case_dynamic_point_prescribed_coupled_motion()
    !! Regression: a Coupled point whose host-prescribed position changes between dynamic-point
    !! steps must drive the bound line endpoint to the prescribed motion. Before the fix,
    !! CD_Step_System_DynamicPoints read the lines' previous-step endpoints (via
    !! CD_Get_System_CoupledMotion) and silently ignored the motion stored in system%points by
    !! CD_Update_System_Point_States, so the coupled endpoint stayed at its old z. Pre-fix the
    !! coupled DOF read back after the step is the stale value (z = 0); post-fix it is the
    !! prescribed z = -0.5. This is the OpenFAST/FMF/C-API dynamic-point caller pattern.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    REAL(wp) :: q(9), v(9), a(9), qout(9), vout(9), aout(9)
    REAL(wp) :: qline(6), vline(6), aline(6), qline2(6), vline2(6), aline2(6)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_COUPLED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, 0.0_wp], mass=10.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'dynpoint-prescribed:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'dynpoint-prescribed:init-line-2')
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-prescribed:init-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-prescribed:preload-motion')

    ! Prescribe a NEW position for the Coupled point (id=10, coupled DOFs 1-3) through the
    ! point-state path the OpenFAST/FMF/C-API callers use, leaving the Free/Fixed points at
    ! their current motion, then take a dynamic-point step.
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-prescribed:get-before')
    qout(3) = -0.5_wp
    CALL CD_Update_System_Point_States(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-prescribed:update-point-states: '//TRIM(em))
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'dynpoint-prescribed:step: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-prescribed:get-after')
    CALL require(ABS(qout(3) - (-0.5_wp)) < 1.0e-9_wp, 'dynpoint-prescribed:coupled-endpoint-follows-host')

    ! A failure AFTER the prescribed-motion scatter must roll the LINES back to the step-entry
    ! state, not leave them at the scatter while only the points are restored. Capture the
    ! converged line state, prescribe a fresh move, inject a non-finite Free-point force to fail
    ! the step, and require the line state to return to the captured entry value.
    CALL CD_Get_System_Line_State(system, 1, qline, vline, aline, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-prescribed:capture-line')
    qout(3) = -0.9_wp
    CALL CD_Update_System_Point_States(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-prescribed:represcribe')
    system%points(2)%force(1) = IEEE_VALUE(system%points(2)%force(1), IEEE_QUIET_NAN)
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es /= CD_SYSTEM_OK, 'dynpoint-prescribed:failed-step-status')
    CALL CD_Get_System_Line_State(system, 1, qline2, vline2, aline2, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qline2 - qline) < 1.0e-12_wp .AND. &
                 nan_max_abs(vline2 - vline) < 1.0e-12_wp .AND. nan_max_abs(aline2 - aline) < 1.0e-12_wp, &
                 'dynpoint-prescribed:failed-step-restores-lines')

    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-prescribed:end')
  END SUBROUTINE case_dynamic_point_prescribed_coupled_motion

  SUBROUTINE case_dynamic_point_line_path_prescribed_motion()
    !! Regression for the second prescribed-motion path: a Coupled endpoint applied through
    !! CD_Update_System_CoupledMotion (which sets the line state directly) must survive a
    !! dynamic-point step. The step treats system%points as the authoritative prescribed motion
    !! and overrides the Coupled/Fixed DOFs from it, so CD_Update_System_CoupledMotion must keep
    !! system%points in sync -- otherwise the freshly line-applied motion (z = -0.5) is reset to
    !! the stale init point cache (z = 0) and the step advances with the wrong prescribed motion.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    REAL(wp) :: q(9), v(9), a(9), qout(9), vout(9), aout(9)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_COUPLED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, 0.0_wp], mass=10.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'dynpoint-linepath:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'dynpoint-linepath:init-line-2')
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-linepath:init-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    ! Move the Coupled point (id=10, DOFs 1-3) to z = -0.5 through the LINE path, differing from
    ! the init point cache (z = 0), then take a dynamic-point step.
    q = [0.0_wp, 0.0_wp, -0.5_wp, 1.2_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-linepath:update-coupled-motion')
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'dynpoint-linepath:step: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-linepath:get-after')
    CALL require(ABS(qout(3) - (-0.5_wp)) < 1.0e-9_wp, 'dynpoint-linepath:coupled-endpoint-preserved')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-linepath:end')
  END SUBROUTINE case_dynamic_point_line_path_prescribed_motion

  SUBROUTINE case_dynamic_free_point_hydro()
    !! Point CdA/Ca add lumped drag and added mass to the Free-point step.
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    INTEGER :: es, n_iter
    REAL(wp) :: q(9), v(9), a(9), qout(9), vout(9), aout(9)
    REAL(wp) :: fluid_velocity(3, 3), fluid_acceleration(3, 3), waterline_z(3)
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=10, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=20, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, -1.0_wp], &
                                 mass=10.0_wp, volume=0.01_wp, cda=2.0_wp, ca=1.0_wp), &
              CD_SystemPointType(id=30, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=10), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=20), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=30)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'dynpoint-hydro:init-line-1')
    CALL init_bar(models(2), 1.0_wp, 2.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'dynpoint-hydro:init-line-2')
    CALL CD_Init_System_From_Points(system, models, points, bindings, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-hydro:init-system: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)

    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, -1.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    a = 0.0_wp
    fluid_velocity = 0.0_wp
    fluid_acceleration = 0.0_wp
    fluid_velocity(1, 2) = 1.0_wp
    fluid_acceleration(3, 2) = 0.5_wp
    waterline_z = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-hydro:preload-motion')
    CALL CD_Update_System_Point_Fluid_Fields(system, fluid_velocity, fluid_acceleration, waterline_z, &
                                             1000.0_wp, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-hydro:update-fluid: '//TRIM(em))
    CALL CD_Step_System_DynamicPoints(system, 0.01_wp, converged, stalled, n_iter, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. converged .AND. .NOT. stalled, 'dynpoint-hydro:step: '//TRIM(em))
    CALL CD_Get_System_CoupledMotion(system, qout, vout, aout, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-hydro:get-motion')
    CALL require(aout(4) > 0.0_wp .AND. vout(4) > 0.0_wp, 'dynpoint-hydro:drag-accelerates-free-point')
    CALL require(aout(6) > 0.0_wp .AND. vout(6) > 0.0_wp, 'dynpoint-hydro:fk-accelerates-free-point')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-hydro:end')
  END SUBROUTINE case_dynamic_free_point_hydro

  SUBROUTINE case_dynamic_free_point_zero_density_no_hydro()
    !! Nonzero point CdA/Ca/fluid kinematics must be inert when fluid density is zero.
    TYPE(CD_SystemType) :: system_ref, system_hydro
    REAL(wp) :: qref(9), vref(9), aref(9), qhyd(9), vhyd(9), ahyd(9)
    INTEGER :: es
    CHARACTER(240) :: em

    CALL init_zero_density_pair(system_ref, .FALSE., es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-zero-rho:init-ref: '//TRIM(em))
    CALL init_zero_density_pair(system_hydro, .TRUE., es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-zero-rho:init-hydro: '//TRIM(em))

    CALL step_zero_density_pair(system_ref, qref, vref, aref, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-zero-rho:step-ref: '//TRIM(em))
    CALL step_zero_density_pair(system_hydro, qhyd, vhyd, ahyd, es, em)
    CALL require(es == CD_SYSTEM_OK, 'dynpoint-zero-rho:step-hydro: '//TRIM(em))

    CALL require(nan_max_abs(qhyd - qref) < 1.0e-12_wp, 'dynpoint-zero-rho:q unchanged by undeclared hydro')
    CALL require(nan_max_abs(vhyd - vref) < 1.0e-12_wp, 'dynpoint-zero-rho:v unchanged by undeclared hydro')
    CALL require(nan_max_abs(ahyd - aref) < 1.0e-12_wp, 'dynpoint-zero-rho:a unchanged by undeclared hydro')
    CALL CD_End_System(system_ref, es, em)
    CALL CD_End_System(system_hydro, es, em)
  END SUBROUTINE case_dynamic_free_point_zero_density_no_hydro

  SUBROUTINE case_zero_coupled_map()
    !! An explicitly supplied zero-length map is valid when no line exposes
    !! coupled DOFs; it must not route through MAXVAL on an empty array.
    TYPE(CD_ModelType) :: models(1)
    TYPE(CD_SystemType) :: system
    INTEGER :: es, n
    INTEGER :: zero_map(0)
    CHARACTER(240) :: em

    CALL init_free_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'zero-map:init-free-line: '//TRIM(em))
    CALL CD_Init_System_From_Models(system, models, es, em, coupled_dof_map=zero_map)
    CALL require(es == CD_SYSTEM_OK .AND. CD_System_Is_Initialized(system), 'zero-map:init-system: '//TRIM(em))
    n = CD_System_NCoupledDOF(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 0, 'zero-map:ncoupled-zero')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'zero-map:end-system')
    CALL CD_End_Model(models(1), es, em)
    CALL require(es == CD_MODEL_OK, 'zero-map:end-line')
  END SUBROUTINE case_zero_coupled_map

  SUBROUTINE case_system_fail_closed()
    !! Malformed system inputs fail closed without leaving initialized ownership.
    TYPE(CD_ModelType) :: models(1)
    TYPE(CD_SystemType) :: system
    TYPE(CD_SystemPointType) :: points_bad_id(1), points_dup(2), points_ok(2), points_extra(3), points_bad_free(1)
    TYPE(CD_LineEndpointBinding) :: bindings_bad(2), bindings_dup(2)
    INTEGER :: es, n
    INTEGER :: bad_map_short(5), bad_map_zero(6), bad_map_gap(6)
    REAL(wp) :: q(6), v(6), a(6), bad(5), qpt(3), vpt(3), apt(3), qref(3), tension(1)
    CHARACTER(240) :: em

    q = 0.0_wp
    v = 0.0_wp
    a = 0.0_wp
    CALL CD_Init_System_From_Models(system, models, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:uninit-line')
    n = CD_System_NLines(system, es, em)
    CALL require(es == CD_SYSTEM_NOT_INITIALIZED .AND. n == 0, 'fail:nlines-uninit')
    q = 123.0_wp
    v = 456.0_wp
    a = 789.0_wp
    CALL CD_Get_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_NOT_INITIALIZED .AND. nan_max_abs(q) < 1.0e-12_wp .AND. &
                 nan_max_abs(v) < 1.0e-12_wp .AND. nan_max_abs(a) < 1.0e-12_wp, 'fail:get-motion-uninit')
    q = 123.0_wp
    v = 456.0_wp
    a = 789.0_wp
    CALL CD_Get_System_Line_State(system, 1, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_NOT_INITIALIZED .AND. nan_max_abs(q) < 1.0e-12_wp .AND. &
                 nan_max_abs(v) < 1.0e-12_wp .AND. nan_max_abs(a) < 1.0e-12_wp, 'fail:line-state-uninit')
    tension = 123.0_wp
    CALL CD_Get_System_Line_Tension(system, 1, tension, es, em)
    CALL require(es == CD_SYSTEM_NOT_INITIALIZED .AND. nan_max_abs(tension) < 1.0e-12_wp, &
                 'fail:line-tension-uninit')

    CALL init_bar(models(1), 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_MODEL_OK, 'fail:init-line')
    bad_map_short = [1, 2, 3, 4, 5]
    CALL CD_Init_System_From_Models(system, models, es, em, coupled_dof_map=bad_map_short)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:map-short')
    bad_map_zero = [1, 2, 3, 4, 5, 0]
    CALL CD_Init_System_From_Models(system, models, es, em, coupled_dof_map=bad_map_zero)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:map-zero')
    bad_map_gap = [1, 2, 3, 5, 5, 6]
    CALL CD_Init_System_From_Models(system, models, es, em, coupled_dof_map=bad_map_gap)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:map-gap')
    points_bad_id(1) = CD_SystemPointType(id=0, point_type=CD_POINT_COUPLED)
    bindings_bad = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                    CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=1)]
    CALL CD_Init_System_From_Points(system, models, points_bad_id, bindings_bad, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:point-id')
    ! Zero mass is VALID for a bound Free/Connect point (the attached end-node
    ! consistent-mass diagonal share carries it); only NEGATIVE mass is rejected.
    points_bad_free(1) = CD_SystemPointType(id=1, point_type=CD_POINT_CONNECT, mass=-1.0_wp)
    CALL CD_Init_System_From_Points(system, models, points_bad_free, bindings_bad, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:connect-mass')
    points_dup = [CD_SystemPointType(id=1, point_type=CD_POINT_COUPLED), &
                  CD_SystemPointType(id=1, point_type=CD_POINT_COUPLED)]
    CALL CD_Init_System_From_Points(system, models, points_dup, bindings_bad, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:point-duplicate')
    points_ok = [CD_SystemPointType(id=1, point_type=CD_POINT_COUPLED), &
                 CD_SystemPointType(id=2, point_type=CD_POINT_COUPLED)]
    bindings_bad = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                    CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=3)]
    CALL CD_Init_System_From_Points(system, models, points_ok, bindings_bad, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:unknown-point')
    bindings_dup = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                    CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=2)]
    CALL CD_Init_System_From_Points(system, models, points_ok, bindings_dup, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. .NOT. CD_System_Is_Initialized(system), 'fail:duplicate-end')
    points_extra = [CD_SystemPointType(id=1, point_type=CD_POINT_COUPLED), &
                    CD_SystemPointType(id=2, point_type=CD_POINT_COUPLED), &
                    CD_SystemPointType(id=3, point_type=CD_POINT_FIXED)]
    bindings_bad = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                    CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2)]
    CALL CD_Init_System_From_Points(system, models, points_extra, bindings_bad, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. CD_System_Is_Initialized(system), 'fail:output-only-point-ok')
    q(1:6) = [1.0_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v(1:6) = 0.0_wp
    a(1:6) = 0.0_wp
    CALL CD_Update_System_Point_States(system, q(1:6), v(1:6), a(1:6), es, em)
    CALL require(es == CD_SYSTEM_OK, 'fail:output-only-point-update')
    CALL CD_Get_System_Point_State(system, 1, qref, vpt, apt, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qref - [1.0_wp, 0.0_wp, 0.0_wp]) < 1.0e-12_wp, &
                 'fail:point-update-query')
    q(1) = IEEE_VALUE(q(1), IEEE_QUIET_NAN)
    CALL CD_Update_System_Point_States(system, q(1:6), v(1:6), a(1:6), es, em)
    CALL require(es == CD_SYSTEM_BADINPUT, 'fail:point-nonfinite-motion')
    CALL CD_Get_System_Point_State(system, 1, qpt, vpt, apt, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qpt - qref) < 1.0e-12_wp, &
                 'fail:point-nonfinite-preserves-state')
    q(1) = 1.0_wp
    CALL CD_Init_System_From_Models(system, models, es, em, coupled_dof_map=bad_map_short)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. CD_System_Is_Initialized(system), &
                 'fail:bad-model-reinit-preserves-system')
    n = CD_System_NCoupledDOF(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 6, 'fail:bad-model-reinit-preserves-ncoupled')
    CALL CD_Get_System_Point_State(system, 1, qpt, vpt, apt, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qpt - qref) < 1.0e-12_wp, &
                 'fail:bad-model-reinit-preserves-point-state')
    bindings_bad = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                    CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=99)]
    CALL CD_Init_System_From_Points(system, models, points_ok, bindings_bad, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. CD_System_Is_Initialized(system), &
                 'fail:bad-point-reinit-preserves-system')
    n = CD_System_NLines(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 1, 'fail:bad-point-reinit-preserves-nlines')
    CALL CD_Get_System_Point_State(system, 1, qpt, vpt, apt, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qpt - qref) < 1.0e-12_wp, &
                 'fail:bad-point-reinit-preserves-point-state')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fail:output-only-point-end')
    CALL CD_Init_System_From_Models(system, models, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fail:init-system')
    CALL CD_Init_System_From_Models(system, models, es, em, coupled_dof_map=bad_map_short)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. CD_System_Is_Initialized(system), 'fail:bad-reinit-preserves-system')
    n = CD_System_NLines(system, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. n == 1, 'fail:bad-reinit-preserves-nlines')
    CALL CD_End_Model(models(1), es, em)
    bad = 0.0_wp
    CALL CD_Update_System_CoupledMotion(system, bad, q, a, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT, 'fail:bad-motion-shape')
    q(2) = IEEE_VALUE(q(2), IEEE_QUIET_NAN)
    CALL CD_Update_System_CoupledMotion(system, q, v, a, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT, 'fail:nonfinite-motion')
    n = CD_System_Line_NDOF(system, 2, es, em)
    CALL require(es == CD_SYSTEM_BADINPUT .AND. n == 0, 'fail:bad-line-index')
    CALL CD_End_System(system, es, em)
    CALL require(es == CD_SYSTEM_OK, 'fail:end')
  END SUBROUTINE case_system_fail_closed

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_system
