! File: tests/test_l1_cantilever.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_cantilever
  !! L1-3 linear cantilever, scored on the Fortran finite-EI Cosserat static solve
  !! against the closed-form Euler-Bernoulli tip deflection. A straight rod of
  !! length L along +z, clamped at node 1 (all 6 DOFs) and loaded transversely (+x)
  !! at the free tip with a small force P (linear regime), has tip deflection
  !!   w_tip = P L^3 / (3 EI).
  !! Solved with CD_Static_Cosserat_Solve at n_elem in {16, 32}; the relative error
  !! must be < 1e-3 (VALIDATION_SPEC.md L1-3). Mirrors the L1-3
  !! benchmark: EI=1e2, EA=1e3, GAs=1e6, GJ=1e2,
  !! L=1, P=0.1.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratStatic, ONLY: CosseratSolverConfig, CD_Static_Cosserat_Solve, CD_COS_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e3_wp, GAS = 1.0e6_wp, EI = 1.0e2_wp, GJ = 1.0e2_wp
  REAL(wp), PARAMETER :: P = 0.1_wp, GATE = 1.0e-3_wp
  INTEGER :: nfail
  nfail = 0

  CALL run_cantilever(16)
  CALL run_cantilever(32)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran finite-EI cantilever matches Euler-Bernoulli (L1-3)'

CONTAINS

  SUBROUTINE run_cantilever(ne)
    INTEGER, INTENT(IN) :: ne
    INTEGER :: nn, ndof, i, conn(2, ne), fixed(6), es, n_iter, tip_x
    REAL(wp) :: nodes_ref(3, ne + 1), ea_a(ne), gas_a(ne), ei_a(ne), gj_a(ne)
    REAL(wp), ALLOCATABLE :: q0(:), f_ext(:), q(:)
    REAL(wp) :: w_eb, w_tip, rel
    LOGICAL :: converged, stalled
    TYPE(CosseratSolverConfig) :: cfg
    CHARACTER(120) :: em

    nn = ne + 1
    ndof = 6*nn
    ALLOCATE (q0(ndof), f_ext(ndof), q(ndof))
    ! straight rod along +z
    DO i = 1, nn
      nodes_ref(:, i) = [0.0_wp, 0.0_wp, REAL(i - 1, wp)*L/REAL(ne, wp)]
    END DO
    DO i = 1, ne
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
    END DO
    ! reference DOF vector: positions = nodes_ref, rotations = 0
    q0 = 0.0_wp
    DO i = 1, nn
      q0(6*i - 5:6*i - 3) = nodes_ref(:, i)
    END DO
    ! clamp node 1 (all 6 DOFs); transverse +x tip load
    fixed = [1, 2, 3, 4, 5, 6]
    f_ext = 0.0_wp
    tip_x = 6*(nn - 1) + 1
    f_ext(tip_x) = P

    CALL CD_Static_Cosserat_Solve(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q0, f_ext, fixed, &
                                  .TRUE., cfg, q, converged, stalled, n_iter, es, em)
    CALL require(es == CD_COS_OK, 'solve-ErrStat')
    CALL require(converged, 'converged')

    w_eb = P*L**3/(3.0_wp*EI)
    w_tip = q(tip_x)                       ! reference x = 0, so w_tip = q(tip_x)
    rel = ABS(w_tip - w_eb)/ABS(w_eb)
    WRITE (*, '(A,I2,A,ES13.6,A,ES13.6,A,ES11.4,A,I0,A)') 'L1-3 ne=', ne, &
      ': w_tip = ', w_tip, '  EB = ', w_eb, '  rel = ', rel, '  (', n_iter, ' iters)'
    CALL require(rel < GATE, 'L1-3:tip-deflection-vs-EB')
    DEALLOCATE (q0, f_ext, q)
  END SUBROUTINE run_cantilever

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_cantilever
