! File: tests/test_of_mooring_counters.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_of_mooring_counters
  !! PORTABLE-COUNTER performance gate for the production EI=0 OpenFAST-aggregate path.
  !! Wall-clock gates are machine-bound and flaky in CI; the honest regression tripwires
  !! are COUNTS, which are deterministic everywhere: Newton iterations per mooring step,
  !! step convergence, the adaptive-substep fallback tripwire, and finite loads-out.
  !!
  !! The rig is the production cadence in miniature -- the committed VolturnUS-S mooring
  !! deck (path = argument 1) driven for 60 s at dtM = 0.1 s with the production bench's
  !! surge+heave harmonic (2 m, 10 s, half-cosine ramp): one CD_AGG_Step_Moving + one
  !! CD_AGG_CalcOutput + one load read per mooring step, exactly the supercycled
  !! CompMooring = 5 module cadence.
  !!
  !! Gates (counts only; bands hold ~2x headroom over the measured values so they trip
  !! on real regressions, not machine noise):
  !!   * every step converges, no hard errors;
  !!   * mean Newton/step <= 4.0 and max <= 20 (measured 2.24 mean; max 14, at the
  !!     cold-start ramp onset -- the steady window runs 2-4);
  !!   * the substep-fallback tripwire stays 0 (a healthy production run never
  !!     subdivides) and its reset semantics hold;
  !!   * loads out are finite every step.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_Fallback_Count, CD_AGG_Fallback_Reset, &
                                         CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_Step_Moving, CD_AGG_CalcOutput, &
                                         CD_AGG_End, CD_AGG_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: DTM = 0.1_wp, DURATION = 60.0_wp, AMP = 2.0_wp, PERIOD = 10.0_wp
  REAL(wp), PARAMETER :: MEAN_ITER_GATE = 4.0_wp
  INTEGER, PARAMETER :: MAX_ITER_GATE = 20

  CHARACTER(1024) :: deck
  REAL(wp) :: t, w, ramp, s, c, pi, iter_sum
  REAL(wp), ALLOCATABLE :: pos0(:, :), pos(:, :), vel(:, :), acc(:, :), fld(:, :)
  TYPE(CD_AGG_ModuleType) :: agg
  INTEGER :: es, ncp, nstep, istep, niter, iter_max, nfail
  LOGICAL :: conv, stalled
  CHARACTER(512) :: em

  nfail = 0
  pi = ACOS(-1.0_wp)
  IF (COMMAND_ARGUMENT_COUNT() < 1) THEN
    WRITE (*, '(A)') 'FAIL: deck path argument required'
    ERROR STOP 1
  END IF
  CALL GET_COMMAND_ARGUMENT(1, deck)

  CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DTM, es, em)
  CALL require(es == CD_AGG_OK, 'aggregate init from the committed deck: '//TRIM(em))
  IF (nfail > 0) THEN
    WRITE (*, '(A)') 'FAIL: cannot initialize'
    ERROR STOP 1
  END IF
  ncp = CD_AGG_NMovingPoints(agg, es, em)
  CALL require(es == CD_AGG_OK .AND. ncp >= 1, 'moving points present')
  ALLOCATE (pos0(3, ncp), pos(3, ncp), vel(3, ncp), acc(3, ncp), fld(3, ncp))
  CALL CD_AGG_GetMovingPointMesh(agg, pos0, vel, acc, fld, es, em)
  CALL require(es == CD_AGG_OK, 'initial mesh read')

  ! reset semantics: the tripwire starts a measured window at zero
  CALL CD_AGG_Fallback_Reset(agg)
  CALL require(CD_AGG_Fallback_Count(agg) == 0, 'fallback tripwire zero after reset')

  nstep = NINT(DURATION/DTM)
  w = 2.0_wp*pi/PERIOD
  iter_sum = 0.0_wp; iter_max = 0
  DO istep = 1, nstep
    t = REAL(istep, wp)*DTM
    IF (t < PERIOD) THEN
      ramp = 0.5_wp*(1.0_wp - COS(pi*t/PERIOD))
    ELSE
      ramp = 1.0_wp
    END IF
    s = SIN(w*t); c = COS(w*t)
    pos = pos0
    pos(1, :) = pos0(1, :) + ramp*AMP*s
    pos(3, :) = pos0(3, :) + ramp*AMP*c*0.5_wp
    vel = 0.0_wp
    vel(1, :) = ramp*AMP*w*c
    vel(3, :) = -ramp*AMP*w*s*0.5_wp
    acc = 0.0_wp
    acc(1, :) = -ramp*AMP*w*w*s
    acc(3, :) = -ramp*AMP*w*w*c*0.5_wp
    CALL CD_AGG_Step_Moving(agg, DTM, pos, vel, acc, conv, stalled, niter, es, em)
    IF (es /= CD_AGG_OK .OR. .NOT. conv) THEN
      WRITE (*, '(A,F8.2,A)') 'FAIL: step at t = ', t, ' s: '//TRIM(em)
      nfail = nfail + 1
      EXIT
    END IF
    iter_sum = iter_sum + REAL(niter, wp)
    iter_max = MAX(iter_max, niter)
    CALL CD_AGG_CalcOutput(agg, es, em)
    IF (es /= CD_AGG_OK) THEN
      WRITE (*, '(A)') 'FAIL: CalcOutput: '//TRIM(em)
      nfail = nfail + 1
      EXIT
    END IF
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, fld, es, em)
    IF (es /= CD_AGG_OK .OR. .NOT. ALL(IEEE_IS_FINITE(fld))) THEN
      WRITE (*, '(A,F8.2,A)') 'FAIL: non-finite or unreadable loads at t = ', t, ' s'
      nfail = nfail + 1
      EXIT
    END IF
  END DO

  WRITE (*, '(A,F6.2,A,I0)') 'counters: newton/step mean = ', iter_sum/REAL(nstep, wp), &
    '   max = ', iter_max
  WRITE (*, '(A,I0)') 'counters: substep fallbacks = ', CD_AGG_Fallback_Count(agg)

  CALL require(iter_sum/REAL(nstep, wp) <= MEAN_ITER_GATE, 'mean Newton/step within the band')
  CALL require(iter_max <= MAX_ITER_GATE, 'max Newton/step within the band')
  CALL require(CD_AGG_Fallback_Count(agg) == 0, 'no substep fallback over the healthy window')

  CALL CD_AGG_End(agg, es, em)
  CALL require(es == CD_AGG_OK, 'aggregate End')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: production-path portable performance counters within their bands'

CONTAINS

  SUBROUTINE require(cond, what)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: what
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'FAIL: '//what
      nfail = nfail + 1
    ELSE
      WRITE (*, '(A)') 'ok:   '//what
    END IF
  END SUBROUTINE require

END PROGRAM test_of_mooring_counters
