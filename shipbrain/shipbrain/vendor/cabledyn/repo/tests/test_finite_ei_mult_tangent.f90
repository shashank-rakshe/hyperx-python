! File: tests/test_finite_ei_mult_tangent.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_mult_tangent
  !! FD ORACLE for the multiplicative-SO(3) consistent tangent.
  !!
  !! The multiplicative gen-alpha step parametrises each step by the per-step rotation
  !! INCREMENT psi (rotation DOFs rebased to psi = 0 at t_n; absolute rotation recovered
  !! by SO(3) composition). The Newton residual is
  !!    R(psi) = M a_alpha(psi) + f_int(theta_alpha(psi)) - f_ext,
  !! with the geodesic blend  theta_alpha = compose(theta_n, (1-af) psi)  feeding the
  !! element force. The consistent effective tangent is therefore
  !!    eff = (1-am)/(beta dt^2) M  +  (1-af) K . Jhat,
  !! where K = dfint/dtheta_alpha and Jhat is block-diagonal: identity on the translation
  !! DOFs and, on each node's three rotation DOFs, the compose/blend chain Jacobian
  !!    J_c = dexp_inv(theta_alpha) . dexp((1-af) psi)      (since
  !!    d theta_alpha / d psi = (1-af) J_c, from exp(psib+dpsib)=exp(Jl(psib)dpsib)exp(psib)).
  !!
  !! This gate proves J_c is the CORRECT directional derivative BEFORE it is trusted in
  !! the dynamics -- it is exactly the SO(3) directional-derivative object that has hidden
  !! sign/convention bugs in this project, and it has a cheap, unambiguous FD oracle:
  !! the central finite difference of the (simple, trusted) residual w.r.t. psi at a
  !! MODERATE-rotation state must equal the analytical eff to round-off. Debug the tangent
  !! against its own derivative, not against the energy blow-up it would cause at step 40.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratAssemble, ONLY: CD_Assemble_Cosserat_Tangent_Force, CD_Assemble_Cosserat_Internal_Force
  USE CableDyn_CosseratDynamic, ONLY: CD_Assemble_Cosserat_Mass
  USE CableDyn_SO3, ONLY: CD_Compose_Rotvec, CD_Dexp_Inv_SO3, CD_Dexp_SO3
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 2, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: EA = 1.0e3_wp, GAS = 5.0e2_wp, EI = 2.0e2_wp, GJ = 1.5e2_wp
  REAL(wp), PARAMETER :: RHO_A = 1.0_wp, I_RHO_T = 1.0e-2_wp, I_RHO_N = 2.0e-2_wp
  REAL(wp), PARAMETER :: DT = 0.02_wp, RHO_INF = 0.8_wp
  ! gen-alpha coefficients from rho_inf
  REAL(wp), PARAMETER :: AM = (2.0_wp*RHO_INF - 1.0_wp)/(RHO_INF + 1.0_wp)
  REAL(wp), PARAMETER :: AF = RHO_INF/(RHO_INF + 1.0_wp)
  REAL(wp), PARAMETER :: BETA = 0.25_wp*(1.0_wp - AM + AF)**2
  ! gamma (= 0.5 - am + af) is unused: the residual here carries no velocity-dependent
  ! term (no damping / load), so only the position/rotation tangent is exercised.

  INTEGER :: conn(2, NE), i, nfail
  REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
  REAL(wp) :: theta_n(3, NN), v_n(NDOF), a_n(NDOF), q_pred(NDOF), psi0(NDOF), f_ext(NDOF)
  REAL(wp) :: eff_an(NDOF, NDOF), eff_fd(NDOF, NDOF), reldiff
  nfail = 0

  ! --- a moderate-rotation, genuinely bent/strained state (large K, nonzero fint) ---
  DO i = 1, NN
    nodes_ref(:, i) = [0.0_wp, 0.0_wp, 0.5_wp*REAL(i - 1, wp)]
  END DO
  DO i = 1, NE
    conn(:, i) = [i, i + 1]
    ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
    ra(i) = RHO_A; it(i) = I_RHO_T; in_(i) = I_RHO_N
  END DO
  theta_n(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
  theta_n(:, 2) = [0.30_wp, 0.10_wp, 0.20_wp]
  theta_n(:, 3) = [0.55_wp, -0.12_wp, 0.28_wp]
  f_ext = 0.0_wp
  v_n = 0.0_wp; a_n = 0.0_wp; psi0 = 0.0_wp
  DO i = 1, NN
    v_n(6*i - 5:6*i - 3) = [0.05_wp, -0.03_wp, 0.04_wp]      ! translational velocity
    v_n(6*i - 2:6*i) = [0.20_wp, 0.10_wp, -0.15_wp]          ! spatial angular velocity omega_n
    a_n(6*i - 5:6*i - 3) = [0.02_wp, 0.01_wp, -0.02_wp]
    a_n(6*i - 2:6*i) = [0.08_wp, -0.05_wp, 0.06_wp]          ! spatial angular acceleration alpha_n
    ! candidate per-step increment: position absolute (= ref + small), rotation = psi increment
    psi0(6*i - 5:6*i - 3) = nodes_ref(:, i) + [0.01_wp, -0.02_wp, 0.015_wp]
    psi0(6*i - 2:6*i) = [0.12_wp, -0.07_wp, 0.09_wp]
  END DO
  ! q_pred: translation Newmark on position; rotation Newmark on the increment (psi base 0)
  DO i = 1, NN
    q_pred(6*i - 5:6*i - 3) = nodes_ref(:, i) + DT*v_n(6*i - 5:6*i - 3) + &
                              DT*DT*(0.5_wp - BETA)*a_n(6*i - 5:6*i - 3)
    q_pred(6*i - 2:6*i) = DT*v_n(6*i - 2:6*i) + DT*DT*(0.5_wp - BETA)*a_n(6*i - 2:6*i)
  END DO

  CALL analytic_eff(psi0, eff_an)
  CALL fd_eff(psi0, eff_fd)
  reldiff = nan_max_abs(eff_an - eff_fd)/nan_max_abs(eff_an)
  WRITE (*, '(A,ES11.3,A,ES11.3,A,ES11.3)') '  max|eff_an|=', nan_max_abs(eff_an), &
    '  max|eff_an-eff_fd|=', nan_max_abs(eff_an - eff_fd), '  rel=', reldiff
  CALL require(reldiff < 1.0e-7_wp, 'mult-consistent-tangent:analytic==central-FD-of-residual')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: multiplicative-SO(3) consistent tangent matches the FD of its own residual'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE residual(psi, R)
    !! R(psi) = M a_alpha + f_int(theta_alpha) - f_ext, exactly as the multiplicative
    !! gen-alpha step forms it: rotation DOFs of psi are the per-step increment.
    REAL(wp), INTENT(IN) :: psi(NDOF)
    REAL(wp), INTENT(OUT) :: R(NDOF)
    REAL(wp) :: a_eval(NDOF), a_alpha(NDOF), q_alpha(NDOF), Mmat(NDOF, NDOF), fint(NDOF)
    INTEGER :: j, es
    CHARACTER(120) :: em
    a_eval = (psi - q_pred)/(BETA*DT*DT)
    a_alpha = (1.0_wp - AM)*a_eval + AM*a_n
    ! blend: translation linear; rotation geodesic theta_alpha = compose(theta_n, (1-af) psi)
    DO j = 1, NN
      q_alpha(6*j - 5:6*j - 3) = (1.0_wp - AF)*psi(6*j - 5:6*j - 3) + AF*nodes_ref(:, j)
      q_alpha(6*j - 2:6*j) = CD_Compose_Rotvec(theta_n(:, j), (1.0_wp - AF)*psi(6*j - 2:6*j))
    END DO
    CALL CD_Assemble_Cosserat_Mass(nodes_ref, conn, ra, it, in_, Mmat, es, em)
    CALL CD_Assemble_Cosserat_Internal_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q_alpha, .TRUE., fint, es, em)
    R = MATMUL(Mmat, a_alpha) + fint - f_ext
  END SUBROUTINE residual

  SUBROUTINE analytic_eff(psi, eff)
    !! eff = (1-am)/(beta dt^2) M + (1-af) K . Jhat, Jhat = I on translation,
    !! J_c = dexp_inv(theta_alpha) dexp((1-af) psi) on each node's rotation triple.
    REAL(wp), INTENT(IN) :: psi(NDOF)
    REAL(wp), INTENT(OUT) :: eff(NDOF, NDOF)
    REAL(wp) :: Mmat(NDOF, NDOF), Kt(NDOF, NDOF), fint(NDOF), q_alpha(NDOF)
    REAL(wp) :: th_alpha(3), jc(3, 3), kcols(NDOF, 3)
    INTEGER :: j, es
    CHARACTER(120) :: em
    DO j = 1, NN
      q_alpha(6*j - 5:6*j - 3) = (1.0_wp - AF)*psi(6*j - 5:6*j - 3) + AF*nodes_ref(:, j)
      q_alpha(6*j - 2:6*j) = CD_Compose_Rotvec(theta_n(:, j), (1.0_wp - AF)*psi(6*j - 2:6*j))
    END DO
    CALL CD_Assemble_Cosserat_Mass(nodes_ref, conn, ra, it, in_, Mmat, es, em)
    CALL CD_Assemble_Cosserat_Tangent_Force(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q_alpha, .TRUE., Kt, fint, es, em)
    ! right-multiply each node's three rotation COLUMNS of K by J_c
    DO j = 1, NN
      th_alpha = q_alpha(6*j - 2:6*j)
      jc = MATMUL(CD_Dexp_Inv_SO3(th_alpha), CD_Dexp_SO3((1.0_wp - AF)*psi(6*j - 2:6*j)))
      kcols = MATMUL(Kt(:, 6*j - 2:6*j), jc)
      Kt(:, 6*j - 2:6*j) = kcols
    END DO
    eff = (1.0_wp - AM)/(BETA*DT*DT)*Mmat + (1.0_wp - AF)*Kt
  END SUBROUTINE analytic_eff

  SUBROUTINE fd_eff(psi, eff)
    !! Column k of eff = d R / d psi_k by central difference.
    REAL(wp), INTENT(IN) :: psi(NDOF)
    REAL(wp), INTENT(OUT) :: eff(NDOF, NDOF)
    REAL(wp) :: pp(NDOF), pm(NDOF), Rp(NDOF), Rm(NDOF), h
    INTEGER :: k
    h = 1.0e-6_wp
    DO k = 1, NDOF
      pp = psi; pm = psi
      pp(k) = pp(k) + h; pm(k) = pm(k) - h
      CALL residual(pp, Rp)
      CALL residual(pm, Rm)
      eff(:, k) = (Rp - Rm)/(2.0_wp*h)
    END DO
  END SUBROUTINE fd_eff

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_finite_ei_mult_tangent
