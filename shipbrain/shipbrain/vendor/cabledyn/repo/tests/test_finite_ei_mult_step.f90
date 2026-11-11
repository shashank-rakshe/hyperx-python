! File: tests/test_finite_ei_mult_step.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_mult_step
  !! Production gate for the multiplicative-SO(3) rotation update:
  !! the consistent tangent in the DYNAMICS (not just in the standalone FD oracle).
  !!
  !! (1) CONSISTENT-TANGENT / fast convergence. A free precessing spin at moderate rate
  !!     under the multiplicative path converges in a SMALL, bounded number of Newton
  !!     iterations every step. This is the production proof that the chain Jacobian
  !!     J_c = dexp_inv(theta_alpha) dexp((1-af) psi) is the consistent tangent: with the
  !!     additive (J_c-free) tangent the same case takes 20-30 iterations and then stalls;
  !!     with J_c it converges in ~2. (The math itself is FD-verified in
  !!     test_finite_ei_mult_tangent.)
  !! (2) SMALL-ROTATION PARITY. At a bounded-small rotation a single step matches the
  !!     additive path to O(theta^2) -- the two integrators agree where T_so3 ~ I.
  !!
  !! SCOPE: the kinematics + consistent tangent. Large-rotation STABILITY (energy growth in
  !! a sustained fast spin) depends on the spatial gyroscopic torque omega x J omega, which
  !! the geometrically-correct kinematics expose and which the additive parametrisation
  !! error happened to mask -- that is checked in test_finite_ei_gyro_dynamics.
  !! This gate therefore checks fast convergence over a bounded window, not indefinite
  !! large-rotation stability.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Gen_Alpha_Step, CD_Cosserat_Initial_Acceleration
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 4, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e4_wp, GAS = 1.0e3_wp, EI = 1.0e1_wp, GJ = 1.0e1_wp
  REAL(wp), PARAMETER :: RHO_A = 1.0_wp, I_RHO_T = 1.0e-2_wp, I_RHO_N = 2.0e-2_wp
  REAL(wp), PARAMETER :: C45 = 0.70710678118654752_wp
  INTEGER :: nfail
  nfail = 0

  CALL case_consistent_tangent_fast_convergence()
  CALL case_small_rotation_parity()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: multiplicative-SO(3) step converges with the consistent tangent'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE spin_steps(omega_rate, dt, nstep, mult, qf, vf, af, max_nit, n_done, crashed)
    !! Free spin of a centred rod about the 45-deg axis; returns the final state, the
    !! peak Newton-iteration count, and whether any step failed within the window.
    REAL(wp), INTENT(IN) :: omega_rate, dt
    INTEGER, INTENT(IN) :: nstep
    LOGICAL, INTENT(IN) :: mult
    REAL(wp), INTENT(OUT) :: qf(NDOF), vf(NDOF), af(NDOF)
    INTEGER, INTENT(OUT) :: max_nit, n_done
    LOGICAL, INTENT(OUT) :: crashed
    INTEGER :: conn(2, NE), i, es, n_iter, step
    REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
    REAL(wp) :: w0(3), ri(3)
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    w0 = omega_rate*[C45, C45, 0.0_wp]
    DO i = 1, NE
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
      ra(i) = RHO_A; it(i) = I_RHO_T; in_(i) = I_RHO_N
    END DO
    q = 0.0_wp; vel = 0.0_wp; f_ext = 0.0_wp
    DO i = 1, NN
      ri = [-0.5_wp*L + REAL(i - 1, wp)*L/REAL(NE, wp), 0.0_wp, 0.0_wp]
      nodes_ref(:, i) = ri
      q(6*i - 5:6*i - 3) = ri
      vel(6*i - 5:6*i - 3) = cross(w0, ri)
      vel(6*i - 2:6*i) = w0
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-10_wp; cfg%rel_tol = 1.0e-9_wp
    cfg%multiplicative_rotation = mult
    crashed = .FALSE.; n_done = 0; max_nit = 0
    CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                          .TRUE., q, f_ext, [INTEGER ::], acc, es, em, v=vel, multiplicative=mult)
    DO step = 1, nstep
      CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                      q, vel, acc, f_ext, [INTEGER ::], dt, cfg, q_new, v_new, a_new, &
                                      converged, stalled, n_iter, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. converged) THEN
        crashed = .TRUE.
        EXIT
      END IF
      q = q_new; vel = v_new; acc = a_new; n_done = step; max_nit = MAX(max_nit, n_iter)
    END DO
    qf = q; vf = vel; af = acc
  END SUBROUTINE spin_steps

  SUBROUTINE case_consistent_tangent_fast_convergence()
    !! Over a bounded moderate-rotation window the multiplicative step converges every
    !! step with a small Newton-iteration count -- the production signature of the
    !! consistent tangent (J_c-free it stalls at ~20-30 iterations).
    REAL(wp) :: qf(NDOF), vf(NDOF), af(NDOF)
    INTEGER :: max_nit, n_done
    LOGICAL :: crashed
    CALL spin_steps(0.5_wp, 0.02_wp, 40, .TRUE., qf, vf, af, max_nit, n_done, crashed)
    CALL require(.NOT. crashed .AND. n_done == 40, 'consistent-tangent:window-converges')
    CALL require(max_nit <= 5, 'consistent-tangent:few-newton-iterations')
    WRITE (*, '(A,I0,A,I0)') '  [mult convergence] moderate-rotation window: ', n_done, &
      ' steps, max Newton iters = ', max_nit
  END SUBROUTINE case_consistent_tangent_fast_convergence

  SUBROUTINE case_small_rotation_parity()
    !! At a bounded-small rotation the multiplicative and additive paths agree to
    !! O(theta^2): one short window, compared state-by-state.
    REAL(wp) :: qa(NDOF), va(NDOF), aa(NDOF), qm(NDOF), vm(NDOF), am(NDOF), dq, dv
    INTEGER :: na, nm, nita, nitm
    LOGICAL :: ca, cm
    CALL spin_steps(0.01_wp, 0.02_wp, 20, .FALSE., qa, va, aa, nita, na, ca)
    CALL spin_steps(0.01_wp, 0.02_wp, 20, .TRUE., qm, vm, am, nitm, nm, cm)
    CALL require(.NOT. ca .AND. .NOT. cm .AND. na == 20 .AND. nm == 20, 'parity:both-complete')
    dq = nan_max_abs(qa - qm); dv = nan_max_abs(va - vm)
    CALL require(dq < 1.0e-5_wp .AND. dv < 1.0e-5_wp, 'parity:small-rotation-additive-vs-multiplicative')
    WRITE (*, '(A,ES10.3,A,ES10.3)') '  [mult parity] small-rotation max|dq|=', dq, '  max|dv|=', dv
  END SUBROUTINE case_small_rotation_parity

  PURE FUNCTION cross(a, b) RESULT(c3)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c3(3)
    c3 = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_finite_ei_mult_step
