! File: tests/test_openfast_touchdown.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_openfast_touchdown
  !! End-to-end production gate for the maintained IEA-15 MW mixed mooring + dynamic-cable
  !! example. It uses the OpenFAST aggregate at 40 Hz, enables the host-fluid surface, verifies
  !! a multi-node grounded run (not merely a seabed endpoint), and drives all platform attachments
  !! through a finite surge/heave trajectory in a uniform current.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_Fallback_Count, CD_AGG_Fallback_Reset, &
                                         CD_AGG_ModuleType, CD_AGG_Init_From_Deck, &
                                         CD_AGG_NMovingPoints, CD_AGG_NFluidNodes, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_SetFluidFields, &
                                         CD_AGG_Step_Moving, CD_AGG_CalcOutput, CD_AGG_End, CD_AGG_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: DT = 0.025_wp, DURATION = 20.0_wp, PERIOD = 10.0_wp
  REAL(wp), PARAMETER :: SURGE = 2.0_wp, HEAVE = 1.0_wp
  TYPE(CD_AGG_ModuleType) :: agg
  CHARACTER(1024) :: deck
  CHARACTER(512) :: em
  REAL(wp), ALLOCATABLE :: p0(:, :), p(:, :), v(:, :), a(:, :), load(:, :)
  REAL(wp), ALLOCATABLE :: fv(:, :), fa(:, :), wl(:)
  REAL(wp) :: t, omega, ramp, ramp_d, ramp_dd, phase, pi, min_cable_z
  INTEGER :: es, ncp, nf, i, s, nstep, ni, nfail, grounded_nodes, iter_max, stalled_count
  LOGICAL :: converged, stalled

  nfail = 0
  IF (COMMAND_ARGUMENT_COUNT() < 1) THEN
    WRITE (*, '(A)') 'FAIL: touchdown example deck path argument required'
    ERROR STOP 1
  END IF
  CALL GET_COMMAND_ARGUMENT(1, deck)
  CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DT, es, em, external_fluid=.TRUE.)
  CALL require(es == CD_AGG_OK, 'touchdown aggregate init: '//TRIM(em))
  IF (es /= CD_AGG_OK) ERROR STOP 1

  CALL require(ALLOCATED(agg%cables) .AND. SIZE(agg%cables) == 1, 'one finite-EI power cable is built')
  CALL require(agg%cables(1)%line%has_contact, 'finite-EI contact is installed')
  CALL require(.NOT. agg%cables(1)%line%has_contact_bathymetry, 'example selects the flat 200 m seabed')
  CALL require(ABS(agg%cables(1)%line%contact_mu - 0.35_wp) <= 0.0_wp, 'declared contact friction is installed')
  grounded_nodes = 0
  min_cable_z = HUGE(1.0_wp)
  DO i = 1, SIZE(agg%cables(1)%line%q)/6
    min_cable_z = MIN(min_cable_z, agg%cables(1)%line%q(6*(i - 1) + 3))
    IF (ABS(agg%cables(1)%line%q(6*(i - 1) + 3) + 200.0_wp) <= 0.5_wp) &
      grounded_nodes = grounded_nodes + 1
  END DO
  CALL require(grounded_nodes >= 3, 'static cable has a multi-node grounded run')
  CALL require(min_cable_z >= -200.5_wp, 'static cable does not penetrate materially below the bed')

  ncp = CD_AGG_NMovingPoints(agg, es, em)
  nf = CD_AGG_NFluidNodes(agg, es, em)
  CALL require(es == CD_AGG_OK .AND. ncp == 4 .AND. nf > 0, 'four coupled ends and host-fluid nodes are exposed')
  ALLOCATE (p0(3, ncp), p(3, ncp), v(3, ncp), a(3, ncp), load(3, ncp))
  ALLOCATE (fv(3, nf), fa(3, nf), wl(nf))
  CALL CD_AGG_GetMovingPointMesh(agg, p0, v, a, load, es, em)
  CALL require(es == CD_AGG_OK .AND. ALL(IEEE_IS_FINITE(load)), 'finite static coupled loads')

  fv = 0.0_wp
  fv(1, :) = 0.5_wp
  fa = 0.0_wp
  wl = 0.0_wp
  pi = ACOS(-1.0_wp)
  omega = 2.0_wp*pi/PERIOD
  nstep = NINT(DURATION/DT)
  iter_max = 0
  stalled_count = 0
  CALL CD_AGG_Fallback_Reset(agg)
  DO s = 1, nstep
    t = REAL(s, wp)*DT
    phase = omega*t
    ! Half-cosine startup over one period; analytic derivatives avoid an artificial velocity jump.
    ramp = 0.5_wp*(1.0_wp - COS(pi*MIN(t/PERIOD, 1.0_wp)))
    IF (t < PERIOD) THEN
      ramp_d = 0.5_wp*pi/PERIOD*SIN(pi*t/PERIOD)
      ramp_dd = 0.5_wp*(pi/PERIOD)**2*COS(pi*t/PERIOD)
    ELSE
      ramp_d = 0.0_wp
      ramp_dd = 0.0_wp
    END IF
    p = p0
    p(1, :) = p0(1, :) + SURGE*ramp*SIN(phase)
    p(3, :) = p0(3, :) + HEAVE*ramp*COS(phase)
    v = 0.0_wp
    v(1, :) = SURGE*(ramp_d*SIN(phase) + ramp*omega*COS(phase))
    v(3, :) = HEAVE*(ramp_d*COS(phase) - ramp*omega*SIN(phase))
    a = 0.0_wp
    a(1, :) = SURGE*(ramp_dd*SIN(phase) + 2.0_wp*ramp_d*omega*COS(phase) - &
                     ramp*omega*omega*SIN(phase))
    a(3, :) = HEAVE*(ramp_dd*COS(phase) - 2.0_wp*ramp_d*omega*SIN(phase) - &
                     ramp*omega*omega*COS(phase))
    CALL CD_AGG_SetFluidFields(agg, fv, fa, wl, es, em)
    IF (es == CD_AGG_OK) THEN
      CALL CD_AGG_Step_Moving(agg, DT, p, v, a, converged, stalled, ni, es, em, t_committed=t)
    END IF
    IF (es /= CD_AGG_OK .OR. .NOT. converged) THEN
      WRITE (*, '(A,F8.3,A)') 'FAIL: touchdown step at t=', t, ' s: '//TRIM(em)
      nfail = nfail + 1
      EXIT
    END IF
    IF (stalled) stalled_count = stalled_count + 1
    iter_max = MAX(iter_max, ni)
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, load, es, em)
    IF (es /= CD_AGG_OK .OR. .NOT. ALL(IEEE_IS_FINITE(load))) THEN
      CALL require(.FALSE., 'finite coupled loads throughout touchdown trajectory')
      EXIT
    END IF
  END DO
  CALL require(CD_AGG_Fallback_Count(agg) == 0, 'no EI=0 adaptive-substep fallback at 40 Hz')
  CALL require(stalled_count == 0, 'no aggregate nonlinear-stall recovery at 40 Hz')
  CALL require(iter_max <= 40, 'bounded nonlinear iterations over the touchdown trajectory')
  WRITE (*, '(A,I0,A,I0)') 'touchdown gate: grounded nodes=', grounded_nodes, ', max Newton iterations=', iter_max
  CALL CD_AGG_End(agg, es, em)
  CALL require(es == CD_AGG_OK, 'touchdown aggregate End')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: OpenFAST finite-EI touchdown example at dtM=0.025 s'

CONTAINS
  SUBROUTINE require(condition, message)
    LOGICAL, INTENT(IN) :: condition
    CHARACTER(*), INTENT(IN) :: message
    IF (.NOT. condition) THEN
      WRITE (*, '(A)') 'MISMATCH: '//TRIM(message)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require
END PROGRAM test_openfast_touchdown
