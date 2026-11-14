! File: tests/test_finite_ei_gyro_tangent.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_gyro_tangent
  !! FD oracle for the CONSISTENT tangent of the multiplicative-SO(3) rotational inertial
  !! force, checked against central FD -- the same discipline that verifies J_c and the
  !! element tangent.
  !!
  !! Per node the multiplicative residual carries the lumped additive-virtual-work inertial
  !! torque
  !!   g(psi) = w * T^T(theta_alpha) * [ I_s(theta_alpha) alpha_alpha
  !!                                     + omega_alpha x (I_s(theta_alpha) omega_alpha) ]
  !! with theta_alpha = compose(theta_n,(1-af) psi), and alpha_alpha / omega_alpha the gen-alpha
  !! Newmark blends of the spatial acceleration / velocity (functions of the increment psi).
  !! Its consistent tangent is
  !!   dg/dpsi = w [ M_Ttheta . (1-af) J_c
  !!                 + T^T ( I_s c_alpha + GyroJw c_omega + M_stheta (1-af) J_c ) ]
  !! with c_alpha = (1-am)/(beta dt^2), c_omega = (1-af) gamma/(beta dt),
  !! J_c = dexp_inv(theta_alpha) dexp((1-af) psi) (the compose chain),
  !! GyroJw = d[omega x (I_s omega)]/domega, M_stheta(:,j) = dIs_j alpha + omega x (dIs_j omega),
  !! M_Ttheta(:,j) = (d/dtheta[T] . e_j)^T s. This gate demands dg/dpsi == central FD of g(psi).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Spatial_Inertia, CD_Spatial_Inertia_Dir, &
                                      CD_Gyro_Torque, CD_Gyro_Torque_DOmega
  USE CableDyn_SO3, ONLY: CD_Compose_Rotvec, CD_Dexp_SO3, CD_Dexp_Inv_SO3, CD_Dexp_Dir_SO3, CD_Hat, CD_Exp_SO3
  IMPLICIT NONE

  REAL(wp), PARAMETER :: IT = 1.0e-2_wp, IN_ = 2.0e-2_wp, W = 0.5_wp
  REAL(wp), PARAMETER :: DT = 0.02_wp, RHO_INF = 0.8_wp, H = 1.0e-7_wp, TOL = 1.0e-6_wp
  REAL(wp), PARAMETER :: AM = (2.0_wp*RHO_INF - 1.0_wp)/(RHO_INF + 1.0_wp)
  REAL(wp), PARAMETER :: AF = RHO_INF/(RHO_INF + 1.0_wp)
  REAL(wp), PARAMETER :: BETA = 0.25_wp*(1.0_wp - AM + AF)**2
  REAL(wp), PARAMETER :: GAMMA = 0.5_wp - AM + AF
  REAL(wp) :: theta_n(3), omega_n(3), alpha_n(3), psi(3), psi_pred(3), omega_pred(3), Lam0(3, 3)
  REAL(wp) :: dg_an(3, 3), dg_fd(3, 3), gp(3), gm(3), ek(3), reldiff
  INTEGER :: k, nfail
  nfail = 0

  Lam0 = CD_Exp_SO3([0.2_wp, -0.3_wp, 0.4_wp])   ! non-identity reference frame (inclined element)
  theta_n = [0.30_wp, -0.20_wp, 0.45_wp]     ! moderate absolute rotation at t_n
  omega_n = [0.7_wp, -0.5_wp, 0.9_wp]        ! spatial angular velocity at t_n
  alpha_n = [0.3_wp, 0.2_wp, -0.4_wp]        ! spatial angular acceleration at t_n
  psi = [0.10_wp, -0.06_wp, 0.08_wp]         ! candidate per-step increment
  psi_pred = DT*omega_n + DT*DT*(0.5_wp - BETA)*alpha_n
  omega_pred = omega_n + DT*(1.0_wp - GAMMA)*alpha_n

  CALL analytic_dg(psi, dg_an)
  DO k = 1, 3
    ek = 0.0_wp; ek(k) = 1.0_wp
    gp = gforce(psi + H*ek)
    gm = gforce(psi - H*ek)
    dg_fd(:, k) = (gp - gm)/(2.0_wp*H)
  END DO
  reldiff = nan_max_abs(dg_an - dg_fd)/nan_max_abs(dg_an)
  WRITE (*, '(A,ES11.3,A,ES11.3,A,ES11.3)') '  max|dg_an|=', nan_max_abs(dg_an), &
    '  max|dg_an-dg_fd|=', nan_max_abs(dg_an - dg_fd), '  rel=', reldiff
  CALL require(reldiff < TOL, 'gyro-inertial-tangent:analytic==central-FD-of-residual')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: consistent gyroscopic+config-inertia tangent matches its own FD'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  FUNCTION gforce(p) RESULT(g)
    !! The per-node rotational inertial torque g(psi).
    REAL(wp), INTENT(IN) :: p(3)
    REAL(wp) :: g(3), th_a(3), al_a(3), om_a(3), al_eval(3), om_eval(3), Is(3, 3), s(3), Tt(3, 3)
    al_eval = (p - psi_pred)/(BETA*DT*DT)
    al_a = (1.0_wp - AM)*al_eval + AM*alpha_n
    om_eval = omega_pred + GAMMA*DT*al_eval
    om_a = (1.0_wp - AF)*om_eval + AF*omega_n
    th_a = CD_Compose_Rotvec(theta_n, (1.0_wp - AF)*p)
    Is = CD_Spatial_Inertia(th_a, Lam0, IT, IN_)
    s = MATMUL(Is, al_a) + CD_Gyro_Torque(Is, om_a)
    Tt = TRANSPOSE(CD_Dexp_SO3(th_a))
    g = W*MATMUL(Tt, s)
  END FUNCTION gforce

  SUBROUTINE analytic_dg(p, dg)
    REAL(wp), INTENT(IN) :: p(3)
    REAL(wp), INTENT(OUT) :: dg(3, 3)
    REAL(wp) :: th_a(3), al_a(3), om_a(3), al_eval(3), om_eval(3), Is(3, 3), s(3), Tt(3, 3)
    REAL(wp) :: ca, cw, Jc(3, 3), GyroJw(3, 3), Mstheta(3, 3), MTtheta(3, 3), dIs(3, 3), dTm(3, 3)
    REAL(wp) :: ds_dpsi(3, 3), ej(3), Iw(3)
    INTEGER :: j
    al_eval = (p - psi_pred)/(BETA*DT*DT)
    al_a = (1.0_wp - AM)*al_eval + AM*alpha_n
    om_eval = omega_pred + GAMMA*DT*al_eval
    om_a = (1.0_wp - AF)*om_eval + AF*omega_n
    th_a = CD_Compose_Rotvec(theta_n, (1.0_wp - AF)*p)
    Is = CD_Spatial_Inertia(th_a, Lam0, IT, IN_)
    s = MATMUL(Is, al_a) + CD_Gyro_Torque(Is, om_a)
    Tt = TRANSPOSE(CD_Dexp_SO3(th_a))
    ca = (1.0_wp - AM)/(BETA*DT*DT)
    cw = (1.0_wp - AF)*GAMMA/(BETA*DT)
    Jc = MATMUL(CD_Dexp_Inv_SO3(th_a), CD_Dexp_SO3((1.0_wp - AF)*p))
    GyroJw = CD_Gyro_Torque_DOmega(Is, om_a)
    DO j = 1, 3
      ej = 0.0_wp; ej(j) = 1.0_wp
      dIs = CD_Spatial_Inertia_Dir(th_a, Lam0, IT, IN_, ej)
      Iw = MATMUL(dIs, om_a)
      Mstheta(:, j) = MATMUL(dIs, al_a) + MATMUL(CD_Hat(om_a), Iw)
      dTm = CD_Dexp_Dir_SO3(th_a, ej)
      MTtheta(:, j) = MATMUL(TRANSPOSE(dTm), s)
    END DO
    ds_dpsi = ca*Is + cw*GyroJw + MATMUL(Mstheta, (1.0_wp - AF)*Jc)
    dg = W*(MATMUL(MTtheta, (1.0_wp - AF)*Jc) + MATMUL(Tt, ds_dpsi))
  END SUBROUTINE analytic_dg

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_finite_ei_gyro_tangent
