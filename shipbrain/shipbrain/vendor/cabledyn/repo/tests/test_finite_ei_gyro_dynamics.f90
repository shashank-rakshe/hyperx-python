! File: tests/test_finite_ei_gyro_dynamics.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_gyro_dynamics
  !! Spatial-gyroscopic dynamics gates: the gyroscopic + config-dependent inertia residual/tangent
  !! (multiplicative_rotation = .TRUE.) REMOVES the large-rotation failure modes that the
  !! additive small-rotation integrator failed (test_finite_ei_large_rotation /
  !! _precession / _gyroscopic establish those additive baselines). Rod along z (Lam0 = I)
  !! so the lumped section-spin diagnostic Lambda J Lambda^T is exact.
  !!
  !!  GATE A  chart-completes + momentum: a sustained large free spin (rho_inf = 1) COMPLETES
  !!          (additive crashes leaving the |theta| < pi chart at ~step 81) with the spatial
  !!          angular momentum conserved (the additive scheme only conserved it to O(amplitude)).
  !!  GATE B  gyroscopic precession: the fast-top precession rate matches the analytical Euler
  !!          rate phidot = |H|/I1 at all spin rates and the error does NOT grow with the axial
  !!          spin (the additive error grew 1.9% -> 12.6% -> ~49% then crashed).
  !!
  !! SCOPE: stability + correct momentum/precession. gen-alpha is not energy-momentum-conserving
  !! for the nonlinear rotational problem, so round-off ENERGY conservation is asserted only for
  !! the rigid free spin with the consistent kinetic energy (GATE C), not for deforming dynamics.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Gen_Alpha_Step, CD_Cosserat_Initial_Acceleration, &
                                      CD_Cosserat_Mechanical_Energy
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK
  USE CableDyn_SO3, ONLY: CD_Exp_SO3
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 8, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e4_wp, GAS = 1.0e3_wp, EI = 1.0e1_wp, GJ = 1.0e1_wp
  REAL(wp), PARAMETER :: C45 = 0.70710678118654752_wp
  REAL(wp), PARAMETER :: W_TRANS = 0.05_wp
  REAL(wp) :: rho_a, i_t, i_n
  INTEGER :: nfail
  nfail = 0

  CALL case_chart_completes_and_momentum()
  CALL case_gyroscopic_precession_correct()
  CALL case_frame_objectivity()
  CALL case_consistent_initial_accel()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: spatial-gyroscopic dynamics (chart-completes + momentum + precession)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_chart_completes_and_momentum()
    !! GATE A. Orbital-config rod, 45-deg spin axis, sustained large rotation (rho_inf = 1):
    !! the multiplicative path COMPLETES (additive chart-crashes ~step 81) and conserves the
    !! spatial angular momentum to round-off (additive: O(amplitude) ~ 0.33 at this rate).
    REAL(wp) :: h_drift, prec, pa
    LOGICAL :: crashed
    INTEGER :: n_done
    rho_a = 1.0_wp; i_t = 1.0e-2_wp; i_n = 2.0e-2_wp
    CALL run_spin([2.0_wp*C45, 0.0_wp, 2.0_wp*C45], 0.02_wp, 200, h_drift, prec, pa, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 200, 'gyro:chart-completes-large-rotation')
    CALL require(h_drift < 1.0e-3_wp, 'gyro:angular-momentum-conserved')
    WRITE (*, '(A,I0,A,ES10.3)') '  [gyro A] large spin completed ', n_done, &
      ' steps; max |H-H0|/|H0| = ', h_drift
  END SUBROUTINE case_chart_completes_and_momentum

  SUBROUTINE case_gyroscopic_precession_correct()
    !! GATE B. Heavy-section fast top (orbital fraction ~0.8%): the precession is ~99%
    !! gyroscopic. The multiplicative path matches the analytical Euler rate at all spins and
    !! the error does not grow with axial spin (the additive error grew with spin).
    REAL(wp) :: h, r_lo, r_hi, pa_lo, pa_hi, rel_lo, rel_hi
    LOGICAL :: crashed
    INTEGER :: n_done
    rho_a = 1.0_wp; i_t = 10.0_wp; i_n = 20.0_wp
    CALL run_top(0.5_wp, W_TRANS, 0.01_wp, 40, r_lo, pa_lo, h, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 40, 'gyro:low-spin-completes')
    CALL run_top(2.0_wp, W_TRANS, 0.01_wp, 30, r_hi, pa_hi, h, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 30, 'gyro:high-spin-completes')
    rel_lo = ABS(r_lo - pa_lo)/pa_lo
    rel_hi = ABS(r_hi - pa_hi)/pa_hi
    CALL require(rel_lo < 1.0e-2_wp, 'gyro:precession-matches-analytic-low-spin')
    CALL require(rel_hi < 1.0e-2_wp, 'gyro:precession-matches-analytic-high-spin (no spin-growth)')
    WRITE (*, '(A,ES10.3,A,ES10.3)') '  [gyro B] precession rel err: w3=0.5 -> ', rel_lo, &
      '   w3=2.0 -> ', rel_hi
  END SUBROUTINE case_gyroscopic_precession_correct

  SUBROUTINE case_frame_objectivity()
    !! FRAME OBJECTIVITY (gates the reference-orientation hardening fix): a free spin's total
    !! mechanical energy drift is invariant under rotating the WHOLE problem. The same physical
    !! gyroscopic fast-top is built with the rod along z (Lam0 = I) and along x (Lam0 /= I), with
    !! the spin axis rotated identically. The config-dependent inertia must use each element's
    !! Lam0, or the inclined (x) rod gets the wrong section inertia and a different (non-objective)
    !! energy drift. Equal drifts => the rotational inertia is built in the element reference frame.
    REAL(wp) :: ed_z, ed_x
    LOGICAL :: cz, cx
    INTEGER :: nz, nx
    rho_a = 1.0_wp; i_t = 10.0_wp; i_n = 20.0_wp        ! section-dominated: inertia frame matters most
    ! z-rod: axis e3 = +z, spin w0 = (w1, 0, w3); x-rod: rotate the whole setup z->x about -y,
    ! so e3 = +x and w0 = (w3, 0, -w1) (the same physical spin in the rotated frame).
    CALL run_energy([0.0_wp, 0.0_wp, 1.0_wp], [0.05_wp, 0.0_wp, 2.0_wp], 0.01_wp, 30, ed_z, cz, nz)
    CALL run_energy([1.0_wp, 0.0_wp, 0.0_wp], [2.0_wp, 0.0_wp, -0.05_wp], 0.01_wp, 30, ed_x, cx, nx)
    CALL require(.NOT. cz .AND. .NOT. cx .AND. nz == 30 .AND. nx == 30, 'gyro:objectivity-both-complete')
    CALL require(ABS(ed_z - ed_x) < 1.0e-10_wp, 'gyro:energy-drift-objective-under-rotation')
    ! with the CONSISTENT (config-dependent) kinetic energy, the rigid free spin conserves total
    ! energy to round-off -- the earlier apparent drift was the frozen-reference-mass KE artifact,
    ! not the integrator. (Energy exchange in DEFORMING dynamics is not asserted here.)
    CALL require(ed_z < 1.0e-6_wp, 'gyro:energy-conserved-rigid-spin-consistent-KE')
    WRITE (*, '(A,ES10.3,A,ES10.3)') '  [gyro C] energy drift: z-rod = ', ed_z, '   x-rod = ', ed_x
  END SUBROUTINE case_frame_objectivity

  SUBROUTINE case_consistent_initial_accel()
    !! CONSISTENT MULTIPLICATIVE IC (gates the velocity-aware initializer hardening fix): for a free
    !! ASYMMETRIC spin (omega not on a principal axis) the gyroscopic residual requires the Euler
    !! acceleration alpha = -I_s^{-1}(omega x I_s omega) at t_0; the velocity-INDEPENDENT solve
    !! returns zero rotational accel and would inject a step-1 transient. With v + multiplicative,
    !! CD_Cosserat_Initial_Acceleration must return the Euler acceleration per node.
    INTEGER :: conn(2, NE), i, es
    REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
    REAL(wp) :: q(NDOF), vel(NDOF), f_ext(NDOF), a_mult(NDOF), a_vi(NDOF), w(3), euler(3), Iw(3)
    CHARACTER(120) :: em
    rho_a = 1.0_wp; i_t = 10.0_wp; i_n = 20.0_wp      ! section-dominated, z-rod (Lam0 = I) -> I_s = diag(it,it,in)
    w = [0.7_wp, -0.5_wp, 0.9_wp]                     ! asymmetric: components on transverse AND axial
    DO i = 1, NE
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
      ra(i) = rho_a; it(i) = i_t; in_(i) = i_n
    END DO
    q = 0.0_wp; vel = 0.0_wp; f_ext = 0.0_wp
    DO i = 1, NN
      nodes_ref(:, i) = [0.0_wp, 0.0_wp, -0.5_wp*L + REAL(i - 1, wp)*L/REAL(NE, wp)]
      q(6*i - 5:6*i - 3) = nodes_ref(:, i)
      vel(6*i - 5:6*i - 3) = cross(w, nodes_ref(:, i))
      vel(6*i - 2:6*i) = w
    END DO
    ! Euler acceleration at theta = 0: I_s = diag(it,it,in); alpha = -I_s^{-1}(w x I_s w)
    Iw = [i_t*w(1), i_t*w(2), i_n*w(3)]
    euler = -cross(w, Iw)
    euler = [euler(1)/i_t, euler(2)/i_t, euler(3)/i_n]
    CALL require(NORM2(euler) > 0.1_wp, 'consistent-ic:euler-accel-nontrivial')
    CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                          q, f_ext, [INTEGER ::], a_mult, es, em, v=vel, multiplicative=.TRUE.)
    CALL require(es == CD_DYN_OK, 'consistent-ic:multiplicative-solve-ok')
    CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                          q, f_ext, [INTEGER ::], a_vi, es, em)
    CALL require(es == CD_DYN_OK, 'consistent-ic:velocity-independent-solve-ok')
    ! the velocity-independent IC misses the gyroscopic term -> ~zero rotational accel
    CALL require(nan_max_abs(a_vi(4:6)) < 1.0e-8_wp, 'consistent-ic:velocity-independent-misses-euler')
    ! the multiplicative IC returns the Euler acceleration on every node
    DO i = 1, NN
      CALL require(nan_max_abs(a_mult(6*i - 2:6*i) - euler) < 1.0e-9_wp, 'consistent-ic:multiplicative-is-euler')
    END DO
    WRITE (*, '(A,3ES11.3)') '  [gyro D] consistent IC rotational accel = Euler accel ', euler
  END SUBROUTINE case_consistent_initial_accel

  SUBROUTINE run_energy(e3, w0, dt, nstep, e_drift, crashed, n_done)
    !! Free spin of a centred rod laid along the unit axis e3, spatial angular velocity w0;
    !! returns the peak relative total-mechanical-energy drift (frame-independent observable).
    REAL(wp), INTENT(IN) :: e3(3), w0(3), dt
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(OUT) :: e_drift
    LOGICAL, INTENT(OUT) :: crashed
    INTEGER, INTENT(OUT) :: n_done
    INTEGER :: conn(2, NE), i, es, n_iter, step
    REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
    REAL(wp) :: ri(3), se, ke, e0
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    DO i = 1, NE
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
      ra(i) = rho_a; it(i) = i_t; in_(i) = i_n
    END DO
    q = 0.0_wp; vel = 0.0_wp; f_ext = 0.0_wp
    DO i = 1, NN
      ri = (-0.5_wp*L + REAL(i - 1, wp)*L/REAL(NE, wp))*e3   ! centred rod along e3
      nodes_ref(:, i) = ri
      q(6*i - 5:6*i - 3) = ri
      vel(6*i - 5:6*i - 3) = cross(w0, ri)
      vel(6*i - 2:6*i) = w0
    END DO
    cfg%rho_inf = 1.0_wp; cfg%abs_tol = 1.0e-10_wp; cfg%rel_tol = 1.0e-9_wp
    cfg%multiplicative_rotation = .TRUE.
    crashed = .FALSE.; n_done = 0; e_drift = 0.0_wp
    CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                          .TRUE., q, f_ext, [INTEGER ::], acc, es, em, v=vel, multiplicative=.TRUE.)
    CALL CD_Cosserat_Mechanical_Energy(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                       q, vel, se, ke, es, em, multiplicative=.TRUE.)
    e0 = se + ke
    DO step = 1, nstep
      CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                      q, vel, acc, f_ext, [INTEGER ::], dt, cfg, q_new, v_new, a_new, &
                                      converged, stalled, n_iter, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. converged) THEN
        crashed = .TRUE.
        RETURN
      END IF
      q = q_new; vel = v_new; acc = a_new; n_done = step
      CALL CD_Cosserat_Mechanical_Energy(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                         q, vel, se, ke, es, em, multiplicative=.TRUE.)
      e_drift = MAX(e_drift, ABS(se + ke - e0)/e0)
    END DO
  END SUBROUTINE run_energy

  SUBROUTINE run_spin(w0, dt, nstep, h_drift, prec_rate, phidot_analytic, crashed, n_done)
    !! Free spin with spatial angular velocity w0 (multiplicative path); returns peak relative
    !! angular-momentum drift, the symmetry-axis precession rate, and the analytical |H|/I1 rate.
    REAL(wp), INTENT(IN) :: w0(3), dt
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(OUT) :: h_drift, prec_rate, phidot_analytic
    LOGICAL, INTENT(OUT) :: crashed
    INTEGER, INTENT(OUT) :: n_done
    INTEGER :: conn(2, NE), i, es, n_iter, step
    REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
    REAL(wp) :: ri(3), h0(3), hh(3), hnorm, i1, axis0(3), axis(3)
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    DO i = 1, NE
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
      ra(i) = rho_a; it(i) = i_t; in_(i) = i_n
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
    cfg%multiplicative_rotation = .TRUE.
    crashed = .FALSE.; n_done = 0; h_drift = 0.0_wp; prec_rate = 0.0_wp
    CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                          .TRUE., q, f_ext, [INTEGER ::], acc, es, em, v=vel, multiplicative=.TRUE.)
    h0 = angular_momentum(q, vel); hnorm = NORM2(h0)
    i1 = i_t*L + rho_a*L**3/12.0_wp
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
      q = q_new; vel = v_new; acc = a_new; n_done = step
      hh = angular_momentum(q, vel)
      h_drift = MAX(h_drift, NORM2(hh - h0)/hnorm)
    END DO
    axis = symmetry_axis(q)
    prec_rate = angle_about(axis0, axis, h0/hnorm)/(REAL(nstep, wp)*dt)
  END SUBROUTINE run_spin

  SUBROUTINE run_top(w3, w1, dt, nstep, prec_rate, phidot_analytic, h_drift, crashed, n_done)
    !! Fast top: axial spin w3 about z + small transverse w1 about x.
    REAL(wp), INTENT(IN) :: w3, w1, dt
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(OUT) :: prec_rate, phidot_analytic, h_drift
    LOGICAL, INTENT(OUT) :: crashed
    INTEGER, INTENT(OUT) :: n_done
    CALL run_spin([w1, 0.0_wp, w3], dt, nstep, h_drift, prec_rate, phidot_analytic, crashed, n_done)
  END SUBROUTINE run_top

  FUNCTION angular_momentum(q, v) RESULT(h)
    REAL(wp), INTENT(IN) :: q(NDOF), v(NDOF)
    REAL(wp) :: h(3), r1(3), r2(3), d1(3), d2(3), th(3), w(3), lam(3, 3), jmat(3, 3), le, b_d, b_o, li
    INTEGER :: e, ia, ib, i
    h = 0.0_wp
    le = L/REAL(NE, wp); b_d = le/3.0_wp; b_o = le/6.0_wp
    DO e = 1, NE
      ia = e; ib = e + 1
      r1 = q(6*ia - 5:6*ia - 3); r2 = q(6*ib - 5:6*ib - 3)
      d1 = v(6*ia - 5:6*ia - 3); d2 = v(6*ib - 5:6*ib - 3)
      h = h + rho_a*(b_d*cross(r1, d1) + b_o*cross(r1, d2) + b_o*cross(r2, d1) + b_d*cross(r2, d2))
    END DO
    jmat = 0.0_wp; jmat(1, 1) = i_t; jmat(2, 2) = i_t; jmat(3, 3) = i_n
    DO i = 1, NN
      li = le; IF (i == 1 .OR. i == NN) li = 0.5_wp*le
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

END PROGRAM test_finite_ei_gyro_dynamics
