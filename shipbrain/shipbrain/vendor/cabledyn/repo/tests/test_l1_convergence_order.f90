! File: tests/test_l1_convergence_order.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_convergence_order
  !! L1-10 convergence order, scored on the Fortran finite-EI static solve. The
  !! linear cantilever (same model as L1-3) resolves a cubic-displacement mode;
  !! the linear-Lagrange Cosserat element is nodally super-convergent (O(h^4) tip
  !! deflection as h -> 0). Solving at n_elem in {4, 8, 16, 32} and measuring the
  !! per-interval observed order of the tip-deflection error vs Euler-Bernoulli,
  !! the FINEST-interval order (16 -> 32) must be >= 3.5 (VALIDATION_SPEC.md L1-10;
  !! the global log-log fit is dragged down by the pre-asymptotic coarse end, so
  !! the gate is the asymptotic interval). Mirrors the L1-10 benchmark.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratStatic, ONLY: CosseratSolverConfig, CD_Static_Cosserat_Solve, CD_COS_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e3_wp, GAS = 1.0e6_wp, EI = 1.0e2_wp, GJ = 1.0e2_wp
  REAL(wp), PARAMETER :: P = 0.1_wp, GATE = 3.5_wp
  INTEGER, PARAMETER :: NMESH = 4, MESHES(NMESH) = [4, 8, 16, 32]
  INTEGER :: nfail, i
  REAL(wp) :: w_eb, err(NMESH), h(NMESH), order_asymp
  nfail = 0

  w_eb = P*L**3/(3.0_wp*EI)
  DO i = 1, NMESH
    err(i) = ABS(tip_deflection(MESHES(i)) - w_eb)
    h(i) = L/REAL(MESHES(i), wp)
  END DO
  ! finest-interval observed order: log(err_{n-1}/err_n) / log(h_{n-1}/h_n)
  order_asymp = LOG(err(NMESH - 1)/err(NMESH))/LOG(h(NMESH - 1)/h(NMESH))

  WRITE (*, '(A)') 'L1-10 per-mesh tip-deflection error vs Euler-Bernoulli:'
  DO i = 1, NMESH
    WRITE (*, '(A,I3,A,ES12.4,A,ES12.4)') '  n_elem=', MESHES(i), '  h=', h(i), '  err=', err(i)
  END DO
  WRITE (*, '(A,F8.4,A,F4.1,A)') 'L1-10 asymptotic (16->32) order = ', order_asymp, &
    '  (gate >= ', GATE, ')'
  CALL require(order_asymp >= GATE, 'L1-10:asymptotic-convergence-order')
  ! errors must be monotone decreasing under refinement (sanity)
  CALL require(err(2) < err(1) .AND. err(3) < err(2) .AND. err(4) < err(3), 'L1-10:errors-decrease')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran finite-EI cantilever is nodally super-convergent (L1-10)'

CONTAINS

  FUNCTION tip_deflection(ne) RESULT(w_tip)
    INTEGER, INTENT(IN) :: ne
    REAL(wp) :: w_tip
    INTEGER :: nn, ndof, i, conn(2, ne), fixed(6), es, n_iter, tip_x
    REAL(wp) :: nodes_ref(3, ne + 1), ea_a(ne), gas_a(ne), ei_a(ne), gj_a(ne)
    REAL(wp), ALLOCATABLE :: q0(:), f_ext(:), q(:)
    LOGICAL :: converged, stalled
    TYPE(CosseratSolverConfig) :: cfg
    CHARACTER(120) :: em
    nn = ne + 1; ndof = 6*nn
    ALLOCATE (q0(ndof), f_ext(ndof), q(ndof))
    DO i = 1, nn
      nodes_ref(:, i) = [0.0_wp, 0.0_wp, REAL(i - 1, wp)*L/REAL(ne, wp)]
    END DO
    DO i = 1, ne
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
    END DO
    q0 = 0.0_wp
    DO i = 1, nn
      q0(6*i - 5:6*i - 3) = nodes_ref(:, i)
    END DO
    fixed = [1, 2, 3, 4, 5, 6]
    f_ext = 0.0_wp
    tip_x = 6*(nn - 1) + 1
    f_ext(tip_x) = P
    CALL CD_Static_Cosserat_Solve(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q0, f_ext, fixed, &
                                  .TRUE., cfg, q, converged, stalled, n_iter, es, em)
    CALL require(es == CD_COS_OK .AND. converged, 'L1-10:solve-converged')
    w_tip = q(tip_x)
    DEALLOCATE (q0, f_ext, q)
  END FUNCTION tip_deflection

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_convergence_order
