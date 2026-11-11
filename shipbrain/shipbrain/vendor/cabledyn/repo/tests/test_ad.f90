! File: tests/test_ad.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_ad
  !! Standalone correctness check for the forward 2nd-order AD core
  !! (CableDyn_AD Dual2). A representative scalar function of several DOFs,
  !! exercising +, -, *, /, sqrt, sin, cos, acos, atan2, is evaluated with the
  !! Dual2 chain rule and its analytic gradient / Hessian are compared against
  !! central finite differences of the SAME function written in plain reals.
  !! This proves the derivative engine in isolation before the Cosserat element
  !! is built on top of it. Gradient is checked to 1e-7 and the (FD-noisy)
  !! Hessian to 1e-5, and Hessian symmetry to 1e-12.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_AD, ONLY: Dual2, Dual1, AD_NV, AD_Var, AD_Const, &
                         OPERATOR(+), OPERATOR(-), OPERATOR(*), OPERATOR(/), &
                         AD_Sqrt, AD_Sin, AD_Cos, AD_Acos, AD_Atan2, &
                         AD1_Var, AD1_Const, AD1_Sqrt, AD1_Sin, AD1_Cos, AD1_Atan2
  IMPLICIT NONE

  REAL(wp), PARAMETER :: GTOL = 1.0e-7_wp, HTOL = 1.0e-5_wp, STOL = 1.0e-12_wp
  REAL(wp), PARAMETER :: H = 1.0e-4_wp
  INTEGER :: nfail, i, j
  REAL(wp) :: q(AD_NV), g_fd(AD_NV), h_fd(AD_NV, AD_NV), qp(AD_NV)
  REAL(wp) :: fpp, fpm, fmp, fmm, fp, fm, f0
  TYPE(Dual2) :: fd
  TYPE(Dual1) :: fd1
  REAL(wp) :: g1_fd(AD_NV), g2(AD_NV)
  nfail = 0

  q = 0.0_wp
  q(1) = 0.5_wp; q(2) = 0.7_wp; q(3) = 0.4_wp; q(4) = 0.6_wp; q(5) = -0.3_wp

  ! --- AD value / grad / hess ---
  fd = f_dual(q)

  ! --- FD gradient (central) ---
  DO i = 1, AD_NV
    qp = q; qp(i) = q(i) + H; fp = f_real(qp)
    qp = q; qp(i) = q(i) - H; fm = f_real(qp)
    g_fd(i) = (fp - fm)/(2.0_wp*H)
  END DO

  ! --- FD Hessian (central): diagonal + off-diagonal ---
  f0 = f_real(q)
  DO i = 1, AD_NV
    qp = q; qp(i) = q(i) + H; fp = f_real(qp)
    qp = q; qp(i) = q(i) - H; fm = f_real(qp)
    h_fd(i, i) = (fp - 2.0_wp*f0 + fm)/(H*H)
    DO j = i + 1, AD_NV
      qp = q; qp(i) = q(i) + H; qp(j) = q(j) + H; fpp = f_real(qp)
      qp = q; qp(i) = q(i) + H; qp(j) = q(j) - H; fpm = f_real(qp)
      qp = q; qp(i) = q(i) - H; qp(j) = q(j) + H; fmp = f_real(qp)
      qp = q; qp(i) = q(i) - H; qp(j) = q(j) - H; fmm = f_real(qp)
      h_fd(i, j) = (fpp - fpm - fmp + fmm)/(4.0_wp*H*H)
      h_fd(j, i) = h_fd(i, j)
    END DO
  END DO

  CALL require(ABS(fd%v - f0) < 1.0e-12_wp, 'AD:value-matches-real')
  CALL require(nan_max_abs(fd%g - g_fd) < GTOL, 'AD:gradient-vs-FD')
  CALL require(nan_max_abs(fd%h - h_fd) < HTOL, 'AD:hessian-vs-FD')
  ! Hessian symmetry (analytic)
  CALL require(nan_max_abs(fd%h - TRANSPOSE(fd%h)) < STOL, 'AD:hessian-symmetric')

  ! --- Dual1 (first-order, force-only path): gradient must match central FD AND
  !     the Dual2 gradient of the SAME function to the AD floor. This validates
  !     the residual-only engine the force-only element split rides on. ---
  fd1 = g_dual1(q)
  fd = g_dual2(q)
  DO i = 1, AD_NV
    qp = q; qp(i) = q(i) + H; fp = g_real(qp)
    qp = q; qp(i) = q(i) - H; fm = g_real(qp)
    g1_fd(i) = (fp - fm)/(2.0_wp*H)
  END DO
  g2 = fd%g
  CALL require(ABS(fd1%v - g_real(q)) < 1.0e-12_wp, 'AD1:value-matches-real')
  CALL require(nan_max_abs(fd1%g - g1_fd) < GTOL, 'AD1:gradient-vs-FD')
  CALL require(nan_max_abs(fd1%g - g2) < 1.0e-12_wp, 'AD1:gradient-matches-Dual2')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    WRITE (*, '(A,ES12.4)') '  max |grad - grad_fd| = ', nan_max_abs(fd%g - g_fd)
    WRITE (*, '(A,ES12.4)') '  max |hess - hess_fd| = ', nan_max_abs(fd%h - h_fd)
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Dual2 AD gradient + Hessian match FD; Dual1 gradient matches FD + Dual2'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  ! G(q) = (q1^2 q2 + sin q3)/(2 + q2^2) + atan2(q4, 1 + q1 q3)
  !        + sqrt(1 + q2^2 + q5^2) + cos(q1 q4)   [no acos: Dual1 has no AD1_Acos]
  PURE FUNCTION g_real(x) RESULT(r)
    REAL(wp), INTENT(IN) :: x(AD_NV)
    REAL(wp) :: r
    r = (x(1)*x(1)*x(2) + SIN(x(3)))/(2.0_wp + x(2)*x(2)) &
        + ATAN2(x(4), 1.0_wp + x(1)*x(3)) &
        + SQRT(1.0_wp + x(2)*x(2) + x(5)*x(5)) &
        + COS(x(1)*x(4))
  END FUNCTION g_real

  FUNCTION g_dual1(x) RESULT(r)
    REAL(wp), INTENT(IN) :: x(AD_NV)
    TYPE(Dual1) :: r, q1, q2, q3, q4, q5
    q1 = AD1_Var(x(1), 1); q2 = AD1_Var(x(2), 2); q3 = AD1_Var(x(3), 3)
    q4 = AD1_Var(x(4), 4); q5 = AD1_Var(x(5), 5)
    r = (q1*q1*q2 + AD1_Sin(q3))/(AD1_Const(2.0_wp) + q2*q2) &
        + AD1_Atan2(q4, AD1_Const(1.0_wp) + q1*q3) &
        + AD1_Sqrt(AD1_Const(1.0_wp) + q2*q2 + q5*q5) &
        + AD1_Cos(q1*q4)
  END FUNCTION g_dual1

  FUNCTION g_dual2(x) RESULT(r)
    REAL(wp), INTENT(IN) :: x(AD_NV)
    TYPE(Dual2) :: r, q1, q2, q3, q4, q5
    q1 = AD_Var(x(1), 1); q2 = AD_Var(x(2), 2); q3 = AD_Var(x(3), 3)
    q4 = AD_Var(x(4), 4); q5 = AD_Var(x(5), 5)
    r = (q1*q1*q2 + AD_Sin(q3))/(2.0_wp + q2*q2) &
        + AD_Atan2(q4, 1.0_wp + q1*q3) &
        + AD_Sqrt(1.0_wp + q2*q2 + q5*q5) &
        + AD_Cos(q1*q4)
  END FUNCTION g_dual2

  ! F(q) = (q1^2 q2 + sin q3)/(2 + q2^2) + acos(0.3 q1)
  !        + atan2(q4, 1 + q1 q3) + sqrt(1 + q2^2 + q5^2)
  PURE FUNCTION f_real(x) RESULT(r)
    REAL(wp), INTENT(IN) :: x(AD_NV)
    REAL(wp) :: r
    r = (x(1)*x(1)*x(2) + SIN(x(3)))/(2.0_wp + x(2)*x(2)) &
        + ACOS(0.3_wp*x(1)) &
        + ATAN2(x(4), 1.0_wp + x(1)*x(3)) &
        + SQRT(1.0_wp + x(2)*x(2) + x(5)*x(5))
  END FUNCTION f_real

  FUNCTION f_dual(x) RESULT(r)
    REAL(wp), INTENT(IN) :: x(AD_NV)
    TYPE(Dual2) :: r, q1, q2, q3, q4, q5
    q1 = AD_Var(x(1), 1); q2 = AD_Var(x(2), 2); q3 = AD_Var(x(3), 3)
    q4 = AD_Var(x(4), 4); q5 = AD_Var(x(5), 5)
    r = (q1*q1*q2 + AD_Sin(q3))/(2.0_wp + q2*q2) &
        + AD_Acos(0.3_wp*q1) &
        + AD_Atan2(q4, 1.0_wp + q1*q3) &
        + AD_Sqrt(1.0_wp + q2*q2 + q5*q5)
  END FUNCTION f_dual

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_ad
