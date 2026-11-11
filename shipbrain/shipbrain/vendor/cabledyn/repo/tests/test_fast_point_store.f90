! File: tests/test_fast_point_store.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_fast_point_store
  !! Point-store consistency of the OpenFAST shell step (CD_FAST_Step, shared by the FMF,
  !! aggregate and C API step paths):
  !!  (1) a system without Free/Connect points steps through CD_Step_System, which moves
  !!      only the lines; the committed prescribed kinematics must also reach the point
  !!      store, so point queries (and the Point<N>p* channels that read them) follow the
  !!      host motion instead of staying at the Init positions;
  !!  (2) a FAILED dynamic-point step must leave every point at its step-entry state (the
  !!      prescribed t+dt kinematics are written to the store before the step starts).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_End_Model, CD_MODEL_OK
  USE CableDyn_System, ONLY: CD_SystemPointType, CD_LineEndpointBinding, CD_Get_System_Point_State, &
                             CD_POINT_FIXED, CD_POINT_COUPLED, CD_POINT_FREE, CD_LINE_END_A, CD_LINE_END_B, &
                             CD_SYSTEM_OK
  USE CableDyn_OpenFAST, ONLY: CD_FAST_ModuleType, CD_FAST_Init_From_Points, CD_FAST_Step, CD_FAST_End, &
                               CD_FAST_GetCoupledMotion, CD_FAST_OK
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_prescribed_points_follow_step()
  CALL case_failed_dynamic_step_restores_points()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: OpenFAST shell point store'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_prescribed_points_follow_step()
    !! Fixed - bar - Coupled - bar - Fixed, no dynamic points: several host steps move
    !! the Coupled point; after each, the store holds exactly the committed kinematics.
    TYPE(CD_FAST_ModuleType) :: module
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    REAL(wp) :: q(9), v(9), a(9), qp(3), vp(3), ap(3)
    INTEGER :: es, n_iter, k
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=1, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=2, point_type=CD_POINT_COUPLED, q=[1.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=3, point_type=CD_POINT_FIXED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=3)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp)
    CALL init_bar(models(2), 1.0_wp, 2.0_wp)
    CALL CD_FAST_Init_From_Points(module, models, points, bindings, es, em)
    CALL require(es == CD_FAST_OK, 'prescribed:init: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)
    CALL CD_FAST_GetCoupledMotion(module, q, v, a, es, em)
    CALL require(es == CD_FAST_OK, 'prescribed:get-motion')
    DO k = 1, 5
      q(4:6) = [1.0_wp + 0.02_wp*k, 0.0_wp, 0.01_wp*k]
      v(4:6) = [0.2_wp, 0.0_wp, 0.1_wp]
      a(4:6) = [0.0_wp, 0.0_wp, 0.3_wp*k]
      CALL CD_FAST_Step(module, 0.1_wp, q, v, a, converged, stalled, n_iter, es, em)
      CALL require(es == CD_FAST_OK, 'prescribed:step: '//TRIM(em))
      CALL CD_Get_System_Point_State(module%system, 2, qp, vp, ap, es, em)
      CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qp - q(4:6)) <= 0.0_wp .AND. &
                   nan_max_abs(vp - v(4:6)) <= 0.0_wp .AND. nan_max_abs(ap - a(4:6)) <= 0.0_wp, &
                   'prescribed:coupled-point-store-follows-step')
      CALL CD_Get_System_Point_State(module%system, 3, qp, vp, ap, es, em)
      CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qp - q(7:9)) <= 0.0_wp, &
                   'prescribed:fixed-point-store-follows-step')
    END DO
    CALL CD_FAST_End(module, es, em)
    CALL require(.NOT. ALLOCATED(module%points_entry), 'prescribed:end-releases-point-snapshot')
  END SUBROUTINE case_prescribed_points_follow_step

  SUBROUTINE case_failed_dynamic_step_restores_points()
    !! Fixed - bar - Free - bar - Coupled: a converging step commits, then a step that
    !! the dynamic-point integrator rejects fails; the store must be exactly the
    !! committed step-entry state and the next valid step must still succeed.
    TYPE(CD_FAST_ModuleType) :: module
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemPointType) :: points(3), entry(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    REAL(wp) :: q(9), v(9), a(9), qbad(9), vbad(9), abad(9), qp(3), vp(3), ap(3)
    INTEGER :: es, n_iter, i
    LOGICAL :: converged, stalled
    CHARACTER(240) :: em

    points = [CD_SystemPointType(id=1, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp]), &
              CD_SystemPointType(id=2, point_type=CD_POINT_FREE, q=[1.0_wp, 0.0_wp, 0.0_wp], mass=1.0_wp), &
              CD_SystemPointType(id=3, point_type=CD_POINT_COUPLED, q=[2.0_wp, 0.0_wp, 0.0_wp])]
    bindings = [CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1), &
                CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=2), &
                CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=3)]
    CALL init_bar(models(1), 0.0_wp, 1.0_wp)
    CALL init_bar(models(2), 1.0_wp, 2.0_wp)
    CALL CD_FAST_Init_From_Points(module, models, points, bindings, es, em)
    CALL require(es == CD_FAST_OK, 'failed-step:init: '//TRIM(em))
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)
    CALL CD_FAST_GetCoupledMotion(module, q, v, a, es, em)
    CALL require(es == CD_FAST_OK, 'failed-step:get-motion')
    q(7) = 2.01_wp
    v(7) = 0.1_wp
    CALL CD_FAST_Step(module, 0.01_wp, q, v, a, converged, stalled, n_iter, es, em)
    CALL require(es == CD_FAST_OK, 'failed-step:first-step: '//TRIM(em))
    ! Invalidate the Free point's mass so the dynamic-point step fails its own point
    ! validation AFTER the shell committed the t+dt Coupled kinematics to the store.
    module%system%points(2)%mass = -1.0_wp
    entry = module%system%points
    qbad = q
    qbad(7:9) = [2.5_wp, 0.3_wp, -0.2_wp]
    vbad = v
    vbad(7:9) = [4.0_wp, 5.0_wp, 6.0_wp]
    abad = a
    abad(7:9) = [7.0_wp, 8.0_wp, 9.0_wp]
    CALL CD_FAST_Step(module, 0.01_wp, qbad, vbad, abad, converged, stalled, n_iter, es, em)
    CALL require(es /= CD_FAST_OK, 'failed-step:invalid-point-step-fails')
    DO i = 1, 3
      CALL CD_Get_System_Point_State(module%system, i, qp, vp, ap, es, em)
      CALL require(es == CD_SYSTEM_OK .AND. nan_max_abs(qp - entry(i)%q) <= 0.0_wp .AND. &
                   nan_max_abs(vp - entry(i)%v) <= 0.0_wp .AND. nan_max_abs(ap - entry(i)%a) <= 0.0_wp, &
                   'failed-step:point-store-restored-to-step-entry')
    END DO
    module%system%points(2)%mass = 1.0_wp
    q(7) = 2.02_wp
    CALL CD_FAST_Step(module, 0.01_wp, q, v, a, converged, stalled, n_iter, es, em)
    CALL require(es == CD_FAST_OK, 'failed-step:recovery-step: '//TRIM(em))
    CALL CD_Get_System_Point_State(module%system, 3, qp, vp, ap, es, em)
    CALL require(es == CD_SYSTEM_OK .AND. ABS(qp(1) - 2.02_wp) <= 0.0_wp, 'failed-step:recovery-store')
    CALL CD_FAST_End(module, es, em)
  END SUBROUTINE case_failed_dynamic_step_restores_points

  SUBROUTINE init_bar(model, x0, x1)
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: x0, x1
    !! Four-element taut bar (interior DOFs, so a line step can genuinely fail).
    INTEGER, PARAMETER :: NE = 4
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, NE), fixed(6), es, e
    REAL(wp) :: q0(3*(NE + 1)), v0(3*(NE + 1)), l0(NE), ea(NE), rho_a(NE), f_ext(3*(NE + 1))
    CHARACTER(240) :: em
    q0 = 0.0_wp
    DO e = 1, NE
      conn(:, e) = [e, e + 1]
    END DO
    DO e = 0, NE
      q0(3*e + 1) = x0 + (x1 - x0)*REAL(e, wp)/REAL(NE, wp)
    END DO
    fixed = [1, 2, 3, 3*NE + 1, 3*NE + 2, 3*NE + 3]
    v0 = 0.0_wp
    l0 = 0.99_wp/REAL(NE, wp)
    ea = 100.0_wp
    rho_a = 5.0_wp
    f_ext = 0.0_wp
    CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .TRUE., f_ext, fixed, cfg, es, em)
    IF (es /= CD_MODEL_OK) THEN
      WRITE (*, '(A)') 'bar init failed: '//TRIM(em)
      ERROR STOP 2
    END IF
  END SUBROUTINE init_bar

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (cond) RETURN
    nfail = nfail + 1
    WRITE (*, '(A)') 'FAIL: '//label
  END SUBROUTINE require
END PROGRAM test_fast_point_store
