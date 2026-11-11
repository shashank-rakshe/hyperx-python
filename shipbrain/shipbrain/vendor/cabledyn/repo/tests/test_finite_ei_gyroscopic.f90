! File: tests/test_finite_ei_gyroscopic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_gyroscopic
  !! ROTATION-DOMINATED (gyroscopic) precession for large-rotation finite-EI dynamics.
  !! This covers the blind spot in the symmetric-top precession gate
  !! (test_finite_ei_precession): that top is slender, so its precession is ~89% ORBITAL
  !! (carried by the exact translational DOFs) and is reproduced to round-off even though
  !! the additive integrator omits the section gyroscopic torque omega x J omega. That
  !! gate would therefore stay green even if the multiplicative-SO(3) gyroscopic
  !! coupling carried a sign or frame error -- exactly where such an error would hide
  !! and where there is the least oracle. This gate removes that blind spot.
  !!
  !! Setup: a centred rod laid along GLOBAL Z (reference frame Lam0 = I, so the
  !! section-spin diagnostic Lambda J Lambda^T is exact) with a HEAVY cross section
  !! (I_rho >> rho_A L^2, orbital fraction ~0.8%), spun FAST about its own symmetry
  !! axis z (which leaves the centreline fixed -- a pure director motion) plus a
  !! small transverse rate. The torque-free symmetry axis then precesses about the
  !! fixed H at the analytical fast-top rate phidot = |H|/I1 ~ I3 w3 / I1, a rate
  !! that SCALES with the axial spin w3 and is ~99% gyroscopic in origin -- so
  !! matching it is a genuine test of the gyroscopic physics, not of the centreline.
  !!
  !! Documented additive-integrator baseline (the teeth): the precession rate is
  !! short of the analytical gyroscopic rate by an error that GROWS with the axial
  !! spin -- 1.9% at w3 = 0.5, 12.6% at w3 = 2.0, ~49% at w3 = 4.0 before the rod
  !! leaves the |theta| < pi chart and the step fails. A frame-correct integrator
  !! that carries omega x J omega keeps this error small at all spin rates (asserted for
  !! the multiplicative-SO(3) path in test_finite_ei_gyro_dynamics). The spin-scaling
  !! error is the gyroscopic signature; a gyroscopic sign error would break the low-spin
  !! match this gate asserts, which the slender symmetric-top gate cannot see.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Gen_Alpha_Step, CD_Cosserat_Initial_Acceleration
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK
  USE CableDyn_SO3, ONLY: CD_Exp_SO3
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 8, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e4_wp, GAS = 1.0e3_wp, EI = 1.0e1_wp, GJ = 1.0e1_wp
  REAL(wp), PARAMETER :: RHO_A = 1.0_wp, I_RHO_T = 10.0_wp, I_RHO_N = 20.0_wp  ! heavy section -> gyroscopic
  REAL(wp), PARAMETER :: W_TRANS = 0.05_wp                                     ! fixed small transverse rate
  INTEGER :: nfail
  nfail = 0

  CALL case_gyroscopic_precession_error()
  CALL case_gyroscopic_chart_crash()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI gyroscopic additive baseline (rotation-dominated fast-top precession)'

