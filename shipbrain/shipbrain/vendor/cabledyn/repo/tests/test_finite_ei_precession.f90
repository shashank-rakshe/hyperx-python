! File: tests/test_finite_ei_precession.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_precession
  !! Angular-momentum conservation and symmetric-top precession gates for
  !! large-rotation finite-EI dynamics (additive integrator baseline).
  !!
  !! Both gates observe the SAME oracle-free motion: a free (no load, no Dirichlet,
  !! rho_inf = 1) spin of a centred straight rod with the angular velocity set at
  !! 45 deg between the symmetry axis (the rod tangent) and a transverse axis. The
  !! rod is laid along GLOBAL Z so the element reference frame Lam0 = I and the
  !! section-spin term of the angular-momentum diagnostic, Lambda J Lambda^T with
  !! J = diag(I_rho_t, I_rho_t, I_rho_n) (material axis 3 = tangent), is EXACT
  !! (no reference-frame rotation to track).
  !! That axis is NOT a principal axis, so the torque-free motion is the classical
  !! symmetric-top PRECESSION: the angular-momentum vector H is fixed in space and
  !! the symmetry axis sweeps a cone about it at the analytical rate
  !!     phidot = |H| / I1,   I1 = I_rho_t * L + rho_A * L^3 / 12
  !! (transverse moment about the spin point: section + slender-rod orbital part;
  !! the consistent translational mass reproduces the rod orbital inertia exactly).
  !! This is a genuine right-vs-wrong reference, not a self-consistency check.
  !!
  !! Findings banked as the documented additive-integrator baseline (the teeth):
  !!  * ANGULAR MOMENTUM: the additive scheme conserves H only to O(rotation amplitude),
  !!    never to round-off -- drift scales LINEARLY with the spin rate (a decade of rate ->
  !!    a decade of drift), reaching O(1) at large rotation. The frame-correct
  !!    multiplicative-SO(3) path conserves H at large rotation; that is asserted in
  !!    test_finite_ei_gyro_dynamics.
  !!  * PRECESSION: the additive precession rate MATCHES the analytical phidot to ~5
  !!    digits up through moderate rotation (the precession here is orbital-dominated
  !!    -- I1 is ~89% orbital for a slender rod -- and the orbital mechanics ride on
  !!    the exact translational DOFs), and deviates by O(1e-2) at large rotation. The
  !!    precession-rate teeth are therefore MODEST by design: the dramatic additive
  !!    failures at large rotation are the energy drift / spurious strain / chart
  !!    crash gated in test_finite_ei_large_rotation. The precession gate's primary value is the
  !!    positive analytical validation (the model precesses at the correct Euler rate).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Gen_Alpha_Step, CD_Cosserat_Initial_Acceleration
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK
  USE CableDyn_SO3, ONLY: CD_Exp_SO3
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 8, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e4_wp, GAS = 1.0e3_wp, EI = 1.0e1_wp, GJ = 1.0e1_wp
  REAL(wp), PARAMETER :: RHO_A = 1.0_wp, I_RHO_T = 1.0e-2_wp, I_RHO_N = 2.0e-2_wp
  REAL(wp), PARAMETER :: C45 = 0.70710678118654752_wp   ! cos/sin 45 deg
  INTEGER :: nfail
  nfail = 0

  CALL case_angular_momentum_conservation()
  CALL case_symmetric_top_precession()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI precession additive baseline (angular momentum + symmetric-top precession)'

