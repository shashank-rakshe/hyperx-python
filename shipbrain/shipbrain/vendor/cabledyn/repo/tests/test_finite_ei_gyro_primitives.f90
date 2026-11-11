! File: tests/test_finite_ei_gyro_primitives.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_gyro_primitives
  !! FD oracle for the spatial rotational-inertia + gyroscopic primitives used by the
  !! multiplicative-SO(3) residual -- the same FD discipline that verifies the element
  !! tangent and the J_c chain, applied to these SO(3) directional-derivative objects.
  !!
  !!  * CD_Gyro_Torque_DOmega == d/domega [ omega x (I_s omega) ]   (central FD)
  !!  * CD_Spatial_Inertia_Dir == d/dtheta [ Lambda J Lambda^T ] . d (central FD, per direction)
  !!  * sanities: I_s symmetric and = diag(it,it,in) at theta=0; gyro torque _|_ omega.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Spatial_Inertia, CD_Spatial_Inertia_Dir, &
                                      CD_Gyro_Torque, CD_Gyro_Torque_DOmega
  USE CableDyn_SO3, ONLY: CD_Exp_SO3
  IMPLICIT NONE

  REAL(wp), PARAMETER :: IT = 1.0e-2_wp, IN_ = 2.0e-2_wp, H = 1.0e-6_wp, TOL = 1.0e-8_wp
  REAL(wp) :: theta(3), omega(3), Is(3, 3), Jw(3, 3), Jw_fd(3, 3), dIs_an(3, 3), dIs_fd(3, 3)
  REAL(wp) :: gp(3), gm(3), Ip(3, 3), Im(3, 3), ek(3), dvec(3), g(3), Lam0(3, 3), Jref(3, 3)
  INTEGER :: k, nfail, kk
  nfail = 0

  theta = [0.30_wp, -0.20_wp, 0.45_wp]      ! a moderate rotation (anisotropic axes exercised)
  omega = [0.7_wp, -0.5_wp, 0.9_wp]
  ! NON-IDENTITY reference frame -> exercises the Lam0 (reference-orientation) handling: a
  ! z-aligned (Lam0 = I) test would not exercise the inclined-cable inertia rotation.
  Lam0 = CD_Exp_SO3([0.3_wp, -0.2_wp, 0.5_wp])
  Jref = MATMUL(Lam0, MATMUL(diagJ(), TRANSPOSE(Lam0)))
  Is = CD_Spatial_Inertia(theta, Lam0, IT, IN_)

  ! sanity: symmetric, and reduces to Lam0 J Lam0^T (the reference inertia) at theta = 0
  CALL require(nan_max_abs(Is - TRANSPOSE(Is)) < 1.0e-14_wp, 'spatial-inertia:symmetric')
  CALL require(nan_max_abs(CD_Spatial_Inertia([0.0_wp, 0.0_wp, 0.0_wp], Lam0, IT, IN_) - Jref) < 1.0e-14_wp, &
               'spatial-inertia:theta0-is-reference-inertia')
  ! sanity: gyroscopic torque is perpendicular to omega (omega . (omega x Is omega) = 0)
  g = CD_Gyro_Torque(Is, omega)
  CALL require(ABS(DOT_PRODUCT(g, omega)) < 1.0e-14_wp, 'gyro-torque:perp-omega')

  ! GATE 1: gyroscopic velocity Jacobian vs central FD of the torque w.r.t. omega
  Jw = CD_Gyro_Torque_DOmega(Is, omega)
  DO k = 1, 3
    ek = 0.0_wp; ek(k) = 1.0_wp
    gp = CD_Gyro_Torque(Is, omega + H*ek)
    gm = CD_Gyro_Torque(Is, omega - H*ek)
    Jw_fd(:, k) = (gp - gm)/(2.0_wp*H)
  END DO
  CALL require(nan_max_abs(Jw - Jw_fd) < TOL, 'gyro-torque-domega:analytic==central-FD')

  ! GATE 2: spatial-inertia directional derivative vs central FD, for each basis direction
  DO kk = 1, 3
    dvec = 0.0_wp; dvec(kk) = 1.0_wp
    dIs_an = CD_Spatial_Inertia_Dir(theta, Lam0, IT, IN_, dvec)
    Ip = CD_Spatial_Inertia(theta + H*dvec, Lam0, IT, IN_)
    Im = CD_Spatial_Inertia(theta - H*dvec, Lam0, IT, IN_)
    dIs_fd = (Ip - Im)/(2.0_wp*H)
    CALL require(nan_max_abs(dIs_an - dIs_fd) < TOL, 'spatial-inertia-dir:analytic==central-FD')
  END DO

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: gyroscopic + spatial-inertia primitives match their finite differences'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  PURE FUNCTION diagJ() RESULT(Jm)
    REAL(wp) :: Jm(3, 3)
    Jm = 0.0_wp
    Jm(1, 1) = IT; Jm(2, 2) = IT; Jm(3, 3) = IN_
  END FUNCTION diagJ

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_finite_ei_gyro_primitives
