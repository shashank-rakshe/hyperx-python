! File: tests/test_load_predictor.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_load_predictor
  !! The load predictor between supercycled solves (CableDyn_LoadPredictor):
  !!   * it is used only between consecutive commits (exactly one dtM apart, within 1e-6 dtM),
  !!     never without a previous commit or with a non-positive dtM;
  !!   * the elapsed fraction is clamped to [0, 1];
  !!   * at the commit (tau = 0) the served loads are the committed ones bit for bit;
  !!   * a load linear in time is reproduced, and a quadratic one t^2 is in error by exactly
  !!     tau (1 + tau) dtM^2 (second order; the hold is first order).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_LoadPredictor, ONLY: CD_Predictor_Ready, CD_Predictor_Fraction, CD_Predict_Loads
  IMPLICIT NONE

  REAL(wp), PARAMETER :: DT = 0.1_wp, TC = 37.3_wp
  REAL(wp) :: f_last(3, 2), f_prev(3, 2), f(3, 2), tau, t, expect
  INTEGER :: nfail, k

  nfail = 0

  CALL require(CD_Predictor_Ready(TC, TC - DT, DT), 'consecutive commits are ready')
  CALL require(CD_Predictor_Ready(TC, TC - DT*(1.0_wp + 0.5e-6_wp), DT), 'within 1e-6 dtM is ready')
  CALL require(.NOT. CD_Predictor_Ready(TC, TC - DT*(1.0_wp + 2.0e-6_wp), DT), 'beyond 1e-6 dtM is not ready')
  CALL require(.NOT. CD_Predictor_Ready(TC, TC - 2.0_wp*DT, DT), 'a skipped commit is not ready')
  CALL require(.NOT. CD_Predictor_Ready(TC, -1.0_wp, DT), 'no previous commit is not ready')
  CALL require(CD_Predictor_Ready(DT, 0.0_wp, DT), 'the static state at t = 0 is a previous commit')
  CALL require(.NOT. CD_Predictor_Ready(TC, TC - DT, 0.0_wp), 'a zero dtM is not ready')

  CALL require(CD_Predictor_Fraction(TC - 0.01_wp, TC, DT) == 0.0_wp, 'the fraction is not negative')
  CALL require(CD_Predictor_Fraction(TC + 2.0_wp*DT, TC, DT) == 1.0_wp, 'the fraction is at most one')
  CALL require(ABS(CD_Predictor_Fraction(TC + 0.075_wp, TC, DT) - 0.75_wp) <= 1.0e-12_wp, 'three quarters')

  ! a load linear in time, a + b t, sampled at the two commits
  DO k = 1, 2
    f_prev(:, k) = [1.0e6_wp, -2.5e5_wp, 3.0e4_wp]*REAL(k, wp) + [4.0e5_wp, 1.0e3_wp, -7.0e4_wp]*(TC - DT)
    f_last(:, k) = [1.0e6_wp, -2.5e5_wp, 3.0e4_wp]*REAL(k, wp) + [4.0e5_wp, 1.0e3_wp, -7.0e4_wp]*TC
  END DO
  CALL CD_Predict_Loads(f_last, f_prev, 0.0_wp, f)
  CALL require(ALL(f == f_last), 'at the commit the committed loads are served bit for bit')
  DO k = 1, 3
    tau = 0.25_wp*REAL(k, wp)
    t = TC + tau*DT
    CALL CD_Predict_Loads(f_last, f_prev, tau, f)
    CALL require(ALL(ABS(f(:, 2) - ([2.0e6_wp, -5.0e5_wp, 6.0e4_wp] + [4.0e5_wp, 1.0e3_wp, -7.0e4_wp]*t)) <= &
                     1.0e-9_wp*MAXVAL(ABS(f_last))), 'a linear load is reproduced')
  END DO

  ! a quadratic load t^2: error tau (1 + tau) dtM^2
  f_prev = (TC - DT)**2
  f_last = TC**2
  DO k = 1, 3
    tau = 0.25_wp*REAL(k, wp)
    t = TC + tau*DT
    CALL CD_Predict_Loads(f_last, f_prev, tau, f)
    expect = tau*(1.0_wp + tau)*DT**2
    CALL require(ABS((t**2 - f(1, 1)) - expect) <= 1.0e-9_wp*expect, 'the quadratic error is tau (1 + tau) dtM^2')
  END DO

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: load predictor (readiness, fraction, extrapolation order)'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'FAIL: '//TRIM(msg)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_load_predictor