CONTAINS

  SUBROUTINE run_free_spin(omega_rate, dt, nstep, h_drift, prec_rate, phidot_analytic, crashed, n_done)
    !! Free precessing spin of the centred rod at rate omega_rate about the 45-deg
    !! axis. Returns the peak relative angular-momentum drift max|H(t)-H(0)|/|H(0)|,
    !! the measured precession rate of the symmetry axis about H (swept angle / time),
    !! and the analytical symmetric-top rate phidot = |H(0)|/I1.
    REAL(wp), INTENT(IN) :: omega_rate, dt
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(OUT) :: h_drift, prec_rate, phidot_analytic
    LOGICAL, INTENT(OUT) :: crashed
    INTEGER, INTENT(OUT) :: n_done
    INTEGER :: conn(2, NE), i, es, n_iter, step
    REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
    REAL(wp) :: w0(3), ri(3), h0(3), hh(3), hnorm, i1, axis0(3), axis(3), swept
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    w0 = omega_rate*[C45, 0.0_wp, C45]   ! 45 deg between a transverse axis (x) and the symmetry axis (z)
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
      vel(6*i - 5:6*i - 3) = cross(w0, ri)                                ! rigid translational velocity
      vel(6*i - 2:6*i) = w0                                               ! spatial angular velocity
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
    ! precession rate: angle the symmetry axis sweeps about H-hat over the window
    axis = symmetry_axis(q)
    swept = angle_about(axis0, axis, h0/hnorm)
    prec_rate = swept/(REAL(nstep, wp)*dt)
  END SUBROUTINE run_free_spin

  SUBROUTINE case_angular_momentum_conservation()
    !! ANGULAR MOMENTUM. Total spatial angular momentum is conserved for a torque-free spin.
    !! The additive integrator conserves it only to O(amplitude): drift scales
    !! linearly with the spin rate and is O(1) at large rotation.
    REAL(wp) :: d_tiny, d_small, d_large, pr, pa, ratio
    LOGICAL :: crashed
    INTEGER :: n_done

    CALL run_free_spin(0.002_wp, 0.02_wp, 300, d_tiny, pr, pa, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 300, 'angmom:tiny-completes')
    CALL run_free_spin(0.02_wp, 0.02_wp, 300, d_small, pr, pa, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 300, 'angmom:small-completes')
    CALL run_free_spin(2.0_wp, 0.02_wp, 70, d_large, pr, pa, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 70, 'angmom:large-window-pre-crash')

    ! bounded at small rotation (the regime where the additive scheme is used)
    CALL require(d_small < 2.0e-2_wp, 'angmom:small-rotation-bounded')
    ! teeth: the additive integrator is expected to drift O(1) at large rotation
    CALL require(d_large > 1.0e-1_wp, 'angmom:teeth-O(1)-drift-at-large-rotation')
    ! teeth: NOT round-off -- the drift scales linearly with amplitude (a decade of
    ! rate gives a decade of drift), which round-off conservation never would.
    ratio = d_small/d_tiny
    CALL require(ratio > 8.0_wp .AND. ratio < 12.0_wp, 'angmom:teeth-linear-in-amplitude')

    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3)') '  [ang.mom drift] tiny = ', d_tiny, &
      '  small = ', d_small, '  large = ', d_large
    WRITE (*, '(A,F6.2,A)') '    small/tiny ratio = ', ratio, ' (linear in spin rate -> not round-off)'
  END SUBROUTINE case_angular_momentum_conservation

  SUBROUTINE case_symmetric_top_precession()
    !! PRECESSION. The symmetry axis precesses about the fixed H at the analytical
    !! symmetric-top rate phidot = |H|/I1. PRIMARY: the additive integrator matches
    !! this at small rotation (right-vs-wrong validation), and the match is
    !! dt-converged (SUPPLEMENT). TEETH: it deviates at large rotation.
    REAL(wp) :: d, pr_small, pr_half, pr_large, pa_small, pa_half, pa_large
    REAL(wp) :: rel_small, rel_half, rel_large
    LOGICAL :: crashed
    INTEGER :: n_done

    CALL run_free_spin(0.02_wp, 0.02_wp, 300, d, pr_small, pa_small, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 300, 'precession:small-completes')
    rel_small = ABS(pr_small - pa_small)/pa_small
    ! PRIMARY: the additive precession is the analytical Euler rate at small rotation
    ! observed 4.1e-5 at dt and dt/2 (the ~5-digit agreement of the header)
    CALL require(rel_small < 1.0e-4_wp, 'precession:matches-analytic-euler-rate')

    ! SUPPLEMENT: dt-converged -- halving dt leaves the rate on the analytical answer
    CALL run_free_spin(0.02_wp, 0.01_wp, 600, d, pr_half, pa_half, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 600, 'precession:small-dt-half-completes')
    rel_half = ABS(pr_half - pa_half)/pa_half
    CALL require(rel_half < 1.0e-4_wp, 'precession:dt-converged-to-analytic')

    ! TEETH: the precession rate deviates from analytic at large rotation (modest,
    ! by design -- orbital-dominated; the sharp large-rotation teeth are the energy and zero-strain
    ! checks in test_finite_ei_large_rotation).
    CALL run_free_spin(2.0_wp, 0.02_wp, 70, d, pr_large, pa_large, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 70, 'precession:large-window-pre-crash')
    rel_large = ABS(pr_large - pa_large)/pa_large
    CALL require(rel_large > 2.0e-3_wp, 'precession:teeth-deviates-at-large-rotation')

    WRITE (*, '(A,ES10.3,A,ES10.3)') '  [precession] analytic rate (small) = ', pa_small, &
      '   measured = ', pr_small
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3)') '    rel err: small = ', rel_small, &
      '  dt/2 = ', rel_half, '  large = ', rel_large
  END SUBROUTINE case_symmetric_top_precession

  FUNCTION angular_momentum(q, v) RESULT(h)
    !! Spatial angular momentum about the origin: consistent-mass orbital part
    !! (the L0/3, L0/6 blocks that define the translational consistent mass) plus the
    !! current-frame section spin sum_i l_i * Lambda_i J Lambda_i^T omega_i. The rod is
    !! along z so the reference frame Lam0 = I and Lambda_i = exp(theta_i) is the full
    !! current director frame -- the spin inertia is exact with no Lam0 to compose.
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
    !! Current symmetry axis = the tip-to-tip direction of the (rigidly moving) rod.
    REAL(wp), INTENT(IN) :: q(NDOF)
    REAL(wp) :: ax(3)
    ax = q(6*NN - 5:6*NN - 3) - q(1:3)
    ax = ax/NORM2(ax)
  END FUNCTION symmetry_axis

  FUNCTION angle_about(a, b, n) RESULT(ang)
    !! Angle between a and b after projecting out the n-hat (precession axis) component.
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

END PROGRAM test_finite_ei_precession
