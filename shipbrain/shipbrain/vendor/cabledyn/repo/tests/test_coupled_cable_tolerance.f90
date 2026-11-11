! File: tests/test_coupled_cable_tolerance.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> One Newton tolerance for a finite-EI cable on every route. A cable in a mixed EI = 0 + finite-EI
!> deck, in OpenFAST (CompMooring = 5), in FAST.Farm and behind the C API runs on the coupled
!> aggregate; alone in a deck it runs on the standalone cubic-Hermite route. Both step it with the
!> deck's dynamic_solver relative tolerance and iteration budget (default 1e-8, 30). A lazy cable
!> (EI 1.99e4 N m^2, 80 elements, its run on a 100 m seabed) hangs from a Coupled fairlead that
!> moves along (3, 1, 1.5) m sin(2 pi t / 10 s), ramped in over 5 s (C2), beside a 450 m chain on
!> a second Coupled point moved the same way. The standalone driver (the executable given as the
!> first argument) runs the mixed deck and the cable alone, from the same motionFile.
!>  1. rhoInf 1.0, dtM 0.05 s and rhoInf 0.4, dtM 0.1 s: FairTen2 and AnchTen2 of the two routes
!>     agree at every row to 1e-6 of their peak (measured: to the printed precision, 5e-8), and the
!>     fairlead bend moment BendMom2N1 (a near-zero moment at the pinned end, 0.07 and 3.9 N m) to
!>     1e-3 of its peak (measured 1.2e-5 and 5e-8). The coupled cable stepped to the former fixed
!>     coupled tolerance 5e-3 failed both: at rhoInf 1 the mixed route's FairTen2 peaked at 4.3e5 N
!>     against 1.9e4 N (AnchTen2 5.5e5 against 2.1e3 N), at dtM 0.1 its FairTen2 fell to 8307 N
!>     against 10799 N and its BendMom2N1 rose to 1612 against 3.9 N m.
!>  2. rhoInf 1.0, dtM 0.05 s, the cable alone driven by a host through the analytic motion: the
!>     C API (CableDyn_InitDeck, CableDyn_Step, CableDyn_EvalChannel), the aggregate as OpenFAST
!>     builds it (host environment, no deck ambient, host fluid fields) and as FAST.Farm builds it
!>     (a TURBINES row, a Turbine1 fairlead) give the standalone driver's channels to the gate 1
!>     bounds from the static row on (measured 4.5e-8 and 2.1e-5); the OpenFAST and FAST.Farm cables
!>     carry the deck's default tolerance and budget, and a deck's dynamic_solver row (2e-8, 25)
!>     reaches them.
!>  3. The same mixed deck and the cable alone, both fairleads held in still water for 10 s at dtM
!>     0.025 s: at rhoInf 0, 0.4 and 1.0 the held equilibrium stays put on both routes (FairTen2 and
!>     AnchTen2 within HELD_TOL = 1e-3 N of the static row; measured 6e-5 N, the printed digits) and
!>     the routes agree to TEN_TOL. Stepped to 5e-3 the coupled cable was not dissipative: the
!>     residual each step left grew at rhoInf 0.4 into an oscillation of +-2.1 N (FairTen2) and
!>     +-1.1 N (AnchTen2) by 10 s, and the anchor tension moved by 0.029 N at rhoInf 0 and 0.015 N
!>     at rhoInf 1. With the fairlead row 1 placed 0.1 mm off the static fairlead and then held
!>     (a seed), the disturbance decays at rhoInf 0.4 (the last 2.5 s at most half the first) and
!>     stays bounded at rhoInf 1 (at most the first 2.5 s), as on the single-line route, which the
!>     mixed route matches to TEN_TOL; stepped to 5e-3 the coupled cable seeded by 1 cm grew at
!>     rhoInf 1 from +-8.2e5 N to +-3.0e6 N while the single-line route decayed from 5.0e4 N to
!>     3.3e3 N.
PROGRAM test_coupled_cable_tolerance
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_BOOL, C_CHAR, C_DOUBLE, C_INT, C_LOC, C_NULL_CHAR, C_PTR
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CAPI, ONLY: CableDyn_Create, CableDyn_Close, CableDyn_InitDeck, CableDyn_Step, &
                           CableDyn_EvalChannel, CableDyn_GetLastError, CableDyn_NCoupledDOF
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_NFluidNodes, CD_AGG_SetFluidFields, CD_AGG_Step_Moving, &
                                         CD_AGG_EvalChannel, CD_AGG_End, CD_AGG_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, PERIOD = 10.0_wp, RAMP = 5.0_wp, TMAX = 20.0_wp
  REAL(wp), PARAMETER :: DIR(3) = [3.0_wp, 1.0_wp, 1.5_wp]
  REAL(wp), PARAMETER :: CHAIN_FAIR(3) = [20.0_wp, 0.0_wp, -10.0_wp], CAB_FAIR(3) = [-20.0_wp, 0.0_wp, -10.0_wp]
  ! gate bounds: tensions to TEN_TOL of their peak, the fairlead bend moment to BEND_TOL of its peak or
  ! of BEND_FLOOR [N m] (a held fairlead's moment is round-off about zero); SEED_TOL replaces TEN_TOL
  ! for the seeded undamped march of gate 3 (rhoInf 1), which keeps the step-to-step solver residual
  REAL(wp), PARAMETER :: TEN_TOL = 1.0e-6_wp, BEND_TOL = 1.0e-3_wp, BEND_FLOOR = 1.0_wp, SEED_TOL = 1.0e-4_wp
  ! gate 3: the held equilibrium's tensions to HELD_TOL [N] of the static row; the seed of the
  ! fairlead row 1 [m]; the time step, duration and decay windows [s]
  REAL(wp), PARAMETER :: HELD_TOL = 1.0e-3_wp, SEED = 1.0e-4_wp, HELD_DT = 0.025_wp, HELD_TMAX = 10.0_wp, &
                         DECAY_WINDOW = 2.5_wp
  INTEGER, PARAMETER :: MAXROW = 500, MAXCOL = 8, NCH = 3
  CHARACTER(16), PARAMETER :: CHANNELS(NCH) = [CHARACTER(16) :: 'FairTen2', 'AnchTen2', 'BendMom2N1']
  ! host routes of gate 2
  INTEGER, PARAMETER :: HOST_CAPI = 1, HOST_OPENFAST = 2, HOST_FARM = 3
  CHARACTER(10), PARAMETER :: HOST_NAME(3) = [CHARACTER(10) :: 'C API', 'OpenFAST', 'FAST.Farm']
  CHARACTER(1024) :: driver
  INTEGER :: n_fail = 0, host

  IF (COMMAND_ARGUMENT_COUNT() < 1) ERROR STOP 'usage: test_coupled_cable_tolerance <CableDyn_driver executable>'
  CALL GET_COMMAND_ARGUMENT(1, driver)

  CALL check_routes(1.0_wp, 0.05_wp, 'cct_r1')
  CALL check_routes(0.4_wp, 0.1_wp, 'cct_r04')
  DO host = HOST_CAPI, HOST_FARM
    CALL check_host(host)
  END DO
  CALL check_held(0.0_wp, .FALSE., 'cct_h0')
  CALL check_held(0.4_wp, .FALSE., 'cct_h04')
  CALL check_held(1.0_wp, .FALSE., 'cct_h1')
  CALL check_held(0.4_wp, .TRUE., 'cct_s04')
  CALL check_held(1.0_wp, .TRUE., 'cct_s1')
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' coupled-cable tolerance gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: the coupled and the standalone finite-EI cable step to the same tolerance'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  SUBROUTINE motion_state(t, g, dg, d2g)
    !! g(t) = r(t) sin(2 pi t / PERIOD) with the C2 ramp r = 10 s^3 - 15 s^4 + 6 s^5, s = min(t / RAMP, 1),
    !! and its exact first and second derivatives: from rest with zero acceleration at t = 0.
    REAL(wp), INTENT(IN) :: t
    REAL(wp), INTENT(OUT) :: g, dg, d2g
    REAL(wp) :: s, r, dr, d2r, w, f, df, d2f
    s = MIN(t/RAMP, 1.0_wp)
    r = 10.0_wp*s**3 - 15.0_wp*s**4 + 6.0_wp*s**5
    dr = 0.0_wp
    d2r = 0.0_wp
    IF (t < RAMP) THEN
      dr = (30.0_wp*s**2 - 60.0_wp*s**3 + 30.0_wp*s**4)/RAMP
      d2r = (60.0_wp*s - 180.0_wp*s**2 + 120.0_wp*s**3)/RAMP**2
    END IF
    w = 2.0_wp*PI/PERIOD
    f = SIN(w*t)
    df = w*COS(w*t)
    d2f = -w*w*SIN(w*t)
    g = r*f
    dg = dr*f + r*df
    d2g = d2r*f + 2.0_wp*dr*df + r*d2f
  END SUBROUTINE motion_state

  SUBROUTINE write_motion(path, dt, with_chain)
    !! The motionFile of the cable's fairlead (point 3) and, with_chain, the chain's (point 1).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(IN) :: with_chain
    INTEGER :: u, k
    REAL(wp) :: t, g, dg, d2g
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az'
    DO k = 0, NINT(TMAX/dt) + 1
      t = REAL(k, wp)*dt
      CALL motion_state(t, g, dg, d2g)
      IF (with_chain) WRITE (u, '(F10.6,A,9ES24.15E3)') t, ' 1 ', CHAIN_FAIR + DIR*g, DIR*dg, DIR*d2g
      WRITE (u, '(F10.6,A,9ES24.15E3)') t, ' 3 ', CAB_FAIR + DIR*g, DIR*dg, DIR*d2g
    END DO
    CLOSE (u)
  END SUBROUTINE write_motion

  SUBROUTINE write_held_motion(path, with_chain)
    !! The gate 3 seed: the cable's fairlead (point 3) and, with_chain, the chain's (point 1) at
    !! SEED m along DIR off their deck positions from row 1 on, at rest.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: with_chain
    REAL(wp), PARAMETER :: ZERO(6) = 0.0_wp
    INTEGER :: u, k
    REAL(wp) :: t, off(3)
    off = SEED*DIR/NORM2(DIR)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az'
    DO k = 0, NINT(HELD_TMAX/HELD_DT) + 1
      t = REAL(k, wp)*HELD_DT
      IF (with_chain) WRITE (u, '(F10.6,A,9ES24.15E3)') t, ' 1 ', CHAIN_FAIR + off, ZERO
      WRITE (u, '(F10.6,A,9ES24.15E3)') t, ' 3 ', CAB_FAIR + off, ZERO
    END DO
    CLOSE (u)
  END SUBROUTINE write_held_motion

  SUBROUTINE write_deck(path, rho_inf, dt, mixed, motion, farm, solver, run_tmax)
    !! The cable (line 2, points 3 -> 4) alone or, mixed, beside the chain (line 1, points 1 -> 2);
    !! motion: the motionFile (blank: a host drives point 3, or the deck holds it); farm: point 3 is
    !! Turbine1 of a TURBINES row at the origin; solver: a dynamic_solver row (blank: the defaults);
    !! run_tmax: TMax (default TMAX).
    CHARACTER(*), INTENT(IN) :: path, motion, solver
    REAL(wp), INTENT(IN) :: rho_inf, dt
    LOGICAL, INTENT(IN) :: mixed, farm
    REAL(wp), INTENT(IN), OPTIONAL :: run_tmax
    INTEGER :: u
    REAL(wp) :: tm
    tm = TMAX
    IF (PRESENT(run_tmax)) tm = run_tmax
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'coupled-cable tolerance gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.1 48.8389796939 500000000 -0.5 0 1.2 0.4 1 0.5'
    WRITE (u, '(A)') 'cab 0.16 36.7 469000000 -0.5 19900 1.2 0.1 1 0'
    IF (farm) THEN
      WRITE (u, '(A)') '--- TURBINES ---'
      WRITE (u, '(A)') 'J X0 Y0 Z0'
      WRITE (u, '(A)') '(-) (m) (m) (m)'
      WRITE (u, '(A)') '1 0 0 0'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    IF (mixed) THEN
      WRITE (u, '(A)') '1 Coupled 20 0 -10 0 0 0 0'
      WRITE (u, '(A)') '2 Fixed 400 0 -100 0 0 0 0'
    END IF
    WRITE (u, '(A)') '3 '//MERGE('Turbine1', 'Coupled ', farm)//' -20 0 -10 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -200 0 -100 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (mixed) WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    IF (mixed) WRITE (u, '(A)') '1 chain 450 50'
    WRITE (u, '(A)') '2 cab 260 80'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100 WtrDpth'
    WRITE (u, '(A)') '1e5 kBot'
    WRITE (u, '(A)') '1e4 cBot'
    WRITE (u, '(F6.3,A)') dt, ' dtM'
    WRITE (u, '(F6.2,A)') tm, ' TMax'
    WRITE (u, '(F5.2,A)') rho_inf, ' rhoInf'
    IF (LEN_TRIM(motion) > 0) WRITE (u, '(A)') TRIM(motion)//' motionFile'
    IF (LEN_TRIM(solver) > 0) WRITE (u, '(A)') TRIM(solver)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen2'
    WRITE (u, '(A)') 'AnchTen2'
    WRITE (u, '(A)') 'BendMom2N1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE run_driver(deck, root, ok)
    CHARACTER(*), INTENT(IN) :: deck, root
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: ex, cs
    CALL EXECUTE_COMMAND_LINE('"'//TRIM(driver)//'" '//deck//' '//root//' > '//root//'.log 2>&1', &
                              WAIT=.TRUE., EXITSTAT=ex, CMDSTAT=cs)
    ok = cs == 0 .AND. ex == 0
  END SUBROUTINE run_driver

  SUBROUTINE read_channels(path, vals, nrow)
    !! The CHANNELS columns of a driver .out file, one row per output time.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: vals(MAXROW, NCH)
    INTEGER, INTENT(OUT) :: nrow
    CHARACTER(32) :: names(MAXCOL)
    CHARACTER(4096) :: buf
    REAL(wp) :: row(MAXCOL)
    INTEGER :: u, ios, ncol, k, c, col(NCH)
    vals = 0.0_wp
    nrow = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    names = ''
    READ (buf, *, IOSTAT=ios) names
    ncol = 0
    DO k = 1, MAXCOL
      IF (LEN_TRIM(names(k)) > 0) ncol = k
    END DO
    col = 0
    DO c = 1, NCH
      DO k = 1, ncol
        IF (TRIM(names(k)) == TRIM(CHANNELS(c))) col(c) = k
      END DO
    END DO
    IF (ANY(col == 0)) THEN
      CLOSE (u); RETURN
    END IF
    DO
      IF (nrow == MAXROW) EXIT
      READ (u, *, IOSTAT=ios) row(1:ncol)
      IF (ios /= 0) EXIT
      nrow = nrow + 1
      vals(nrow, :) = row(col)
    END DO
    CLOSE (u)
  END SUBROUTINE read_channels

  SUBROUTINE compare(label, ref, got, n, ten_bound)
    !! Each channel of got against ref over n rows: |got - ref| <= tol max|ref| (the bend moment:
    !! tol max(max|ref|, BEND_FLOOR)); ten_bound replaces TEN_TOL.
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: ref(:, :), got(:, :)
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN), OPTIONAL :: ten_bound
    REAL(wp) :: e, peak, tol
    INTEGER :: c
    DO c = 1, NCH
      peak = MAXVAL(ABS(ref(1:n, c)))
      IF (c == 3) peak = MAX(peak, BEND_FLOOR)
      e = MAXVAL(ABS(got(1:n, c) - ref(1:n, c)))/MAX(peak, TINY(1.0_wp))
      IF (.NOT. IEEE_IS_FINITE(e)) e = HUGE(1.0_wp)
      tol = TEN_TOL
      IF (PRESENT(ten_bound)) tol = ten_bound
      IF (c == 3) tol = BEND_TOL
      WRITE (*, '(2X,A,1X,A,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A,ES9.2,A,ES8.1,A)') label, TRIM(CHANNELS(c)), &
        ': peak ', peak, ' (', MAXVAL(ABS(got(1:n, c))), '), range ', MINVAL(ref(1:n, c)), ' (', &
        MINVAL(got(1:n, c)), '), max|diff|/peak ', e, ' (bound ', tol, ')'
      CALL require(e <= tol, label//': '//TRIM(CHANNELS(c))//' agrees with the standalone route')
    END DO
  END SUBROUTINE compare

  SUBROUTINE check_routes(rho_inf, dt, root)
    !! Gate 1: the mixed route against the standalone cubic-Hermite route, same cable and motion.
    REAL(wp), INTENT(IN) :: rho_inf, dt
    CHARACTER(*), INTENT(IN) :: root
    REAL(wp) :: va(MAXROW, NCH), vb(MAXROW, NCH)
    INTEGER :: ra, rb
    LOGICAL :: ok_a, ok_b
    CHARACTER(64) :: label
    WRITE (label, '(A,F4.2,A,F5.3,A)') 'rhoInf ', rho_inf, ', dtM ', dt, ' s'
    CALL write_motion(root//'_single.txt', dt, .FALSE.)
    CALL write_motion(root//'_mixed.txt', dt, .TRUE.)
    CALL write_deck(root//'_single.dat', rho_inf, dt, .FALSE., root//'_single.txt', .FALSE., '')
    CALL write_deck(root//'_mixed.dat', rho_inf, dt, .TRUE., root//'_mixed.txt', .FALSE., '')
    CALL run_driver(root//'_single.dat', root//'_single', ok_a)
    CALL run_driver(root//'_mixed.dat', root//'_mixed', ok_b)
    CALL require(ok_a .AND. ok_b, TRIM(label)//': both routes run')
    IF (.NOT. (ok_a .AND. ok_b)) RETURN
    CALL read_channels(root//'_single.out', va, ra)
    CALL read_channels(root//'_mixed.out', vb, rb)
    CALL require(ra == NINT(TMAX/dt) + 1 .AND. rb == ra, TRIM(label)//': every output row is written')
    IF (ra /= rb .OR. ra < 2) RETURN
    WRITE (*, '(A)') 'gate 1, '//TRIM(label)//': standalone (mixed route):'
    CALL compare('mixed', va, vb, ra)
  END SUBROUTINE check_routes

  REAL(wp) FUNCTION half_swing(v, n, t0, t1) RESULT(h)
    !! Half the peak-to-peak of v over the output rows with t0 < t <= t1 (row k at (k - 1) HELD_DT).
    REAL(wp), INTENT(IN) :: v(:), t0, t1
    INTEGER, INTENT(IN) :: n
    REAL(wp) :: lo, hi, t
    INTEGER :: k
    lo = HUGE(1.0_wp)
    hi = -HUGE(1.0_wp)
    DO k = 1, n
      t = REAL(k - 1, wp)*HELD_DT
      IF (t <= t0 + 1.0e-9_wp .OR. t > t1 + 1.0e-9_wp) CYCLE
      lo = MIN(lo, v(k))
      hi = MAX(hi, v(k))
    END DO
    h = 0.5_wp*(hi - lo)
    IF (.NOT. IEEE_IS_FINITE(h)) h = HUGE(1.0_wp)
  END FUNCTION half_swing

  SUBROUTINE check_held(rho_inf, seeded, root)
    !! Gate 3: both fairleads held in still water (seeded: row 1 SEED m off the static fairlead).
    REAL(wp), INTENT(IN) :: rho_inf
    LOGICAL, INTENT(IN) :: seeded
    CHARACTER(*), INTENT(IN) :: root
    REAL(wp) :: va(MAXROW, NCH), vb(MAXROW, NCH), dev, h0, h1, ratio, bound
    INTEGER :: ra, rb, c, r
    LOGICAL :: ok_a, ok_b
    CHARACTER(80) :: label
    WRITE (label, '(A,F4.2,A)') 'rhoInf ', rho_inf, MERGE(', seeded', ', held  ', seeded)
    IF (seeded) THEN
      CALL write_held_motion(root//'_single.txt', .FALSE.)
      CALL write_held_motion(root//'_mixed.txt', .TRUE.)
      CALL write_deck(root//'_single.dat', rho_inf, HELD_DT, .FALSE., root//'_single.txt', .FALSE., '', HELD_TMAX)
      CALL write_deck(root//'_mixed.dat', rho_inf, HELD_DT, .TRUE., root//'_mixed.txt', .FALSE., '', HELD_TMAX)
    ELSE
      CALL write_deck(root//'_single.dat', rho_inf, HELD_DT, .FALSE., '', .FALSE., '', HELD_TMAX)
      CALL write_deck(root//'_mixed.dat', rho_inf, HELD_DT, .TRUE., '', .FALSE., '', HELD_TMAX)
    END IF
    CALL run_driver(root//'_single.dat', root//'_single', ok_a)
    CALL run_driver(root//'_mixed.dat', root//'_mixed', ok_b)
    CALL require(ok_a .AND. ok_b, TRIM(label)//': both routes run')
    IF (.NOT. (ok_a .AND. ok_b)) RETURN
    CALL read_channels(root//'_single.out', va, ra)
    CALL read_channels(root//'_mixed.out', vb, rb)
    CALL require(ra == NINT(HELD_TMAX/HELD_DT) + 1 .AND. rb == ra, TRIM(label)//': every output row is written')
    IF (ra /= rb .OR. ra < 2) RETURN
    WRITE (*, '(A)') 'gate 3, '//TRIM(label)//': standalone (mixed route):'
    IF (seeded .AND. rho_inf > 0.95_wp) THEN
      CALL compare('mixed', va, vb, ra, SEED_TOL)
    ELSE
      CALL compare('mixed', va, vb, ra)
    END IF
    DO c = 1, 2
      IF (.NOT. seeded) THEN
        DO r = 1, 2
          IF (r == 1) dev = MAXVAL(ABS(va(1:ra, c) - va(1, c)))
          IF (r == 2) dev = MAXVAL(ABS(vb(1:rb, c) - vb(1, c)))
          IF (.NOT. IEEE_IS_FINITE(dev)) dev = HUGE(1.0_wp)
          WRITE (*, '(2X,A,1X,A,A,ES10.3,A,ES8.1,A)') TRIM(MERGE('single', 'mixed ', r == 1)), TRIM(CHANNELS(c)), &
            ': held equilibrium, max|T - T(0)| ', dev, ' N (bound ', HELD_TOL, ' N)'
          CALL require(dev <= HELD_TOL, TRIM(label)//': '//TRIM(CHANNELS(c))//' holds the equilibrium on the '// &
                       TRIM(MERGE('single', 'mixed ', r == 1))//' route')
        END DO
      ELSE
        h0 = half_swing(vb(:, c), rb, 0.0_wp, DECAY_WINDOW)
        h1 = half_swing(vb(:, c), rb, HELD_TMAX - DECAY_WINDOW, HELD_TMAX)
        ratio = h1/MAX(h0, TINY(1.0_wp))
        bound = MERGE(1.0_wp, 0.5_wp, rho_inf > 0.95_wp)
        WRITE (*, '(2X,A,1X,A,A,ES10.3,A,ES10.3,A,F7.4,A,F4.2,A)') 'mixed', TRIM(CHANNELS(c)), ': half swing ', h0, &
          ' N in the first 2.5 s, ', h1, ' N in the last, ratio ', ratio, ' (bound ', bound, ')'
        CALL require(ratio <= bound, TRIM(label)//': the '//TRIM(CHANNELS(c))//' disturbance '// &
                     TRIM(MERGE('stays bounded', 'decays       ', rho_inf > 0.95_wp))//' on the mixed route')
      END IF
    END DO
  END SUBROUTINE check_held

  SUBROUTINE check_host(route)
    !! Gate 2: a host drives the cable alone through the analytic motion at rhoInf 1, dtM 0.05.
    INTEGER, INTENT(IN) :: route
    REAL(wp), PARAMETER :: RI = 1.0_wp, DT = 0.05_wp
    CHARACTER(*), PARAMETER :: ROOT = 'cct_r1'
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: agg
    CHARACTER(KIND=C_CHAR), TARGET :: c_path(64), c_tok(16), msg(512)
    TYPE(C_PTR) :: handle
    INTEGER(C_INT) :: ces, n_iter, ndof
    LOGICAL(C_BOOL) :: cconv, cstall
    REAL(C_DOUBLE), TARGET :: q(3), v(3), a(3)
    REAL(C_DOUBLE) :: cval
    REAL(wp) :: va(MAXROW, NCH), got(MAXROW, NCH), pos(3, 1), vel(3, 1), acc(3, 1), t, g, dg, d2g
    REAL(wp), ALLOCATABLE :: fv(:, :), fa(:, :), wz(:)
    INTEGER :: ra, k, c, i, es, nit, nfl
    LOGICAL :: conv, stall
    CHARACTER(2048) :: em
    CHARACTER(64) :: deck
    CHARACTER(16) :: tok

    CALL read_channels(ROOT//'_single.out', va, ra)
    CALL require(ra == NINT(TMAX/DT) + 1, HOST_NAME(route)//': the standalone reference of gate 1 exists')
    IF (ra /= NINT(TMAX/DT) + 1) RETURN
    deck = 'cct_host_'//TRIM(MERGE('farm', 'host', route == HOST_FARM))//'.dat'
    CALL write_deck(TRIM(deck), RI, DT, .FALSE., '', route == HOST_FARM, '')
    got = 0.0_wp
    IF (route == HOST_CAPI) THEN
      c_path = C_NULL_CHAR
      DO i = 1, LEN_TRIM(deck)
        c_path(i) = deck(i:i)
      END DO
      CALL CableDyn_Create(handle, ces)
      CALL CableDyn_InitDeck(handle, C_LOC(c_path), INT(LEN_TRIM(deck), C_INT), ces)
      IF (ces /= 0_C_INT) THEN
        CALL CableDyn_GetLastError(handle, C_LOC(msg), INT(SIZE(msg), C_INT))
        em = ''
        DO i = 1, SIZE(msg)
          IF (msg(i) == C_NULL_CHAR) EXIT
          em(i:i) = msg(i)
        END DO
      END IF
      ndof = -1_C_INT
      IF (ces == 0_C_INT) ndof = CableDyn_NCoupledDOF(handle, ces)
      CALL require(ces == 0_C_INT .AND. ndof == 3_C_INT, &
                   'C API: the cable deck initialises with one coupled point: '//TRIM(em))
      IF (ces /= 0_C_INT) THEN
        CALL CableDyn_Close(handle, ces); RETURN
      END IF
      ! row k + 1 at t = k dt; row 1 is the static state
      DO k = 0, ra - 1
        t = REAL(k, wp)*DT
        CALL motion_state(t, g, dg, d2g)
        q = CAB_FAIR + DIR*g
        v = DIR*dg
        a = DIR*d2g
        IF (k > 0) THEN
          CALL CableDyn_Step(handle, REAL(DT, C_DOUBLE), C_LOC(q), C_LOC(v), C_LOC(a), 3_C_INT, cconv, cstall, &
                             n_iter, ces)
          IF (ces /= 0_C_INT .OR. .NOT. LOGICAL(cconv)) EXIT
        END IF
        DO c = 1, NCH
          c_tok = C_NULL_CHAR
          tok = CHANNELS(c)
          DO i = 1, LEN_TRIM(tok)
            c_tok(i) = tok(i:i)
          END DO
          CALL CableDyn_EvalChannel(handle, C_LOC(c_tok), INT(SIZE(c_tok), C_INT), cval, ces)
          got(k + 1, c) = REAL(cval, wp)
        END DO
        IF (ces /= 0_C_INT) EXIT
      END DO
      CALL require(ces == 0_C_INT .AND. k == ra, 'C API: every step converges and every channel evaluates')
      CALL CableDyn_Close(handle, ces)
    ELSE
      ALLOCATE (agg)
      IF (route == HOST_OPENFAST) THEN
        CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DT, es, em, env_gravity=9.80665_wp, env_rho_water=1025.0_wp, &
                                   env_wtrdpth=100.0_wp, external_fluid=.TRUE., forbid_deck_ambient=.TRUE.)
      ELSE
        CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DT, es, em, n_turbines=1, &
                                   turbine_ref_pos=RESHAPE([0.0_wp, 0.0_wp, 0.0_wp], [3, 1]), &
                                   forbid_deck_ambient=.TRUE.)
      END IF
      CALL require(es == CD_AGG_OK, HOST_NAME(route)//': the cable deck initialises: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL require(CD_AGG_NMovingPoints(agg, es, em) == 1 .AND. agg%ncable == 1, &
                   HOST_NAME(route)//': one cable, one moving point')
      IF (agg%ncable /= 1) RETURN
      CALL require(agg%cables(1)%tol == 1.0e-8_wp .AND. agg%cables(1)%max_iter == 30, &
                   HOST_NAME(route)//': the cable steps to the deck default dynamic_solver 1e-8, 30')
      nfl = CD_AGG_NFluidNodes(agg, es, em)
      ALLOCATE (fv(3, nfl), fa(3, nfl), wz(nfl))
      fv = 0.0_wp
      fa = 0.0_wp
      wz = 0.0_wp
      DO k = 0, ra - 1
        t = REAL(k, wp)*DT
        CALL motion_state(t, g, dg, d2g)
        pos(:, 1) = CAB_FAIR + DIR*g
        vel(:, 1) = DIR*dg
        acc(:, 1) = DIR*d2g
        IF (k > 0) THEN
          IF (route == HOST_OPENFAST) THEN
            CALL CD_AGG_SetFluidFields(agg, fv, fa, wz, es, em)
            IF (es /= CD_AGG_OK) EXIT
          END IF
          CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, conv, stall, nit, es, em, t_committed=t)
          IF (es /= CD_AGG_OK .OR. .NOT. conv) EXIT
        END IF
        DO c = 1, NCH
          CALL CD_AGG_EvalChannel(agg, c, got(k + 1, c), es, em)
        END DO
        IF (es /= CD_AGG_OK) EXIT
      END DO
      CALL require(es == CD_AGG_OK .AND. k == ra, HOST_NAME(route)//': every step converges: '//TRIM(em))
      CALL CD_AGG_End(agg, es, em)
      ! a deck's dynamic_solver row reaches the host route's cable
      CALL write_deck(TRIM(deck), RI, DT, .FALSE., '', route == HOST_FARM, 'dynamic_solver 2.0e-8 1.0e-14 25 12')
      IF (route == HOST_OPENFAST) THEN
        CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DT, es, em, env_gravity=9.80665_wp, env_rho_water=1025.0_wp, &
                                   env_wtrdpth=100.0_wp, external_fluid=.TRUE., forbid_deck_ambient=.TRUE.)
      ELSE
        CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), DT, es, em, n_turbines=1, &
                                   turbine_ref_pos=RESHAPE([0.0_wp, 0.0_wp, 0.0_wp], [3, 1]), &
                                   forbid_deck_ambient=.TRUE.)
      END IF
      CALL require(es == CD_AGG_OK, HOST_NAME(route)//': the dynamic_solver deck initialises: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL require(agg%cables(1)%tol == 2.0e-8_wp .AND. agg%cables(1)%max_iter == 25, &
                   HOST_NAME(route)//': the deck dynamic_solver row sets the cable tolerance and budget')
      CALL CD_AGG_End(agg, es, em)
    END IF
    WRITE (*, '(A)') 'gate 2, '//TRIM(HOST_NAME(route))//', rhoInf 1.00, dtM 0.050 s: standalone (host route):'
    CALL compare(TRIM(HOST_NAME(route)), va, got, ra)
  END SUBROUTINE check_host

END PROGRAM test_coupled_cable_tolerance
