! File: tests/test_l1_bending_patch.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_bending_patch
  !! L1-2 pure-bending patch test, scored on the Fortran finite-EI Cosserat static
  !! solve. A single element clamped at node 1 with an end moment M about the
  !! element-local bending axis (global x) applied at node 2 produces a state of
  !! constant curvature; at equilibrium the Euler-Bernoulli relation
  !!   M = EI * kappa,   kappa = theta_2x / L0
  !! must hold to a tight tolerance, independently of the moment level. Checked at
  !! three moment levels (kappa = 5e-4, 1e-3, 2e-3) to a relative 1e-6 gate
  !! (VALIDATION_SPEC.md L1-2). Mirrors the L1-2 patch test.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratStatic, ONLY: CosseratSolverConfig, CD_Static_Cosserat_Solve, CD_COS_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L0 = 1.0_wp, EA = 1.0e3_wp, GAS = 1.0e6_wp, EI = 1.0e2_wp, GJ = 1.0e2_wp
  REAL(wp), PARAMETER :: GATE = 1.0e-6_wp
  INTEGER :: nfail
  nfail = 0

  CALL run_moment(0.05_wp)     ! kappa = 5e-4
  CALL run_moment(0.10_wp)     ! kappa = 1e-3
  CALL run_moment(0.20_wp)     ! kappa = 2e-3

  ! the static solver must reject PARTIAL rotational Dirichlet (1 or 2 of a
  ! node's 3 rotation DOFs fixed) -- the dexp-corrected compose is inconsistent
  ! there at finite rotation, so only full-clamp / full-free triplets are allowed
  CALL run_partial_dirichlet_rejection()
  ! an all-prescribed (n_free = 0) solve must still validate the mesh / element
  ! domain -- an out-of-chart fixed rotation cannot report a spurious "converged"
  CALL run_all_fixed_malformed_rejection()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran finite-EI pure-bending patch matches M = EI*kappa (L1-2)'

CONTAINS

  SUBROUTINE run_partial_dirichlet_rejection()
    !! Clamp node 1 fully but fix only theta_x of node 2 (a partial triplet) ->
    !! the solver must fail closed (ErrStat /= 0, not converged).
    INTEGER :: conn(2, 1), fixed(7), es, n_iter
    REAL(wp) :: nodes_ref(3, 2), ea_a(1), gas_a(1), ei_a(1), gj_a(1)
    REAL(wp) :: q0(12), f_ext(12), q(12)
    LOGICAL :: converged, stalled
    TYPE(CosseratSolverConfig) :: cfg
    CHARACTER(120) :: em
    nodes_ref(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]; nodes_ref(:, 2) = [0.0_wp, 0.0_wp, L0]
    conn(:, 1) = [1, 2]
    ea_a = EA; gas_a = GAS; ei_a = EI; gj_a = GJ
    q0 = 0.0_wp; q0(7:9) = nodes_ref(:, 2)
    fixed = [1, 2, 3, 4, 5, 6, 10]            ! node 1 full + only theta_2x (DOF 10)
    f_ext = 0.0_wp
    CALL CD_Static_Cosserat_Solve(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q0, f_ext, fixed, &
                                  .TRUE., cfg, q, converged, stalled, n_iter, es, em)
    CALL require(es /= 0 .AND. .NOT. converged, 'reject:partial-rotational-dirichlet')
  END SUBROUTINE run_partial_dirichlet_rejection

  SUBROUTINE run_all_fixed_malformed_rejection()
    !! Every DOF prescribed but node 2 carries an out-of-chart rotation
    !! (theta_2x > pi): the all-fixed shortcut must still validate the element
    !! domain and fail closed, not report a spurious converged solve.
    INTEGER :: conn(2, 1), fixed(12), es, n_iter, i
    REAL(wp) :: nodes_ref(3, 2), ea_a(1), gas_a(1), ei_a(1), gj_a(1)
    REAL(wp) :: q0(12), f_ext(12), q(12)
    LOGICAL :: converged, stalled
    TYPE(CosseratSolverConfig) :: cfg
    CHARACTER(120) :: em
    nodes_ref(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]; nodes_ref(:, 2) = [0.0_wp, 0.0_wp, L0]
    conn(:, 1) = [1, 2]
    ea_a = EA; gas_a = GAS; ei_a = EI; gj_a = GJ
    q0 = 0.0_wp; q0(7:9) = nodes_ref(:, 2); q0(10) = 3.5_wp     ! node-2 theta_x > pi
    fixed = [(i, i=1, 12)]                                      ! every DOF prescribed
    f_ext = 0.0_wp
    CALL CD_Static_Cosserat_Solve(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q0, f_ext, fixed, &
                                  .TRUE., cfg, q, converged, stalled, n_iter, es, em)
    CALL require(es /= 0 .AND. .NOT. converged, 'reject:all-fixed-malformed-input')
  END SUBROUTINE run_all_fixed_malformed_rejection

  SUBROUTINE run_moment(moment)
    REAL(wp), INTENT(IN) :: moment
    INTEGER :: conn(2, 1), fixed(6), es, n_iter
    REAL(wp) :: nodes_ref(3, 2), ea_a(1), gas_a(1), ei_a(1), gj_a(1)
    REAL(wp) :: q0(12), f_ext(12), q(12), kappa, kappa_expected, rel
    LOGICAL :: converged, stalled
    TYPE(CosseratSolverConfig) :: cfg
    CHARACTER(120) :: em

    nodes_ref(:, 1) = [0.0_wp, 0.0_wp, 0.0_wp]
    nodes_ref(:, 2) = [0.0_wp, 0.0_wp, L0]
    conn(:, 1) = [1, 2]
    ea_a = EA; gas_a = GAS; ei_a = EI; gj_a = GJ
    q0 = 0.0_wp
    q0(1:3) = nodes_ref(:, 1)
    q0(7:9) = nodes_ref(:, 2)
    ! clamp node 1 (all 6 DOFs); apply moment about x at node 2 (theta_2x = DOF 10)
    fixed = [1, 2, 3, 4, 5, 6]
    f_ext = 0.0_wp
    f_ext(10) = moment

    CALL CD_Static_Cosserat_Solve(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, q0, f_ext, fixed, &
                                  .TRUE., cfg, q, converged, stalled, n_iter, es, em)
    CALL require(es == CD_COS_OK, 'solve-ErrStat')
    CALL require(converged, 'converged')

    kappa = q(10)/L0                       ! theta_2x / L0
    kappa_expected = moment/EI
    rel = ABS(kappa - kappa_expected)/ABS(kappa_expected)
    WRITE (*, '(A,ES10.3,A,ES13.6,A,ES13.6,A,ES11.4)') 'L1-2 M=', moment, &
      ': kappa = ', kappa, '  M/EI = ', kappa_expected, '  rel = ', rel
    CALL require(rel < GATE, 'L1-2:kappa-eq-M-over-EI')
  END SUBROUTINE run_moment

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_bending_patch
