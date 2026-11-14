! File: tests/test_l1_energy_stability.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_energy_stability
  !! L1-8 generalised-α energy stability, scored on the Fortran finite-EI
  !! dynamics. A free-free Euler-Bernoulli beam (same model as L1-6) is given the
  !! first elastic mode shape and integrated at rho_inf = 0.8 (numerical
  !! dissipation). For a single mode the total mechanical energy is constant in
  !! the continuum; the dissipative gen-α makes it MONOTONE NON-INCREASING. The
  !! gate (VALIDATION_SPEC.md L1-8, smoke profile) is that the per-period PEAK
  !! mechanical energy does not grow within numerical noise:
  !!   max_k ( peak[k+1] - peak[k] ) < energy_noise_floor
  !! A growing peak would signal an unstable integrator. Energy is the assembled
  !! 1/2 v^T M v + sum_e U_e(q) (CD_Cosserat_Mechanical_Energy). Mirrors the
  !! L1-8 smoke gate (n_steps_per_period, n_periods on a free-free beam).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Gen_Alpha_Step, &
                                      CD_Cosserat_Initial_Acceleration, CD_Cosserat_Mechanical_Energy
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e4_wp, GAS = 1.0e3_wp, EI = 1.0e-2_wp, GJ = 1.0e-1_wp
  REAL(wp), PARAMETER :: RHO_A = 1.0_wp, I_RHO_T = 1.0e-6_wp, I_RHO_N = 2.0e-6_wp
  REAL(wp), PARAMETER :: A_AMP = 1.0e-3_wp, PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: BETA1L = 4.730040744862704_wp
  ! n_elem = 32 is the mesh floor (coarser meshes carry spurious rotation-dominated
  ! negative eigenpairs in the linear-Lagrange Cosserat pencil that the integrator
  ! cannot stabilise). n_periods = 2 is the minimum that makes the peak-growth
  ! check non-tautological. 200 steps/period keeps the effective tangent
  ! mass-regularised enough for a reliable Newton direction; a coarser step at
  ! this mesh + the tiny rotational inertia ill-conditions the solve. The banded
  ! and element-parallel production kernel keeps this smoke profile cheap while
  ! the long 100-period decay run remains a separate validation profile.
  INTEGER, PARAMETER :: NE = 32, NN = NE + 1, NDOF = 6*NN
  INTEGER, PARAMETER :: NPP = 200, NPER = 2, NSTEP = NPP*NPER
  INTEGER :: nfail, i, es, n_iter, step, k
  INTEGER :: conn(2, NE)
  REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
  REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
  REAL(wp) :: sigma1, f1, period_an, dt, norm, x, phimax, phi(NN), slope(NN)
  REAL(wp) :: strain_e, kinetic_e, energy(0:NSTEP), peak(NPER), e0, max_gain, noise_floor, emax
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

  q = 0.0_wp
  DO i = 1, NN
    x = REAL(i - 1, wp)*L/REAL(NE, wp)
    nodes_ref(:, i) = [x, 0.0_wp, 0.0_wp]
    q(6*i - 5) = x
    q(6*i - 3) = norm*phi(i)
    q(6*i - 1) = -ATAN(norm*slope(i))
  END DO
  vel = 0.0_wp; f_ext = 0.0_wp
  cfg%abs_tol = 1.0e-9_wp                       ! free vibration: absolute residual gate

  CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                        .TRUE., q, f_ext, [INTEGER ::], acc, es, em)
  CALL require(es == CD_DYN_OK, 'energy:a0-ErrStat')
  CALL total_energy(q, vel, energy(0))
  e0 = energy(0)
  CALL require(e0 > 0.0_wp, 'energy:E0-positive')

  DO step = 1, NSTEP
    CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                    q, vel, acc, f_ext, [INTEGER ::], dt, cfg, q_new, v_new, a_new, &
                                    converged, stalled, n_iter, es, em)
    CALL require(es == CD_DYN_OK .AND. converged .AND. .NOT. stalled, 'energy:step-converged')
    q = q_new; vel = v_new; acc = a_new
    CALL total_energy(q, vel, energy(step))
  END DO

  ! per-period peak energy (max within each period) and the largest period-to-period gain
  DO k = 1, NPER
    peak(k) = MAXVAL(energy((k - 1)*NPP:k*NPP))
  END DO
  max_gain = -HUGE(1.0_wp)
  DO k = 1, NPER - 1
    max_gain = MAX(max_gain, peak(k + 1) - peak(k))
  END DO
  emax = MAXVAL(energy)
  noise_floor = 1.0e-9_wp*e0                     ! round-off margin; instability grows by O(E0)

  WRITE (*, '(A,ES13.6,A,ES12.4,A,ES12.4)') 'L1-8 energy: E0 = ', e0, &
    '  max per-period peak gain = ', max_gain, '  floor = ', noise_floor
  ! PRIMARY gate (matches the reference smoke): the per-period PEAK mechanical energy
  ! is monotone non-increasing within numerical noise. gen-α controls a MODIFIED
  ! (algorithmic) energy, so the mechanical energy spikes WITHIN a period as the
  ! non-eigenmode IC's high-frequency content is dissipated -- the per-period-peak
  ! comparison is exactly what tolerates those spikes while catching instability
  ! (a growing peak).
  CALL require(max_gain < noise_floor, 'L1-8:per-period-peak-non-increasing')
  ! catastrophic-blow-up guard: a genuinely unstable integrator grows the energy
  ! without bound (orders of magnitude); the bounded high-frequency IC transient
  ! sits within a small multiple of E0.
  CALL require(emax < 2.0_wp*e0, 'L1-8:energy-bounded')
  ! net decay over the window -- the gen-α numerical dissipation is active
  CALL require(energy(NSTEP) < e0, 'L1-8:net-energy-decay')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran finite-EI gen-alpha is energy-stable (L1-8)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE total_energy(qs, vs, e)
    REAL(wp), INTENT(IN) :: qs(NDOF), vs(NDOF)
    REAL(wp), INTENT(OUT) :: e
    INTEGER :: es_e
    CHARACTER(120) :: em_e
    CALL CD_Cosserat_Mechanical_Energy(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                       .TRUE., qs, vs, strain_e, kinetic_e, es_e, em_e)
    CALL require(es_e == CD_DYN_OK, 'energy:diagnostic-ErrStat')
    e = strain_e + kinetic_e
  END SUBROUTINE total_energy

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

END PROGRAM test_l1_energy_stability
