! File: tests/test_cable_static.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cable_static
  !! Unit tests for CableDyn_Static (Newton + Armijo + DGBSV), cross-validated
  !! against an independent static solution.
  !! The headline case is a pre-stretched (taut) bar sagging
  !! under gravity between two fixed ends; the converged state is compared to the
  !! independent reference solution. f_ext (the consistent gravity load) is built with the already-
  !! validated CD_Assemble_Distributed_Load, so both solvers see the same load.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Loads, ONLY: CD_Assemble_Distributed_Load, CD_Seabed_Penalty_Load
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Init_Bathymetry, CD_End_Bathymetry, CD_BATHY_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve, &
                             CD_Static_Cable_Solve_Continuation, &
                             CD_STATIC_OK, CD_STATIC_BADINPUT, CD_STATIC_SINGULAR
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  INTEGER :: nfail
  nfail = 0

  CALL case_catenary_reference()
  CALL case_all_fixed_trivial()
  CALL case_singular_tangent()
  CALL case_bad_input()
  CALL case_fully_grounded()
  CALL case_partial_grounded()
  CALL case_bathymetry_seabed_route()
  CALL case_seabed_fail_closed()
  CALL case_continuation_matches_reference()
  CALL case_continuation_heavy_nonlinear()
  CALL case_continuation_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Static matches the independent reference values'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE expect(got, want, label)
    REAL(wp), INTENT(IN) :: got, want
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 1.0e-8_wp, rtol = 1.0e-9_wp
    IF (.NOT. (ABS(got - want) <= atol + rtol*ABS(want))) THEN
      WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect

  SUBROUTINE expect_es(es, want, label)
    INTEGER, INTENT(IN) :: es, want
    CHARACTER(*), INTENT(IN) :: label
    IF (es /= want) THEN
      WRITE (*, '(A,A,A,I0,A,I0)') 'MISMATCH [', label, ']: ErrStat ', es, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect_es

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE five_node_bar(conn, l0, ea, q0)
    !! span-4 line along x, 4 elements, 10% pre-stretch (L0 = 0.9) -> taut.
    INTEGER, INTENT(OUT) :: conn(2, 4)
    REAL(wp), INTENT(OUT) :: l0(4), ea(4), q0(15)
    INTEGER :: i
    conn = RESHAPE([1, 2, 2, 3, 3, 4, 4, 5], [2, 4])
    l0 = [0.9_wp, 0.9_wp, 0.9_wp, 0.9_wp]
    ea = [1000.0_wp, 1000.0_wp, 1000.0_wp, 1000.0_wp]
    q0 = 0.0_wp
    DO i = 1, 5
      q0(3*i - 2) = REAL(i - 1, wp)   ! x = 0,1,2,3,4 ; y = z = 0
    END DO
  END SUBROUTINE five_node_bar

  SUBROUTINE case_catenary_reference()
    !! Pre-stretched bar sagging under gravity; converged q vs the reference.
    INTEGER  :: conn(2, 4), fixed(6), es, n_iter, i
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15), load(3, 4)
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: want_q(15) = [ &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           0.96792055637890251_wp, 0.0_wp, -0.4164534696057578_wp, &
                           2.0_wp, 0.0_wp, -0.5644728713952184_wp, &
                           3.0320794436210976_wp, 0.0_wp, -0.41645346960575774_wp, &
                           4.0_wp, 0.0_wp, 0.0_wp]
    CALL five_node_bar(conn, l0, ea, q0)
    ! f_ext = consistent gravity (w = 50 N/m downward), built like the reference
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 4)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL expect_es(es, CD_STATIC_OK, 'reference:fext-ErrStat')
    fixed = [1, 2, 3, 13, 14, 15]      ! both endpoints (nodes 1 and 5)
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em)
    CALL expect_es(es, CD_STATIC_OK, 'reference:solve-ErrStat')
    CALL require(converged, 'reference:converged')
    CALL require(.NOT. stalled, 'reference:not-stalled')
    CALL require(n_iter >= 1 .AND. n_iter <= 50, 'reference:iters-sane')
    DO i = 1, 15
      CALL expect(q(i), want_q(i), 'reference:q')
    END DO
  END SUBROUTINE case_catenary_reference

  SUBROUTINE case_continuation_matches_reference()
    !! Load continuation reaches the SAME reference catenary equilibrium as the
    !! single-shot solve -- it changes the path to the fixed point, not the answer.
    INTEGER  :: conn(2, 4), fixed(6), es, n_iter_total, n_stages, i
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15), load(3, 4)
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: factors(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
    REAL(wp), PARAMETER :: want_q(15) = [ &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           0.96792055637890251_wp, 0.0_wp, -0.4164534696057578_wp, &
                           2.0_wp, 0.0_wp, -0.5644728713952184_wp, &
                           3.0320794436210976_wp, 0.0_wp, -0.41645346960575774_wp, &
                           4.0_wp, 0.0_wp, 0.0_wp]
    CALL five_node_bar(conn, l0, ea, q0)
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 4)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL expect_es(es, CD_STATIC_OK, 'cont:fext-ErrStat')
    fixed = [1, 2, 3, 13, 14, 15]
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, factors, &
                                            q, converged, stalled, at_floor, n_iter_total, n_stages, es, em)
    CALL expect_es(es, CD_STATIC_OK, 'cont:solve-ErrStat')
    CALL require(converged .AND. .NOT. stalled, 'cont:converged')
    CALL require(n_stages == 4, 'cont:all-stages-done')
    CALL require(n_iter_total >= 1, 'cont:iters-sane')
    DO i = 1, 15
      CALL expect(q(i), want_q(i), 'cont:q-vs-reference')
    END DO
  END SUBROUTINE case_continuation_matches_reference

  SUBROUTINE case_continuation_heavy_nonlinear()
    !! Continuation under a strongly nonlinear heavy load (40x the reference load):
    !! it converges to a true (converged => residual < tol) symmetric sag, and where
    !! the single-shot solve also converges the two agree to the solver tolerance --
    !! continuation changes the path to the fixed point, never the fixed point.
    !! (On this TAUT bar the Armijo single-shot is itself robust; continuation's
    !! convergence GAIN is exercised in the slack/grounded regime that the catenary
    !! seed unlocks, not here -- so we do not assert the single-shot stalls.)
    INTEGER  :: conn(2, 4), fixed(6), es, n_iter, n_iter_total, n_stages, i
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q_ss(15), q_co(15), load(3, 4)
    LOGICAL  :: ss_conv, ss_stall, ss_floor, co_conv, co_stall, co_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: factors(6) = [0.05_wp, 0.1_wp, 0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
    CALL five_node_bar(conn, l0, ea, q0)
    load = SPREAD([0.0_wp, 0.0_wp, -2.0e3_wp], 2, 4)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    fixed = [1, 2, 3, 13, 14, 15]
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q_ss, ss_conv, ss_stall, ss_floor, n_iter, es, em)
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, factors, &
                                            q_co, co_conv, co_stall, co_floor, n_iter_total, n_stages, es, em)
    CALL expect_es(es, CD_STATIC_OK, 'heavy:cont-ErrStat')
    CALL require(co_conv .AND. .NOT. co_stall .AND. n_stages == 6, 'heavy:continuation-converges')
    ! a true, physical equilibrium: sags below the chord, symmetric about node 3
    CALL require(q_co(6) < 0.0_wp .AND. q_co(9) < 0.0_wp .AND. q_co(12) < 0.0_wp, 'heavy:sags')
    CALL require(ABS(q_co(6) - q_co(12)) < 1.0e-6_wp, 'heavy:symmetric-z')
    CALL require(ABS((q_co(4) + q_co(10)) - 4.0_wp) < 1.0e-6_wp, 'heavy:symmetric-x')
    CALL require(q_co(9) < q_co(6), 'heavy:deepest-at-mid')
    ! where single-shot also reaches the fixed point, continuation must agree with it
    IF (ss_conv) THEN
      DO i = 1, 15
        CALL expect(q_co(i), q_ss(i), 'heavy:continuation-equals-single-shot')
      END DO
    END IF
  END SUBROUTINE case_continuation_heavy_nonlinear

  SUBROUTINE case_continuation_fail_closed()
    !! The continuation schedule must be a strictly increasing ramp in (0, 1]
    !! ending at 1; reject every malformed schedule.
    INTEGER  :: conn(2, 4), fixed(6), es, n_iter_total, n_stages
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15)
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    CALL five_node_bar(conn, l0, ea, q0)
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 13, 14, 15]
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                                            [REAL(wp) ::], q, converged, stalled, at_floor, &
                                            n_iter_total, n_stages, es, em)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'cont-fail:empty-schedule')
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                                            [0.5_wp, 0.25_wp, 1.0_wp], q, converged, stalled, &
                                            at_floor, n_iter_total, n_stages, es, em)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'cont-fail:non-increasing')
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                                            [0.25_wp, 0.5_wp, 0.75_wp], q, converged, stalled, &
                                            at_floor, n_iter_total, n_stages, es, em)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'cont-fail:not-ending-at-one')
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                                            [-0.5_wp, 1.0_wp], q, converged, stalled, &
                                            at_floor, n_iter_total, n_stages, es, em)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'cont-fail:non-positive')
    ! An incomplete seabed pair (seabed_z_floor without seabed_kn) must still be rejected: the
    ! seabed-stiffness ramp forwards seabed_z_floor at every stage so the inner solve fail-closes.
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                                            [1.0_wp], q, converged, stalled, &
                                            at_floor, n_iter_total, n_stages, es, em, seabed_z_floor=0.0_wp)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'cont-fail:seabed-floor-without-kn')
  END SUBROUTINE case_continuation_fail_closed

  SUBROUTINE case_all_fixed_trivial()
    !! Every DOF prescribed -> q0 is the (trivially converged) solution.
    INTEGER  :: conn(2, 4), fixed(15), es, n_iter, i
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15)
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    CALL five_node_bar(conn, l0, ea, q0)
    f_ext = 0.0_wp
    fixed = [(i, i=1, 15)]
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em)
    CALL expect_es(es, CD_STATIC_OK, 'allfixed:ErrStat')
    CALL require(converged, 'allfixed:converged')
    DO i = 1, 15
      CALL expect(q(i), q0(i), 'allfixed:q-equals-q0')
    END DO
  END SUBROUTINE case_all_fixed_trivial

  SUBROUTINE case_singular_tangent()
    !! A straight, zero-pre-stretch line (L0 = span) under gravity has zero tension,
    !! so the transverse tangent is singular at the seed -> DGBSV fails closed.
    INTEGER  :: conn(2, 4), fixed(6), es, n_iter
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15), load(3, 4)
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    CALL five_node_bar(conn, l0, ea, q0)
    l0 = [1.0_wp, 1.0_wp, 1.0_wp, 1.0_wp]   ! L0 = element span -> zero strain at the seed
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 4)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    fixed = [1, 2, 3, 13, 14, 15]
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em)
    CALL expect_es(es, CD_STATIC_SINGULAR, 'singular:ErrStat')
    CALL require(.NOT. converged, 'singular:not-converged')
  END SUBROUTINE case_singular_tangent

  SUBROUTINE case_bad_input()
    !! Out-of-range fixed DOF and an invalid config both fail closed.
    INTEGER  :: conn(2, 4), es, n_iter
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15)
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg, bad
    CHARACTER(120) :: em
    CALL five_node_bar(conn, l0, ea, q0)
    f_ext = 0.0_wp
    ! fixed DOF 99 is out of range for a 15-DOF mesh
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 99], cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'badinput:fixed-range')
    ! invalid config: max_iter = 0
    bad = cfg
    bad%max_iter = 0
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 13, 14, 15], bad, &
                               q, converged, stalled, at_floor, n_iter, es, em)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'badinput:config-maxiter')
    ! invalid config: non-positive Armijo constant (would relax sufficient-decrease)
    bad = cfg
    bad%armijo_c1 = -1.0_wp
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 13, 14, 15], bad, &
                               q, converged, stalled, at_floor, n_iter, es, em)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'badinput:armijo-negative')
    ! invalid config: NaN Armijo constant
    bad = cfg
    bad%armijo_c1 = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 13, 14, 15], bad, &
                               q, converged, stalled, at_floor, n_iter, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'badinput:armijo-nan')
    ! invalid config: non-positive stall_rel_tol
    bad = cfg
    bad%stall_rel_tol = 0.0_wp
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 13, 14, 15], bad, &
                               q, converged, stalled, at_floor, n_iter, es, em)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'badinput:stall-rel-tol')
  END SUBROUTINE case_bad_input

  SUBROUTINE case_fully_grounded()
    !! A flat heavy line resting on the seabed (ends pinned in x,y only; all z free,
    !! held up by contact). The total seabed reaction balances the total weight,
    !! and the converged shape matches the reference.
    INTEGER  :: conn(2, 4), fixed(4), es, n_iter, i
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15), load(3, 4), kn(5)
    REAL(wp) :: seabed_f(15), seabed_kr(15, 15), reaction
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: want_q(15) = [ &
                           0.0_wp, 0.0_wp, -0.0002252494460135768_wp, &
                           0.99999998865981787_wp, 0.0_wp, -0.00044975083022788385_wp, &
                           2.0_wp, 0.0_wp, -0.00044999944751707876_wp, &
                           3.0000000113401821_wp, 0.0_wp, -0.00044975083022788385_wp, &
                           4.0_wp, 0.0_wp, -0.0002252494460135768_wp]
    conn = RESHAPE([1, 2, 2, 3, 3, 4, 4, 5], [2, 4])
    l0 = [0.9_wp, 0.9_wp, 0.9_wp, 0.9_wp]
    ea = [1000.0_wp, 1000.0_wp, 1000.0_wp, 1000.0_wp]
    q0 = 0.0_wp
    DO i = 1, 5
      q0(3*i - 2) = REAL(i - 1, wp)   ! x = 0..4
      q0(3*i) = -0.001_wp             ! z just below the floor (seabed active at the seed)
    END DO
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 4)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    kn = 1.0e5_wp
    fixed = [1, 2, 13, 14]    ! node 1 and node 5 pinned in x,y only; every z free
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, &
                               seabed_z_floor=0.0_wp, seabed_kn=kn)
    CALL expect_es(es, CD_STATIC_OK, 'grounded:ErrStat')
    CALL require(converged, 'grounded:converged')
    ! total upward seabed reaction == total downward weight (180 N)
    CALL CD_Seabed_Penalty_Load(RESHAPE(q, [3, 5]), kn, 0.0_wp, seabed_f, seabed_kr, es, em)
    reaction = seabed_f(3) + seabed_f(6) + seabed_f(9) + seabed_f(12) + seabed_f(15)
    CALL expect(reaction, 180.0_wp, 'grounded:reaction-balances-weight')
    DO i = 1, 15
      CALL expect(q(i), want_q(i), 'grounded:q')
    END DO
  END SUBROUTINE case_fully_grounded

  SUBROUTINE case_partial_grounded()
    !! A taut bar sagging under gravity onto a raised seabed (z_floor = -0.3): the
    !! mid-span rests on the floor, the ends hang above it. No node penetrates beyond
    !! tolerance, and the converged shape matches the reference (grounded-chain regression).
    INTEGER  :: conn(2, 4), fixed(6), es, n_iter, i
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15), load(3, 4), kn(5), pen, max_pen
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: z_floor = -0.3_wp
    REAL(wp), PARAMETER :: want_q(15) = [ &
                           0.0_wp, 0.0_wp, 0.0_wp, &
                           0.98029580379726322_wp, 0.0_wp, -0.30004343547623757_wp, &
                           2.0_wp, 0.0_wp, -0.30044894215770507_wp, &
                           3.0197041962027367_wp, 0.0_wp, -0.30004343547623757_wp, &
                           4.0_wp, 0.0_wp, 0.0_wp]
    conn = RESHAPE([1, 2, 2, 3, 3, 4, 4, 5], [2, 4])
    l0 = [0.9_wp, 0.9_wp, 0.9_wp, 0.9_wp]
    ea = [1000.0_wp, 1000.0_wp, 1000.0_wp, 1000.0_wp]
    q0 = 0.0_wp
    DO i = 1, 5
      q0(3*i - 2) = REAL(i - 1, wp)
    END DO
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 4)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    kn = 1.0e5_wp
    fixed = [1, 2, 3, 13, 14, 15]
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, &
                               seabed_z_floor=z_floor, seabed_kn=kn)
    CALL expect_es(es, CD_STATIC_OK, 'partial:ErrStat')
    CALL require(converged, 'partial:converged')
    ! no node penetrates the seabed beyond the penalty floor tolerance
    max_pen = 0.0_wp
    DO i = 1, 5
      pen = z_floor - q(3*i)
      IF (pen > max_pen) max_pen = pen
    END DO
    CALL require(max_pen < 1.0e-3_wp, 'partial:no-through-seabed')
    CALL require(max_pen > 0.0_wp, 'partial:seabed-actually-engaged')
    DO i = 1, 15
      CALL expect(q(i), want_q(i), 'partial:q-vs-reference')
    END DO
  END SUBROUTINE case_partial_grounded

  SUBROUTINE case_bathymetry_seabed_route()
    !! The static solver accepts a variable bathymetry surface instead of a scalar
    !! z_floor. This all-prescribed route proves the production solver validates and
    !! assembles the bathymetry contact path without perturbing the flat-floor gates.
    TYPE(CD_BathymetryType) :: bathy, empty_bathy
    TYPE(CableSolverConfig) :: cfg
    REAL(wp) :: q0(6), q(6), f_ext(6), l0(1), ea(1), kn(2), depth(2, 2)
    INTEGER :: conn(2, 1), fixed(6), n_iter, es
    LOGICAL :: converged, stalled, at_floor
    CHARACTER(160) :: em

    q0 = [0.0_wp, 0.0_wp, -100.5_wp, 10.0_wp, 0.0_wp, -101.0_wp]
    f_ext = 0.0_wp
    conn(:, 1) = [1, 2]
    l0 = [10.0_wp]
    ea = [1.0e6_wp]
    fixed = [1, 2, 3, 4, 5, 6]
    kn = [100.0_wp, 200.0_wp]
    depth = RESHAPE([100.0_wp, 102.0_wp, 101.0_wp, 103.0_wp], [2, 2])
    CALL CD_Init_Bathymetry(bathy, [0.0_wp, 10.0_wp], [0.0_wp, 10.0_wp], depth, es, em)
    CALL require(es == CD_BATHY_OK, 'bathy-route:init')

    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, &
                               seabed_kn=kn, bathymetry=bathy)
    CALL require(es == CD_STATIC_OK .AND. converged, 'bathy-route:solve')
    CALL require(nan_max_abs(q - q0) < 1.0e-14_wp, 'bathy-route:all-fixed-state')

    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, &
                               seabed_kn=kn, bathymetry=empty_bathy)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'bathy-route:uninitialized-fails')

    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, fixed, cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, &
                               seabed_z_floor=-100.0_wp, seabed_kn=kn, bathymetry=bathy)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'bathy-route:mutually-exclusive')

    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_bathymetry_seabed_route

  SUBROUTINE case_seabed_fail_closed()
    !! Invalid seabed inputs fail closed; supplying only one of the two seabed args
    !! is rejected.
    INTEGER  :: conn(2, 4), es, n_iter
    REAL(wp) :: l0(4), ea(4), q0(15), f_ext(15), q(15), kn(5), kn_bad(4), kn_nan(5)
    LOGICAL  :: converged, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    CHARACTER(120) :: em
    INTEGER :: i
    conn = RESHAPE([1, 2, 2, 3, 3, 4, 4, 5], [2, 4])
    l0 = [0.9_wp, 0.9_wp, 0.9_wp, 0.9_wp]
    ea = [1000.0_wp, 1000.0_wp, 1000.0_wp, 1000.0_wp]
    q0 = 0.0_wp
    DO i = 1, 5
      q0(3*i - 2) = REAL(i - 1, wp)
    END DO
    f_ext = 0.0_wp
    kn = 1.0e5_wp
    kn_bad = 1.0e5_wp          ! wrong length (4, not n_nodes = 5)
    kn_nan = 1.0e5_wp; kn_nan(3) = -1.0_wp   ! a non-positive entry
    ! only one seabed arg supplied
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 13, 14, 15], cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, seabed_z_floor=0.0_wp)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'seabed:one-arg-only')
    ! wrong-size seabed_kn
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 13, 14, 15], cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, &
                               seabed_z_floor=0.0_wp, seabed_kn=kn_bad)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'seabed:kn-wrong-size')
    ! non-positive seabed_kn entry
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 13, 14, 15], cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, &
                               seabed_z_floor=0.0_wp, seabed_kn=kn_nan)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'seabed:kn-nonpositive')
    ! non-finite z_floor
    CALL CD_Static_Cable_Solve(q0, conn, l0, ea, .FALSE., f_ext, [1, 2, 3, 13, 14, 15], cfg, &
                               q, converged, stalled, at_floor, n_iter, es, em, &
                               seabed_z_floor=IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN), seabed_kn=kn)
    CALL expect_es(es, CD_STATIC_BADINPUT, 'seabed:zfloor-nan')
  END SUBROUTINE case_seabed_fail_closed

END PROGRAM test_cable_static
