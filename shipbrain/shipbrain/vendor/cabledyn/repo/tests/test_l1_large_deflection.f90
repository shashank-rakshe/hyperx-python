! File: tests/test_l1_large_deflection.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_large_deflection
  !! L1-4 large-deflection cantilever, scored on the Fortran finite-EI static
  !! solve against the inextensional planar elastica (Bisshopp & Drucker 1945). A
  !! straight rod along +z, clamped at node 1, carries a transverse +x tip load P;
  !! at the dimensionless load alpha^2 = P L^2 / EI the geometrically-exact tip
  !! position (x_tip, z_tip) must match the elastica reference to < 0.1 % of L,
  !! across alpha^2 in {0.5, 1.0, 2.0} (theta_tip up to ~pi/4). Mirrors the
  !! L1-4 benchmark: same
  !! EI=1e2/EA=1e3/GAs=1e6/GJ=1e2, n_elem=32, and the kinematic-linear-EB warm
  !! start that lets Newton converge in one solve without load stepping --
  !! theta(s) = arctan(P s (2L - s) / (2 EI)) with positions integrated along the
  !! arc, x(s) = int_0^s sin theta, z(s) = int_0^s cos theta (geometric
  !! shortening; a straight linear-EB profile stalls Newton at alpha^2 = 2).
  !! Elastica tip references are the Bisshopp-Drucker elliptic-integral values; the
  !! Fortran solver must reproduce them.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratStatic, ONLY: CosseratSolverConfig, CD_Static_Cosserat_Solve, CD_COS_OK
  IMPLICIT NONE

  ! EA = 1e6 (NOT the L1-3 value 1e3): the analytical reference is the
  ! INEXTENSIONAL elastica, so the rod must be axially stiff (T/EA ~ 5e-5 at
  ! alpha^2 = 1) or the ~4% axial stretch of a softer rod fails the gate by
  ! formulation bias. GAs/L^2/EI = 1e4 stays in the recommended Kirchhoff band.
  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e6_wp, GAS = 1.0e6_wp, EI = 1.0e2_wp, GJ = 1.0e2_wp
  REAL(wp), PARAMETER :: GATE = 1.0e-3_wp
  INTEGER, PARAMETER :: NE = 32
  INTEGER :: nfail
  nfail = 0

  ! alpha^2, x_tip/L, z_tip/L (elastica reference, reference-generated)
  CALL run_case(0.5_wp, 0.16214357565840026_wp, 0.984081037528981_wp)
  CALL run_case(1.0_wp, 0.30172077380023266_wp, 0.9435667637170584_wp)
  CALL run_case(2.0_wp, 0.4934574803964408_wp, 0.8393582791746794_wp)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran finite-EI cantilever matches the planar elastica (L1-4)'

CONTAINS

  SUBROUTINE run_case(alpha_sq, x_ref_norm, z_ref_norm)
    REAL(wp), INTENT(IN) :: alpha_sq, x_ref_norm, z_ref_norm
    INTEGER :: nn, ndof, i, conn(2, NE), fixed(6), es, n_iter, tip_x, tip_z
    REAL(wp) :: nodes_ref(3, NE + 1), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE)
    REAL(wp), ALLOCATABLE :: q0(:), f_ext(:), q(:)
    REAL(wp) :: p_load, s, err_x, err_z
    LOGICAL :: converged, stalled
    TYPE(CosseratSolverConfig) :: cfg
    CHARACTER(120) :: em

    nn = NE + 1; ndof = 6*nn
    ALLOCATE (q0(ndof), f_ext(ndof), q(ndof))
    p_load = alpha_sq*EI/L**2
    DO i = 1, nn
      nodes_ref(:, i) = [0.0_wp, 0.0_wp, REAL(i - 1, wp)*L/REAL(NE, wp)]
    END DO
    DO i = 1, NE
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
    END DO

    ! kinematic-linear-EB warm start: rotation about +y, positions integrated
    ! along the arc so the rod shortens in z (z(L) < L) rather than extending.
    q0 = 0.0_wp
    DO i = 1, nn
      s = REAL(i - 1, wp)*L/REAL(NE, wp)
      q0(6*i - 5) = arc_integral(p_load, s, .TRUE.)    ! x(s) = int_0^s sin theta
      q0(6*i - 3) = arc_integral(p_load, s, .FALSE.)   ! z(s) = int_0^s cos theta
      q0(6*i - 1) = theta_eb(p_load, s)                ! theta_y(s)
    END DO

    fixed = [1, 2, 3, 4, 5, 6]
    f_ext = 0.0_wp
    tip_x = 6*(nn - 1) + 1
    tip_z = 6*(nn - 1) + 3
    f_ext(tip_x) = p_load

    CALL CD_Static_Cosserat_Solve(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q0, f_ext, fixed, &
                                  .TRUE., cfg, q, converged, stalled, n_iter, es, em)
    CALL require(es == CD_COS_OK, 'solve-ErrStat')
    CALL require(converged, 'converged')

    err_x = ABS(q(tip_x) - x_ref_norm*L)/L           ! reference x = 0
    err_z = ABS(q(tip_z) - z_ref_norm*L)/L
    WRITE (*, '(A,F4.1,A,ES11.4,A,ES11.4,A,I0,A)') 'L1-4 alpha^2=', alpha_sq, &
      ': err_x=', err_x, '  err_z=', err_z, '  (', n_iter, ' iters)'
    CALL require(MAX(err_x, err_z) < GATE, 'L1-4:tip-position-vs-elastica')
    DEALLOCATE (q0, f_ext, q)
  END SUBROUTINE run_case

  PURE FUNCTION theta_eb(p_load, s) RESULT(th)
    !! linear-EB rotation field theta(s) = arctan(P s (2L - s) / (2 EI)).
    REAL(wp), INTENT(IN) :: p_load, s
    REAL(wp) :: th
    th = ATAN(p_load*s*(2.0_wp*L - s)/(2.0_wp*EI))
  END FUNCTION theta_eb

  PURE FUNCTION arc_integral(p_load, s, want_sin) RESULT(val)
    !! int_0^s f(theta_eb(sigma)) d sigma, f = sin (want_sin) or cos, by composite
    !! Simpson on a fine uniform grid (the integrand is smooth).
    REAL(wp), INTENT(IN) :: p_load, s
    LOGICAL, INTENT(IN) :: want_sin
    REAL(wp) :: val, h, sigma, acc
    INTEGER, PARAMETER :: M = 256                     ! even; >> enough for the warm start
    INTEGER :: k
    IF (s <= 0.0_wp) THEN
      val = 0.0_wp; RETURN
    END IF
    h = s/REAL(M, wp)
    acc = trig(theta_eb(p_load, 0.0_wp), want_sin) + trig(theta_eb(p_load, s), want_sin)
    DO k = 1, M - 1
      sigma = REAL(k, wp)*h
      IF (MOD(k, 2) == 1) THEN
        acc = acc + 4.0_wp*trig(theta_eb(p_load, sigma), want_sin)
      ELSE
        acc = acc + 2.0_wp*trig(theta_eb(p_load, sigma), want_sin)
      END IF
    END DO
    val = h/3.0_wp*acc
  END FUNCTION arc_integral

  PURE FUNCTION trig(th, want_sin) RESULT(r)
    REAL(wp), INTENT(IN) :: th
    LOGICAL, INTENT(IN) :: want_sin
    REAL(wp) :: r
    IF (want_sin) THEN
      r = SIN(th)
    ELSE
      r = COS(th)
    END IF
  END FUNCTION trig

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_large_deflection
