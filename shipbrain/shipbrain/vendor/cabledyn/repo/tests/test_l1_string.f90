! File: tests/test_l1_string.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_string
  !! L1-5 taut-string vibration, scored on the Fortran EI=0 generalised-α dynamics
  !! against the closed-form string period. A pinned-pinned cable pre-stretched 1%
  !! (so tension T = EA*0.01) carries no bending; a small first-mode transverse
  !! perturbation z(x) = A sin(pi x / L) oscillates at the string fundamental, period
  !! T1 = 2 L sqrt(mu / T) with mu the mass per CURRENT length (rho_A * L0_total / L,
  !! since rho_A is per reference length and the cable is stretched). The discrete
  !! first-mode period is measured from the mid-span trough (parabola-interpolated)
  !! and compared to T1. Mirrors the L1-5 benchmark (VALIDATION_SPEC.md): the EI=0
  !! cable IS the pure-string limit (no rotational inertia).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_Cable_Gen_Alpha_Step, &
                              CD_Cable_Initial_Acceleration, CD_DYN_OK
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 32, NN = NE + 1
  REAL(wp), PARAMETER :: SPAN = 1.0_wp, EA = 1.0e4_wp, RHO_A = 1.0_wp
  REAL(wp), PARAMETER :: PRESTRETCH = 0.01_wp        ! axial strain at rest
  REAL(wp), PARAMETER :: AMP = 1.0e-3_wp             ! first-mode perturbation amplitude
  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: GATE = 1.0e-3_wp            ! VALIDATION_SPEC L1-5: <0.1% on the period
  INTEGER, PARAMETER :: NPP = 200                    ! steps per period
  INTEGER, PARAMETER :: NSTEP = 260                  ! ~1.3 periods (trough near NPP/2)

  INTEGER  :: nfail, conn(2, NE), fixed(6), es, n_iter, i, mid, step, imin
  REAL(wp) :: l0(NE), ea_arr(NE), rho_arr(NE), f_ext(3*NN)
  REAL(wp) :: q(3*NN), v(3*NN), a(3*NN), q_new(3*NN), v_new(3*NN), a_new(3*NN)
  REAL(wp) :: l0e, tension, mu, period_an, dt, x, zmid(0:NSTEP), t_trough, period_num, rel
  REAL(wp) :: zlo, zc, zhi, denom, frac
  LOGICAL  :: converged, stalled
  TYPE(GenAlphaConfig) :: cfg
  CHARACTER(120) :: em
  nfail = 0

  ! pre-stretched mesh: total L0 = SPAN/(1+strain); stretched to SPAN -> strain
  l0e = (SPAN/(1.0_wp + PRESTRETCH))/REAL(NE, wp)
  tension = EA*PRESTRETCH
  mu = RHO_A*(SPAN/(1.0_wp + PRESTRETCH))/SPAN          ! mass per current length
  period_an = 2.0_wp*SPAN*SQRT(mu/tension)
  dt = period_an/REAL(NPP, wp)

  DO i = 1, NE
    conn(1, i) = i; conn(2, i) = i + 1
    l0(i) = l0e; ea_arr(i) = EA; rho_arr(i) = RHO_A
  END DO
  f_ext = 0.0_wp
  ! first-mode shape: x in [0, SPAN], z = AMP sin(pi x / SPAN), y = 0
  q = 0.0_wp
  DO i = 1, NN
    x = REAL(i - 1, wp)*SPAN/REAL(NE, wp)
    q(3*i - 2) = x
    q(3*i) = AMP*SIN(PI*x/SPAN)
  END DO
  v = 0.0_wp
  ! both ends fully pinned
  fixed = [1, 2, 3, 3*NN - 2, 3*NN - 1, 3*NN]
  ! Benchmark-specific absolute residual gate. With f_ext = 0 (free vibration)
  ! the relative convergence scale max(||f_ext_free||, r0, abs_tol) collapses to
  ! the round-off-small predictor residual r0, so the default rel_tol gate alone
  ! can never fire. The element-force scale here is the line tension EA*eps = 100
  ! N; the converged-residual round-off floor sits ~1e-11. Setting abs_tol = 1e-8
  ! (three orders above that floor, ten below the 100 N force scale) makes the
  ! ABSOLUTE gate ||R|| < abs_tol the operative one: tight enough that a stalled
  ! or iteration-exhausted corrector cannot pass (its residual stays O(0.1-100
  ! N)), loose enough to certify the round-off-limited free-vibration step. The
  ! step must then truly converge -- asserted below -- so the measured period
  ! cannot be a plausible-but-unconverged artifact.
  cfg%abs_tol = 1.0e-8_wp
  CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea_arr, rho_arr, .FALSE., f_ext, fixed, a, es, em)
  CALL require(es == CD_DYN_OK, 'string:a0-ErrStat')

  mid = NE/2 + 1                              ! mid-span node (NE even)
  zmid(0) = q(3*mid)
  DO step = 1, NSTEP
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea_arr, rho_arr, .FALSE., f_ext, fixed, &
                                 dt, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL require(es == CD_DYN_OK .AND. converged .AND. .NOT. stalled, 'string:step-converged')
    q = q_new; v = v_new; a = a_new
    zmid(step) = q(3*mid)
  END DO

  ! discrete half-period = the mid-span trough time (parabola-interpolated minimum)
  imin = 1
  DO step = 1, NSTEP - 1
    IF (zmid(step) < zmid(imin)) imin = step
  END DO
  zlo = zmid(imin - 1); zc = zmid(imin); zhi = zmid(imin + 1)
  denom = zlo - 2.0_wp*zc + zhi
  frac = 0.0_wp
  IF (ABS(denom) > 0.0_wp) frac = 0.5_wp*(zlo - zhi)/denom    ! sub-step offset in [-0.5, 0.5]
  t_trough = (REAL(imin, wp) + frac)*dt
  period_num = 2.0_wp*t_trough
  rel = ABS(period_num - period_an)/period_an
  WRITE (*, '(A,ES14.6,A,ES14.6,A,ES12.4)') 'L1-5 string: T_num = ', period_num, &
    '  T1 = ', period_an, '  rel err = ', rel
  CALL require(rel < GATE, 'L1-5:string-period-vs-analytical')
  ! sanity: the mid-span actually swung to the far side (a real oscillation)
  CALL require(zmid(imin) < -0.5_wp*AMP, 'L1-5:crossed-to-far-side')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran EI=0 dynamics matches the analytical string period (L1-5)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_string
