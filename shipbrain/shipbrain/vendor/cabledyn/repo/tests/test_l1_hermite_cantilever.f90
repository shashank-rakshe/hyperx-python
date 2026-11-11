! File: tests/test_l1_hermite_cantilever.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_hermite_cantilever
  !! L1-3 linear cantilever on the PRODUCTION cubic-Hermite bending-cable path. A horizontal
  !! cantilever (clamped root: r AND m fixed at node 1 -- the C1 clamp), loaded through the static
  !! solver's generalized nodal-load vector, against the Euler-Bernoulli closed forms:
  !!
  !! (a) tip POINT LOAD P on the r_z slot: tip deflection vs P L^3 / 3 EI. The point-load solution
  !!     is a CUBIC in x, which the element contains exactly, so the error is the small
  !!     geometric-nonlinearity residual O((w')^2) plus the solver tolerance.
  !! (b) tip MOMENT M0 on the m_z slot (the moment-like load conjugate to the material tangent):
  !!     tip deflection vs M0 L^2 / 2 EI and tip slope (m_z) vs M0 L / EI -- a QUADRATIC the cubic
  !!     also contains exactly. Run on a deliberately COARSE long-element mesh (2 elements of
  !!     L/2), this doubles as the regression for the moment entry of the convergence force
  !!     scale: a raw N.m magnitude folded in as a force would loosen the tangent-residual
  !!     verdict by the tributary length on long elements.
  !!
  !! Both gated at 1e-3 relative. The distributed-load cantilever
  !! (w L^4 / 8 EI, a quartic the cubic cannot contain exactly) is the L1-10 convergence gate.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e6_wp, EI = 100.0_wp, P = 0.1_wp
  ! M0 keeps the tip slope M0 L / EI at 0.01 so the geometric-nonlinearity remainder
  ! O((w')^2) ~ 1e-4 stays under the 1e-3 gate (the quadratic itself is exact in the cubic).
  REAL(wp), PARAMETER :: M0 = 1.0_wp
  INTEGER, PARAMETER :: NE = 16
  REAL(wp), PARAMETER :: GATE = 1.0e-3_wp

  REAL(wp) :: w_eb, w_tip, s_tip, relerr, sl_err
  INTEGER :: nfail

  nfail = 0
  w_eb = P*L**3/(3.0_wp*EI)
  CALL solve_tip_load(NE, w_tip)
  relerr = ABS(w_tip - w_eb)/w_eb
  WRITE (*, '(A,ES12.5,A,ES12.5,A,ES10.3)') 'L1-3a tip deflection = ', w_tip, '   P L^3/3EI = ', w_eb, &
    '   rel err = ', relerr
  CALL require(relerr < GATE, 'tip deflection within 1e-3 of P L^3 / 3 EI')

  ! tip moment on a coarse 2-element mesh (long elements exercise the moment force-scale entry)
  CALL solve_tip_moment(2, w_tip, s_tip)
  w_eb = M0*L**2/(2.0_wp*EI)
  relerr = ABS(w_tip - w_eb)/w_eb
  sl_err = ABS(s_tip - M0*L/EI)/(M0*L/EI)
  WRITE (*, '(A,ES12.5,A,ES12.5,A,ES10.3,A,ES10.3)') 'L1-3b tip deflection = ', w_tip, &
    '   M0 L^2/2EI = ', w_eb, '   rel err = ', relerr, '   slope rel err = ', sl_err
  CALL require(relerr < GATE, 'tip-moment deflection within 1e-3 of M0 L^2 / 2 EI')
  CALL require(sl_err < GATE, 'tip-moment slope within 1e-3 of M0 L / EI')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L1-3 linear cantilever (tip force + tip moment) on the cubic-Hermite path'

CONTAINS

  SUBROUTINE solve_tip_load(ne, wtip)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(OUT) :: wtip
    INTEGER :: nn, i, k, es, iters
    REAL(wp) :: le, res
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), wv(:), seed(:), q(:), curv(:), fnod(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    CHARACTER(300) :: em
    nn = ne + 1
    le = L/REAL(ne, wp)
    ALLOCATE (l0(ne), EAv(ne), EIv(ne), wv(ne), seed(6*nn), q(6*nn), curv(nn), fnod(6*nn))
    l0 = le; EAv = EA; EIv = EI; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)*le    ! r_x along the axis
      seed(6*(i - 1) + 4) = 1.0_wp                ! m_x unit tangent
    END DO
    fnod = 0.0_wp
    fnod(6*(nn - 1) + 3) = P                      ! tip point load, +z
    ! clamp the root (r1 + m1), planar x-z (r_y, m_y everywhere); tip free
    ALLOCATE (fixed(6 + 2*(nn - 1)))
    fixed(1:6) = [1, 2, 3, 4, 5, 6]
    k = 6
    DO i = 2, nn
      fixed(k + 1) = 6*(i - 1) + 2; fixed(k + 2) = 6*(i - 1) + 5; k = k + 2
    END DO
    ! tol is RELATIVE to the solver's force scale, which floors at 1 N for this feather-light
    ! load (P = 0.1 N): 1e-8 * 1 N is still 1e-7 of P, far inside the gate. Newton's terminal
    ! residual on this near-linear problem sits orders below the exit tolerance anyway.
    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                      1, 60, 1.0e-8_wp, 1.0_wp, q, curv, res, iters, es, em, &
                                      f_nodal=fnod)
    CALL require(es == CD_HCSTAT_OK, 'cantilever solve converged: '//TRIM(em))
    wtip = q(6*(nn - 1) + 3)
  END SUBROUTINE solve_tip_load

  SUBROUTINE solve_tip_moment(ne, wtip, stip)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(OUT) :: wtip, stip
    INTEGER :: nn, i, k, es, iters
    REAL(wp) :: le, res
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), wv(:), seed(:), q(:), curv(:), fnod(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    CHARACTER(300) :: em
    nn = ne + 1
    le = L/REAL(ne, wp)
    ALLOCATE (l0(ne), EAv(ne), EIv(ne), wv(ne), seed(6*nn), q(6*nn), curv(nn), fnod(6*nn))
    l0 = le; EAv = EA; EIv = EI; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)*le
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    fnod = 0.0_wp
    fnod(6*(nn - 1) + 6) = M0                     ! tip bending moment via the m_z slot
    ALLOCATE (fixed(6 + 2*(nn - 1)))
    fixed(1:6) = [1, 2, 3, 4, 5, 6]
    k = 6
    DO i = 2, nn
      fixed(k + 1) = 6*(i - 1) + 2; fixed(k + 2) = 6*(i - 1) + 5; k = k + 2
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                      1, 60, 1.0e-8_wp, 1.0_wp, q, curv, res, iters, es, em, &
                                      f_nodal=fnod)
    CALL require(es == CD_HCSTAT_OK, 'tip-moment solve converged: '//TRIM(em))
    wtip = q(6*(nn - 1) + 3)
    stip = q(6*nn)                                 ! m_z at the tip ~ dz/ds
  END SUBROUTINE solve_tip_moment

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_hermite_cantilever
