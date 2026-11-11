! File: tests/test_l1_hermite_convergence.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_hermite_convergence
  !! L1-10 solve-level convergence order of the PRODUCTION cubic-Hermite bending-cable path.
  !!
  !! Case: a horizontal cantilever under uniform self-weight w, whose Euler-Bernoulli solution
  !! z(x) = -(w/24EI) x^2 (x^2 - 4Lx + 6L^2) is a QUARTIC -- the lowest-order field the cubic
  !! element cannot contain exactly (a tip POINT load is a cubic the element reproduces to
  !! round-off at any mesh, so it cannot carry an order measurement).
  !!
  !! Where the order is measured: for the linearised beam operator with the element's exact
  !! consistent load vector [w l0/2 on r_z, +/- w l0^2/12 on m_z], the cubic-Hermite solution is
  !! NODALLY EXACT (its Green's function is piecewise cubic with a node at the load point), so
  !! nodal values carry no mesh signal either. The discretisation error lives in the INTERIOR:
  !! the per-element field is the cubic Hermite interpolant of the quartic, with midpoint error
  !! e_mid = w h^4 / (384 EI) per element -- an analytic O(h^4) sequence. The gate samples the
  !! solved field at every element midpoint via the Hermite shape functions, normalises the max
  !! error by the tip deflection wL^4/8EI, and requires the observed finest-interval order >= 3.5
  !! (theory: 4.0; expected errors (h/L)^4/48 = 8.1e-5, 5.1e-6, 3.2e-7, 2.0e-8 at ne = 4..32).
  !! The load is feather-light (tip deflection 1e-5 L) so the geometric-nonlinearity remainder
  !! O((w')^2) ~ 2e-10 relative stays an order below the finest-mesh signal.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e6_wp, EI = 1.0e2_wp
  REAL(wp), PARAMETER :: WLOAD = 8.0e-3_wp          ! tip deflection wL^4/8EI = 1e-5 L
  INTEGER, PARAMETER :: NMESH = 4, MESHES(NMESH) = [4, 8, 16, 32]
  REAL(wp) :: errs(NMESH), hs(NMESH), order_fin, w_tip_ref
  INTEGER :: im, nfail

  nfail = 0
  w_tip_ref = WLOAD*L**4/(8.0_wp*EI)

  DO im = 1, NMESH
    CALL midpoint_error(MESHES(im), errs(im))
    hs(im) = L/REAL(MESHES(im), wp)
  END DO

  WRITE (*, '(A)') 'L1-10 interior (element-midpoint) deflection error vs the EB quartic, / (wL^4/8EI):'
  DO im = 1, NMESH
    WRITE (*, '(A,I3,A,ES11.4)') '   ne = ', MESHES(im), '   err = ', errs(im)
  END DO
  order_fin = LOG(errs(NMESH - 1)/errs(NMESH))/LOG(hs(NMESH - 1)/hs(NMESH))
  WRITE (*, '(A,F6.2)') 'L1-10 finest-interval observed order = ', order_fin

  DO im = 2, NMESH
    CALL require(errs(im) < errs(im - 1), 'midpoint error decreases monotonically under refinement')
  END DO
  CALL require(errs(NMESH) < 1.0e-7_wp, 'finest-mesh interior error < 1e-7 relative')
  CALL require(order_fin >= 3.5_wp, 'finest-interval convergence order >= 3.5')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L1-10 cubic-Hermite solve converges at fourth order on the EB quartic'

CONTAINS

  SUBROUTINE midpoint_error(ne, err)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(OUT) :: err
    INTEGER :: nn, i, k, e, es, iters
    REAL(wp) :: le, res, s_mid, z_h, z_ex
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), wv(:), seed(:), q(:), curv(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    CHARACTER(300) :: em
    nn = ne + 1
    le = L/REAL(ne, wp)
    ALLOCATE (l0(ne), EAv(ne), EIv(ne), wv(ne), seed(6*nn), q(6*nn), curv(nn))
    l0 = le; EAv = EA; EIv = EI; wv = WLOAD
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)*le    ! r_x along the axis
      seed(6*(i - 1) + 4) = 1.0_wp                ! m_x unit tangent
    END DO
    ! clamp the root (r1 + m1); planar x-z (r_y, m_y everywhere); tip free (m_x stays free)
    ALLOCATE (fixed(6 + 2*(nn - 1)))
    fixed(1:6) = [1, 2, 3, 4, 5, 6]
    k = 6
    DO i = 2, nn
      fixed(k + 1) = 6*(i - 1) + 2; fixed(k + 2) = 6*(i - 1) + 5; k = k + 2
    END DO
    ! tol is relative to the solver's force scale (floored at 1 N >> the 8e-3 N total load);
    ! the first full Newton step lands on the linearised solution with residual at the
    ! nonlinear remainder ~1e-12, well under this exit tolerance.
    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                      1, 30, 1.0e-8_wp, 1.0_wp, q, curv, res, iters, es, em)
    CALL require(es == CD_HCSTAT_OK, 'cantilever solve converged: '//TRIM(em))
    ! Element-midpoint deflection from the Hermite shape functions at xi = 1/2:
    ! z(mid) = (z1 + z2)/2 + le (mz1 - mz2)/8; weight acts -z, so z_exact < 0.
    err = 0.0_wp
    DO e = 1, ne
      z_h = 0.5_wp*(q(6*(e - 1) + 3) + q(6*e + 3)) + le*(q(6*(e - 1) + 6) - q(6*e + 6))/8.0_wp
      s_mid = (REAL(e, wp) - 0.5_wp)*le
      z_ex = -(WLOAD/(24.0_wp*EI))*s_mid**2*(s_mid**2 - 4.0_wp*L*s_mid + 6.0_wp*L**2)
      err = MAX(err, ABS(z_h - z_ex))
    END DO
    err = err/w_tip_ref
  END SUBROUTINE midpoint_error

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_hermite_convergence
