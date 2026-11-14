! File: tests/test_l1_catenary.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_catenary
  !! L1-7 static catenary, scored on the Fortran core against the ANALYTICAL
  !! inextensible catenary. A heavy chain of suspended
  !! length L hangs between two level pinned supports a span S apart under its own
  !! weight; the closed-form shape is y(x) = a cosh(x/a) with the catenary parameter
  !! a fixed by L = 2 a sinh(S/(2a)). The EI=0 static solve starts from a parabola
  !! through the supports with 1.25 times the catenary's sag, nodes uniform in x (so the seed is
  !! neither the answer's shape nor its arc-length spacing), solves to equilibrium by load
  !! continuation with a large EA so extensibility is negligible, and the converged
  !! shape must match the analytical catenary in a normalised L2 sense below the
  !! L1-7 gate, having moved well away from the seed.
  !!
  !! This mirrors the L1-7 gate (VALIDATION_SPEC.md), promoted
  !! onto src/ via CD_Static_Cable_Solve -- the first analytical L1 gate scored on
  !! the Fortran core (alongside the seabed-reaction and axial-period checks already
  !! gated in test_cable_static / test_cable_dynamic).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Loads, ONLY: CD_Assemble_Distributed_Load
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 32           ! elements
  INTEGER, PARAMETER :: NN = NE + 1       ! nodes
  REAL(wp), PARAMETER :: SPAN = 100.0_wp  ! horizontal support separation [m]
  REAL(wp), PARAMETER :: LSUS = 120.0_wp  ! suspended (unstretched) length [m]
  REAL(wp), PARAMETER :: EA = 1.0e8_wp    ! axial stiffness [N] (large -> ~inextensible)
  REAL(wp), PARAMETER :: WPL = 100.0_wp   ! self-weight per metre [N/m]
  ! L1-7 gate: normalised L2 of (FE - analytical catenary) positions. The Fortran
  ! EI=0 solve with a near-inextensible EA lands ~2.1e-4 at this mesh; the gate is
  ! set ~5x above that so it catches a regression without being float-brittle.
  REAL(wp), PARAMETER :: GATE = 1.0e-3_wp

  INTEGER  :: nfail, conn(2, NE), fixed(6), es, n_iter, n_stages, i
  REAL(wp) :: l0(NE), ea_arr(NE), load(3, NE), f_ext(3*NN)
  REAL(wp) :: q0(3*NN), q(3*NN), an(3, NN)
  REAL(wp) :: acat, diff2, ref2, err
  LOGICAL  :: converged, stalled, at_floor
  TYPE(CableSolverConfig) :: cfg
  CHARACTER(120) :: em

  nfail = 0

  ! --- analytical catenary parameter a: solve L = 2 a sinh(S/(2a)) by bisection ---
  acat = solve_catenary_a(SPAN, LSUS)

  ! --- analytical node positions, uniform in arc length along the catenary ---
  CALL analytical_catenary_nodes(SPAN, LSUS, acat, NN, an)

  ! --- mesh: chain of NE uniform segments, L0 = L / NE ---
  DO i = 1, NE
    conn(1, i) = i
    conn(2, i) = i + 1
    l0(i) = LSUS/REAL(NE, wp)
    ea_arr(i) = EA
    load(1, i) = 0.0_wp
    load(2, i) = 0.0_wp
    load(3, i) = -WPL                 ! self-weight, -z, per unit length
  END DO
  CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
  CALL require(es == 0, 'fext-ErrStat')

  ! --- seed q0 with a parabola of 1.25x the analytical sag (every element stretched), nodes
  ! uniform in x; pin both ends ---
  DO i = 1, NN
    q0(3*i - 2) = SPAN*REAL(i - 1, wp)/REAL(NE, wp)
    q0(3*i - 1) = 0.0_wp
    q0(3*i) = 1.25_wp*MINVAL(an(3, :))*4.0_wp*(q0(3*i - 2)/SPAN)*(1.0_wp - q0(3*i - 2)/SPAN)
  END DO
  fixed = [1, 2, 3, 3*NN - 2, 3*NN - 1, 3*NN]

  CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea_arr, .FALSE., f_ext, fixed, cfg, &
                                          [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp], q, converged, stalled, &
                                          at_floor, n_iter, n_stages, es, em)
  CALL require(es == CD_STATIC_OK, 'solve-ErrStat')
  CALL require(converged, 'converged')

  ! --- normalised L2 of (FE - analytical) node positions ---
  diff2 = 0.0_wp
  ref2 = 0.0_wp
  DO i = 1, NN
    diff2 = diff2 + SUM((q(3*i - 2:3*i) - an(:, i))**2)
    ref2 = ref2 + SUM(an(:, i)**2)
  END DO
  err = SQRT(diff2/ref2)
  WRITE (*, '(A,I0,A,ES12.4,A,ES12.4)') 'L1-7 catenary (Fortran, n_elem=', NE, &
    '): normalised L2 = ', err, '  gate < ', GATE
  CALL require(err < GATE, 'L1-7:catenary-vs-analytical')
  ! the solve did the work: the seed itself is far outside the gate
  diff2 = 0.0_wp
  DO i = 1, NN
    diff2 = diff2 + SUM((q0(3*i - 2:3*i) - an(:, i))**2)
  END DO
  CALL require(SQRT(diff2/ref2) > 10.0_wp*GATE, 'L1-7:seed-is-not-the-answer')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran EI=0 static solve matches the analytical catenary (L1-7)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  REAL(wp) FUNCTION solve_catenary_a(s, l) RESULT(a)
    !! Bisection for a in  L = 2 a sinh(S/(2a)).  f(a) = 2 a sinh(S/2a) - L is
    !! monotone decreasing from +inf (a->0+) to S-L < 0 (a->inf), so it has a
    !! unique root for L > S.
    REAL(wp), INTENT(IN) :: s, l
    REAL(wp) :: lo, hi, mid, f
    INTEGER :: it
    lo = s/100.0_wp        ! f(lo) > 0
    hi = s*100.0_wp        ! f(hi) ~ S - L < 0
    DO it = 1, 200
      mid = 0.5_wp*(lo + hi)
      f = 2.0_wp*mid*SINH(s/(2.0_wp*mid)) - l
      IF (f > 0.0_wp) THEN
        lo = mid
      ELSE
        hi = mid
      END IF
    END DO
    a = 0.5_wp*(lo + hi)
  END FUNCTION solve_catenary_a

  SUBROUTINE analytical_catenary_nodes(s, l, a, n, pos)
    !! Node positions on the analytical catenary, uniform in arc length. Supports at
    !! (0,0,0) and (S,0,0); the chain hangs in the x-z plane (y = 0). The low point
    !! is at arc length L/2 from the left support; for a node at signed arc sigma
    !! from the low point, xi = a asinh(sigma/a), x = S/2 + xi, z = a cosh(xi/a) -
    !! a cosh(S/(2a)) (zero at the supports, negative sag below).
    REAL(wp), INTENT(IN)  :: s, l, a
    INTEGER, INTENT(IN)  :: n
    REAL(wp), INTENT(OUT) :: pos(3, n)
    REAL(wp) :: sigma, xi, z_support
    INTEGER :: i
    z_support = a*COSH(s/(2.0_wp*a))
    DO i = 1, n
      sigma = REAL(i - 1, wp)*l/REAL(n - 1, wp) - 0.5_wp*l    ! arc from the low point
      xi = a*ASINH(sigma/a)
      pos(1, i) = 0.5_wp*s + xi
      pos(2, i) = 0.0_wp
      pos(3, i) = a*COSH(xi/a) - z_support
    END DO
  END SUBROUTINE analytical_catenary_nodes

END PROGRAM test_l1_catenary