CONTAINS

  SUBROUTINE run_fast_top(w3, w1, dt, nstep, prec_rate, phidot_analytic, h_drift, crashed, n_done)
    !! Free fast-top spin: axial rate w3 about the symmetry axis z + transverse rate
    !! w1 about x. Returns the measured precession rate of the symmetry axis about H,
    !! the analytical fast-top rate phidot = |H(0)|/I1, the peak relative
    !! angular-momentum drift, and whether the additive step failed before nstep.
    REAL(wp), INTENT(IN) :: w3, w1, dt
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(OUT) :: prec_rate, phidot_analytic, h_drift
    LOGICAL, INTENT(OUT) :: crashed
    INTEGER, INTENT(OUT) :: n_done
    INTEGER :: conn(2, NE), i, es, n_iter, step
    REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
    REAL(wp) :: w0(3), ri(3), h0(3), hh(3), hnorm, i1, axis0(3), axis(3), swept
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    w0 = [w1, 0.0_wp, w3]          ! transverse about x, axial spin about z (the symmetry axis)
    DO i = 1, NE
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
      ra(i) = RHO_A; it(i) = I_RHO_T; in_(i) = I_RHO_N
    END DO
    q = 0.0_wp; vel = 0.0_wp; f_ext = 0.0_wp
    DO i = 1, NN
      ri = [0.0_wp, 0.0_wp, -0.5_wp*L + REAL(i - 1, wp)*L/REAL(NE, wp)]   ! centred rod on z (Lam0 = I)
      nodes_ref(:, i) = ri
      q(6*i - 5:6*i - 3) = ri
      vel(6*i - 5:6*i - 3) = cross(w0, ri)
      vel(6*i - 2:6*i) = w0
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-10_wp; cfg%rel_tol = 1.0e-9_wp

    crashed = .FALSE.; n_done = 0; h_drift = 0.0_wp; prec_rate = 0.0_wp
    CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                          .TRUE., q, f_ext, [INTEGER ::], acc, es, em)
    h0 = angular_momentum(q, vel)
    hnorm = NORM2(h0)
    i1 = I_RHO_T*L + RHO_A*L**3/12.0_wp
    phidot_analytic = hnorm/i1
    axis0 = symmetry_axis(q)
    DO step = 1, nstep
      CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                      q, vel, acc, f_ext, [INTEGER ::], dt, cfg, q_new, v_new, a_new, &
                                      converged, stalled, n_iter, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. converged) THEN
        crashed = .TRUE.
        RETURN
      END IF
      q = q_new; vel = v_new; acc = a_new
      n_done = step
      hh = angular_momentum(q, vel)
      h_drift = MAX(h_drift, NORM2(hh - h0)/hnorm)
    END DO
    axis = symmetry_axis(q)
    swept = angle_about(axis0, axis, h0/hnorm)
    prec_rate = swept/(REAL(nstep, wp)*dt)
  END SUBROUTINE run_fast_top

  SUBROUTINE case_gyroscopic_precession_error()
    !! Fast-top precession. The rate is gyroscopic in origin and must match the
    !! analytical phidot = |H|/I1. The additive integrator's error GROWS with the
    !! axial spin -- the gyroscopic signature -- so it is bounded at low spin and
    !! fails at higher spin. The multiplicative path (carrying omega x J omega) keeps
    !! it bounded at all spin rates (test_finite_ei_gyro_dynamics).
    REAL(wp) :: r_lo, r_hi, pa_lo, pa_hi, hd, rel_lo, rel_hi, growth
    LOGICAL :: crashed
    INTEGER :: n_done

    CALL run_fast_top(0.5_wp, W_TRANS, 0.01_wp, 40, r_lo, pa_lo, hd, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 40, 'gyro:low-spin-completes')
    CALL run_fast_top(2.0_wp, W_TRANS, 0.01_wp, 30, r_hi, pa_hi, hd, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 30, 'gyro:high-spin-completes')

    ! sanity: the motion IS the fast gyroscopic precession, not a slow transverse
    ! tumble -- the rate is many times the transverse rate (no-gyro would give ~w1).
    CALL require(r_lo > 5.0_wp*W_TRANS, 'gyro:precession-is-fast-gyroscopic')

    rel_lo = ABS(r_lo - pa_lo)/pa_lo
    rel_hi = ABS(r_hi - pa_hi)/pa_hi
    ! bounded at low spin (the regime where the additive scheme is used)
    CALL require(rel_lo < 5.0e-2_wp, 'gyro:low-spin-rate-bounded')
    ! teeth: the gyroscopic precession rate is wrong at higher spin
    CALL require(rel_hi > 5.0e-2_wp, 'gyro:teeth-rate-wrong-at-higher-spin')
    ! teeth: the error SCALES with axial spin (gyroscopic signature, not a fixed offset)
    growth = rel_hi/rel_lo
    CALL require(growth > 3.0_wp, 'gyro:teeth-error-grows-with-axial-spin')

    WRITE (*, '(A,ES10.3,A,ES10.3)') '  [gyro precession] rel err: w3=0.5 -> ', rel_lo, '   w3=2.0 -> ', rel_hi
    WRITE (*, '(A,F6.2,A)') '    growth (rel_hi/rel_lo) = ', growth, ' (error scales with axial spin)'
  END SUBROUTINE case_gyroscopic_precession_error

  SUBROUTINE case_gyroscopic_chart_crash()
    !! Teeth: a sustained fast axial spin drives the directors out of the |theta| < pi
    !! chart and the additive step fails. A multiplicative-SO(3) update wraps Lambda
    !! and sustains the spin (test_finite_ei_gyro_dynamics asserts completion there).
    REAL(wp) :: r, pa, hd
    LOGICAL :: crashed
    INTEGER :: n_done

    CALL run_fast_top(4.0_wp, 0.5_wp, 0.01_wp, 200, r, pa, hd, crashed, n_done)
    CALL require(crashed .AND. n_done < 200, 'gyro:additive-cannot-sustain-fast-spin')
    WRITE (*, '(A,I0,A)') '  [gyro chart] sustained fast spin left the chart after ', n_done, ' steps'
  END SUBROUTINE case_gyroscopic_chart_crash

  FUNCTION angular_momentum(q, v) RESULT(h)
    !! Spatial angular momentum about the origin: consistent-mass orbital part plus
    !! the section spin sum_i l_i Lambda_i J Lambda_i^T omega_i. The rod is along z so
    !! Lam0 = I and Lambda_i = exp(theta_i) is the exact current director frame.
    REAL(wp), INTENT(IN) :: q(NDOF), v(NDOF)
    REAL(wp) :: h(3), r1(3), r2(3), d1(3), d2(3), th(3), w(3), lam(3, 3), jmat(3, 3)
    REAL(wp) :: le, b_d, b_o, li
    INTEGER :: e, ia, ib, i
    h = 0.0_wp
    le = L/REAL(NE, wp); b_d = le/3.0_wp; b_o = le/6.0_wp
    DO e = 1, NE
      ia = e; ib = e + 1
      r1 = q(6*ia - 5:6*ia - 3); r2 = q(6*ib - 5:6*ib - 3)
      d1 = v(6*ia - 5:6*ia - 3); d2 = v(6*ib - 5:6*ib - 3)
      h = h + RHO_A*(b_d*cross(r1, d1) + b_o*cross(r1, d2) + b_o*cross(r2, d1) + b_d*cross(r2, d2))
    END DO
    jmat = 0.0_wp; jmat(1, 1) = I_RHO_T; jmat(2, 2) = I_RHO_T; jmat(3, 3) = I_RHO_N
    DO i = 1, NN
      IF (i == 1 .OR. i == NN) THEN
        li = 0.5_wp*le
      ELSE
        li = le
      END IF
      th = q(6*i - 2:6*i); w = v(6*i - 2:6*i)
      lam = CD_Exp_SO3(th)
      h = h + li*MATMUL(lam, MATMUL(jmat, MATMUL(TRANSPOSE(lam), w)))
    END DO
  END FUNCTION angular_momentum

  FUNCTION symmetry_axis(q) RESULT(ax)
    REAL(wp), INTENT(IN) :: q(NDOF)
    REAL(wp) :: ax(3)
    ax = q(6*NN - 5:6*NN - 3) - q(1:3)
    ax = ax/NORM2(ax)
  END FUNCTION symmetry_axis

  FUNCTION angle_about(a, b, n) RESULT(ang)
    REAL(wp), INTENT(IN) :: a(3), b(3), n(3)
    REAL(wp) :: ang, ap(3), bp(3)
    ap = a - DOT_PRODUCT(a, n)*n; bp = b - DOT_PRODUCT(b, n)*n
    ap = ap/NORM2(ap); bp = bp/NORM2(bp)
    ang = ACOS(MAX(-1.0_wp, MIN(1.0_wp, DOT_PRODUCT(ap, bp))))
  END FUNCTION angle_about

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

END PROGRAM test_finite_ei_gyroscopic
