! File: tests/test_l1_euler_beam.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_euler_beam
  !! L1-6 free-free Euler-Bernoulli beam first-mode vibration, scored on the
  !! Fortran finite-EI gen-α dynamics against the closed-form beam frequency. A
  !! straight rod along +x (bending-dominated: EI = 1e-2, no axial pretension),
  !! free-free, is given the analytical first elastic mode shape
  !!   phi1(x) = cosh(bx) + cos(bx) - sigma1 (sinh(bx) + sin(bx)),
  !!   b = beta1L / L,  sigma1 = (cosh(beta1L)-cos(beta1L))/(sinh(beta1L)-sin(beta1L)),
  !! with beta1L = 4.7300407... (first non-rigid root of cos.cosh = 1), scaled so
  !! peak |z| = A_AMP, and each node's theta_y aligned with the local slope
  !! (-arctan(dz/dx)). The first-mode period is measured from the node-1 trough
  !! (parabola-interpolated, as in L1-5) and compared to
  !!   T1 = 2 pi L^2 / ((beta1L)^2 sqrt(EI/rhoA)).
  !! Gate < 0.1% (VALIDATION_SPEC.md L1-6) at n_elem = 64 -- the linear-Lagrange
  !! Cosserat discrete-pencil bias is +0.029% there. Mirrors the L1-6 benchmark.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Gen_Alpha_Step, CD_Cosserat_Initial_Acceleration
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e4_wp, GAS = 1.0e3_wp, EI = 1.0e-2_wp, GJ = 1.0e-1_wp
  REAL(wp), PARAMETER :: RHO_A = 1.0_wp, I_RHO_T = 1.0e-6_wp, I_RHO_N = 2.0e-6_wp
  REAL(wp), PARAMETER :: A_AMP = 1.0e-3_wp, PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: BETA1L = 4.730040744862704_wp, GATE = 1.0e-3_wp
  INTEGER, PARAMETER :: NE = 64, NN = NE + 1, NDOF = 6*NN
  INTEGER, PARAMETER :: NPP = 200, NSTEP = 260
  INTEGER :: nfail, i, es, n_iter, step, imin
  INTEGER :: conn(2, NE)
  REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
  REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
  REAL(wp) :: sigma1, f1, period_an, dt, norm, x, phimax, ztrack(0:NSTEP), zlo, zc, zhi, denom, frac
  REAL(wp) :: t_trough, period_num, rel, phi(NN), slope(NN)
  LOGICAL :: converged, stalled
  TYPE(GenAlphaConfig) :: cfg
  CHARACTER(120) :: em
  nfail = 0

  sigma1 = (COSH(BETA1L) - COS(BETA1L))/(SINH(BETA1L) - SIN(BETA1L))
  f1 = (BETA1L**2)*SQRT(EI/RHO_A)/(2.0_wp*PI*L**2)
  period_an = 1.0_wp/f1
  dt = period_an/REAL(NPP, wp)

  DO i = 1, NN
    x = REAL(i - 1, wp)*L/REAL(NE, wp)
    phi(i) = mode_shape(x)
    slope(i) = mode_slope(x)
  END DO
  DO i = 1, NE
    conn(:, i) = [i, i + 1]
    ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
    ra(i) = RHO_A; it(i) = I_RHO_T; in_(i) = I_RHO_N
  END DO
  phimax = nan_max_abs(phi)
  norm = A_AMP/phimax

  ! mesh + IC: rod along +x, z = norm*phi, theta_y = -arctan(norm*slope)
  q = 0.0_wp
  DO i = 1, NN
    x = REAL(i - 1, wp)*L/REAL(NE, wp)
    nodes_ref(:, i) = [x, 0.0_wp, 0.0_wp]
    q(6*i - 5) = x                              ! node x-position
    q(6*i - 3) = norm*phi(i)                    ! node z-deflection
    q(6*i - 1) = -ATAN(norm*slope(i))           ! theta_y aligned with the slope
  END DO
  vel = 0.0_wp
  f_ext = 0.0_wp

  ! free vibration (f_ext = 0): the relative gate cannot fire (scale collapses to
  ! r0), so make the ABSOLUTE residual gate operative -- the bending-force scale
  ! is ~1e-4, round-off floor ~1e-15, so abs_tol = 1e-9 certifies true convergence
  cfg%abs_tol = 1.0e-9_wp

  CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                        .TRUE., q, f_ext, [INTEGER ::], acc, es, em)
  CALL require(es == CD_DYN_OK, 'euler:a0-ErrStat')

  ztrack(0) = q(3)                              ! node-1 z (antinode at x = 0)
  DO step = 1, NSTEP
    CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                    q, vel, acc, f_ext, [INTEGER ::], dt, cfg, q_new, v_new, a_new, &
                                    converged, stalled, n_iter, es, em)
    CALL require(es == CD_DYN_OK .AND. converged .AND. .NOT. stalled, 'euler:step-converged')
    q = q_new; vel = v_new; acc = a_new
    ztrack(step) = q(3)
  END DO

  ! first-mode period from the node-1 trough (parabola-interpolated minimum)
  imin = 1
  DO step = 1, NSTEP - 1
    IF (ztrack(step) < ztrack(imin)) imin = step
  END DO
  zlo = ztrack(imin - 1); zc = ztrack(imin); zhi = ztrack(imin + 1)
  denom = zlo - 2.0_wp*zc + zhi
  frac = 0.0_wp
  IF (ABS(denom) > 0.0_wp) frac = 0.5_wp*(zlo - zhi)/denom
  t_trough = (REAL(imin, wp) + frac)*dt
  period_num = 2.0_wp*t_trough
  rel = ABS(period_num - period_an)/period_an
  WRITE (*, '(A,ES14.6,A,ES14.6,A,ES11.4)') 'L1-6 Euler beam: T_num = ', period_num, &
    '  T1 = ', period_an, '  rel err = ', rel
  CALL require(rel < GATE, 'L1-6:first-mode-period-vs-analytical')
  CALL require(ztrack(imin) < -0.5_wp*A_AMP, 'L1-6:crossed-to-far-side')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran finite-EI dynamics matches the Euler-beam first-mode period (L1-6)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  PURE FUNCTION mode_shape(x) RESULT(p)
    REAL(wp), INTENT(IN) :: x
    REAL(wp) :: p, bx
    bx = BETA1L*x/L
    p = (COSH(bx) + COS(bx)) - sigma1*(SINH(bx) + SIN(bx))
  END FUNCTION mode_shape

  PURE FUNCTION mode_slope(x) RESULT(s)
    REAL(wp), INTENT(IN) :: x
    REAL(wp) :: s, bx, b
    bx = BETA1L*x/L
    b = BETA1L/L
    s = b*(SINH(bx) - SIN(bx)) - sigma1*b*(COSH(bx) + COS(bx))
  END FUNCTION mode_slope

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_euler_beam
