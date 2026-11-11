! File: tests/test_mixed_route_currents.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> Deck currents on the standalone mixed route: a deck that mixes an EI = 0 chain and a finite-EI
!> cable (on separate points, without bodies, rods or Free/Connect points) runs on the coupled
!> aggregate, marched by the standalone driver (the executable given as the first argument), and
!> takes every deck current the single-line routes take. Each deck is run three ways: the cable
!> alone (the standalone cubic-Hermite route), the chain alone (the EI = 0 route) and both together
!> (the mixed route); both Coupled fairleads surge 1 m from rest (motionFile) over 10 s.
!>  1. A uniform current (0.4, 0.3, 0) m/s and a sheared profile, both across the two lines (the
!>     cable along x, the chain along y), in the static start and the march: the mixed route
!>     against the single-line routes, each channel to a fraction of its range, beside the same
!>     comparison in still water (the route difference without a current). The static start agrees
!>     within STATIC_TOL: the chain and the cable exactly (measured 0). In the march the cable steps
!>     with the deck's Newton controls on both routes (1e-8 by default), in the driver and in the
!>     library march of the driver's loop alike: it agrees within DRIVER_CABLE_TOL (measured 0) and
!>     LIBRARY_CABLE_TOL (1.9e-8). Before the coupled cable took the deck's controls, it stepped to
!>     5e-3 on the mixed route and differed by 1.2e-3 of the range, in still water too. The chain
!>     agrees within CHAIN_TOL (exactly in a sheared current; its
!>     row-1 transfer re-derives its interior accelerations on the mixed route, by 5e-5 in still
!>     water). The current is felt: both mid nodes leave the vertical plane of their chord, and
!>     the chain's fairlead tension history differs from the still-water run's.
!>  2. MoorDyn-C Currents 1 (a sheared current_profile.txt), Currents 2 (a sheared
!>     current_profile_dynamic.txt that varies in time) and Currents 5 (a current_profile_4d.txt
!>     grid that varies in x, y, z and time): the gate 1 agreement of the mixed route with the
!>     single-line routes given the same file.
!>  3. The wrap of a Currents 2 table past its last sample in the march: three samples (0, 2, 4 s,
!>     the first and last equal) run to 10 s repeat with period 6 s. The mixed route matches the
!>     mixed route given the table unrolled to 12 s (round-off: 1e-9 of each channel's range) and
!>     departs from the same table held after its last sample (beyond 6 s, by more than 1 % of the
!>     chain's tension range): the march samples the wrapped field at every step.
!>  4. A uniform field written as a Currents 1 profile equals the OPTION uniform current on the
!>     mixed route to GRID_TOL of each channel's range (the profile's linear interpolation between
!>     equal levels is exact on some platforms and one ulp off on others, which the march carries:
!>     0 on Windows, 3.9e-8 on Linux gfortran); written as a Currents 5 grid (constant in space and time), its static
!>     start bit for bit and its march to GRID_TOL of each channel's range (the round-off of the
!>     grid's trilinear weights).
!>  5. The correction rewind of the aggregate (CD_AGG_Snapshot, a step, CD_AGG_Restore, the step
!>     again) every 20th step, in still water and in the Currents 2 field: the repeated step samples
!>     the current again from the restored state, and every channel of every step equals the march
!>     without rewinds bit for bit.
!>  6. The mixed route still refuses deck waves by name, and like the single-line routes a current
!>     OPTION beside Currents 2 (double-counting) and a current without dtM.
PROGRAM test_mixed_route_currents
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_UpdateStates_Moving, &
                                         CD_AGG_Step_Moving, CD_AGG_CalcOutput, CD_AGG_EvalChannel, &
                                         CD_AGG_NumChannels, CD_AGG_End, CD_AGG_MotionKinematics, &
                                         CD_AGG_Refresh_Accelerations, CD_AGG_Snapshot, CD_AGG_Restore, CD_AGG_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: DT = 0.05_wp, TMAX = 10.0_wp, PERIOD = 10.0_wp
  INTEGER, PARAMETER :: NSTEP = 200, MAXCOL = 16, MAXROW = 400
  CHARACTER(*), PARAMETER :: CAB_T = 'cab 0.2 60.0 4.0e8 0.0 1.0e4 1.2 0.1 1.0 0.0'
  CHARACTER(*), PARAMETER :: CHAIN_T = 'chain 0.1 50.0 1.0e9 -1.0 0.0 1.37 0.64 1.0 0.0'
  ! the mixed deck's channels: the cable (line 1) then the chain (line 2)
  CHARACTER(16), PARAMETER :: MIXED_OUTS(10) = [CHARACTER(16) :: 'FairTen1', 'AnchTen1', 'L1N21px', 'L1N21py', &
                                                     'L1N21pz', 'FairTen2', 'AnchTen2', 'L2N11px', 'L2N11py', 'L2N11pz']
  CHARACTER(16), PARAMETER :: CABLE_OUTS(5) = [CHARACTER(16) :: 'FairTen1', 'AnchTen1', 'L1N21px', 'L1N21py', &
                                                                                                             'L1N21pz']
  CHARACTER(16), PARAMETER :: CHAIN_OUTS(5) = [CHARACTER(16) :: 'FairTen1', 'AnchTen1', 'L1N11px', 'L1N11py', &
                                                                                                             'L1N11pz']
  ! differences of the mixed route from the single-line routes, of each channel's range (gate 1): the
  ! static start; the cable stepped by the driver, and by the library loop; the chain
  REAL(wp), PARAMETER :: STATIC_TOL = 1.0e-6_wp, DRIVER_CABLE_TOL = 1.0e-6_wp, LIBRARY_CABLE_TOL = 1.0e-6_wp
  REAL(wp), PARAMETER :: CHAIN_TOL = 1.0e-4_wp
  ! round-off between two writings of one field (gates 3 and 4), of each channel's range, and of a
  ! uniform field interpolated on a grid (gate 4)
  REAL(wp), PARAMETER :: SAME_TOL = 1.0e-9_wp, GRID_TOL = 1.0e-7_wp
  CHARACTER(1024) :: driver
  INTEGER :: n_fail = 0

  IF (COMMAND_ARGUMENT_COUNT() < 1) ERROR STOP 'usage: test_mixed_route_currents <CableDyn_driver executable>'
  CALL GET_COMMAND_ARGUMENT(1, driver)

  CALL check_option_currents()
  CALL check_moordyn_c_currents()
  CALL check_wrap()
  CALL check_uniform_writings()
  CALL check_snapshot('still/mixed.dat', '5 still water')
  CALL check_snapshot('c2/mixed.dat', '5 Currents 2')
  CALL check_refusals()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' mixed-route current gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: deck currents on the standalone mixed route'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  PURE SUBROUTINE smooth(amplitude, t, f, df, d2f)
    !! f = F (1 - cos w t) / 2 and its rates, w = 2 pi / PERIOD: a motion from rest.
    REAL(wp), INTENT(IN) :: amplitude, t
    REAL(wp), INTENT(OUT) :: f, df, d2f
    REAL(wp) :: w
    w = 2.0_wp*PI/PERIOD
    f = 0.5_wp*amplitude*(1.0_wp - COS(w*t))
    df = 0.5_wp*amplitude*w*SIN(w*t)
    d2f = 0.5_wp*amplitude*w*w*COS(w*t)
  END SUBROUTINE smooth

  SUBROUTINE write_motion(path, ids, ys)
    !! motionFile rows of the Coupled points ids at (0, ys, -50), each surging 1 m from rest.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: ids(:)
    REAL(wp), INTENT(IN) :: ys(:)
    REAL(wp) :: t, x, vx, ax
    INTEGER :: u, k, j
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, NSTEP
      t = DT*k
      CALL smooth(1.0_wp, t, x, vx, ax)
      DO j = 1, SIZE(ids)
        WRITE (u, '(F8.3,1X,I0,3ES25.16E3,A,ES25.16E3,A,ES25.16E3,A)') t, ids(j), x, ys(j), -50.0_wp, ' ', vx, &
          ' 0 0 ', ax, ' 0 0'
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_motion

  SUBROUTINE write_deck(path, types, points, lines, sections, options, outs)
    CHARACTER(*), INTENT(IN) :: path, types(:), points(:), lines(:), sections(:), options(:), outs(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'mixed-route current gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    DO i = 1, SIZE(types)
      WRITE (u, '(A)') TRIM(types(i))
    END DO
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    DO i = 1, SIZE(points)
      WRITE (u, '(A)') TRIM(points(i))
    END DO
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    DO i = 1, SIZE(lines)
      WRITE (u, '(A)') TRIM(lines(i))
    END DO
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    DO i = 1, SIZE(sections)
      WRITE (u, '(A)') TRIM(sections(i))
    END DO
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    DO i = 1, SIZE(options)
      WRITE (u, '(A)') TRIM(options(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    DO i = 1, SIZE(outs)
      WRITE (u, '(A)') TRIM(outs(i))
    END DO
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE write_case(dir, current)
    !! The three decks of a case in folder dir (ending in '/', or empty): cable.dat, a 100 m
    !! finite-EI line (40 elements) from End A on the Coupled point (0, 0, -50) to a Fixed End B
    !! at (95, 0, -60); chain.dat, a 110 m chain (20 segments) from (0, 20, -50) to a Fixed
    !! (0, 110, -100); and mixed.dat, both on their own points. current: the deck's current rows.
    CHARACTER(*), INTENT(IN) :: dir, current(:)
    CHARACTER(48) :: opts(SIZE(current) + 3)
    INTEGER :: i
    opts(1) = '0.05 dtM'
    opts(2) = '10.0 TMax'
    DO i = 1, SIZE(current)
      opts(2 + i) = current(i)
    END DO
    opts(SIZE(opts)) = 'cable_m.txt motionFile'
    CALL write_motion(dir//'cable_m.txt', [1], [0.0_wp])
    CALL write_deck(dir//'cable.dat', [CHARACTER(64) :: CAB_T], &
                    [CHARACTER(40) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 95.0 0.0 -60.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -'], [CHARACTER(24) :: '1 cab 100.0 40'], opts, CABLE_OUTS)
    opts(SIZE(opts)) = 'chain_m.txt motionFile'
    CALL write_motion(dir//'chain_m.txt', [1], [20.0_wp])
    CALL write_deck(dir//'chain.dat', [CHARACTER(64) :: CHAIN_T], &
                    [CHARACTER(40) :: '1 Coupled 0.0 20.0 -50.0 0 0 0 0', '2 Fixed 0.0 110.0 -100.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -'], [CHARACTER(24) :: '1 chain 110.0 20'], opts, CHAIN_OUTS)
    opts(SIZE(opts)) = 'mixed_m.txt motionFile'
    CALL write_motion(dir//'mixed_m.txt', [1, 3], [0.0_wp, 20.0_wp])
    CALL write_deck(dir//'mixed.dat', [CHARACTER(64) :: CAB_T, CHAIN_T], &
                    [CHARACTER(40) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 95.0 0.0 -60.0 0 0 0 0', &
                     '3 Coupled 0.0 20.0 -50.0 0 0 0 0', '4 Fixed 0.0 110.0 -100.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], &
                    opts, MIXED_OUTS)
  END SUBROUTINE write_case

  SUBROUTINE write_text(path, lines)
    CHARACTER(*), INTENT(IN) :: path, lines(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO i = 1, SIZE(lines)
      WRITE (u, '(A)') TRIM(lines(i))
    END DO
    CLOSE (u)
  END SUBROUTINE write_text

  SUBROUTINE run_driver(deck, root, ok)
    !! Run the driver executable on a deck, its stdout and stderr to <root>.log.
    CHARACTER(*), INTENT(IN) :: deck, root
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: ex, cs
    CALL EXECUTE_COMMAND_LINE('"'//TRIM(driver)//'" '//deck//' '//root//' > '//root//'.log 2>&1', &
                              WAIT=.TRUE., EXITSTAT=ex, CMDSTAT=cs)
    ok = cs == 0 .AND. ex == 0
  END SUBROUTINE run_driver

  INTEGER FUNCTION driver_exit(deck, root) RESULT(ex)
    CHARACTER(*), INTENT(IN) :: deck, root
    INTEGER :: cs
    CALL EXECUTE_COMMAND_LINE('"'//TRIM(driver)//'" '//deck//' '//root//' > '//root//'.log 2>&1', &
                              WAIT=.TRUE., EXITSTAT=ex, CMDSTAT=cs)
    IF (cs /= 0) ex = -1
  END FUNCTION driver_exit

  LOGICAL FUNCTION log_has(root, text) RESULT(found)
    CHARACTER(*), INTENT(IN) :: root, text
    CHARACTER(4096) :: line
    INTEGER :: u, ios
    found = .FALSE.
    OPEN (NEWUNIT=u, FILE=root//'.log', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (INDEX(line, text) > 0) found = .TRUE.
    END DO
    CLOSE (u)
  END FUNCTION log_has

  SUBROUTINE read_out(path, names, vals, nrow)
    !! The channel names and rows of a driver .out file (Time first).
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(32), INTENT(OUT) :: names(MAXCOL)
    REAL(wp), INTENT(OUT) :: vals(MAXROW, MAXCOL)
    INTEGER, INTENT(OUT) :: nrow
    CHARACTER(4096) :: buf
    INTEGER :: u, ios, ncol, k
    names = ''
    vals = 0.0_wp
    nrow = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    READ (buf, *, IOSTAT=ios) names
    ncol = 0
    DO k = 1, MAXCOL
      IF (LEN_TRIM(names(k)) > 0) ncol = k
    END DO
    DO
      IF (nrow == MAXROW) EXIT
      READ (u, *, IOSTAT=ios) vals(nrow + 1, 1:ncol)
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    CLOSE (u)
  END SUBROUTINE read_out

  INTEGER FUNCTION col_of(names, name) RESULT(c)
    CHARACTER(32), INTENT(IN) :: names(:)
    CHARACTER(*), INTENT(IN) :: name
    INTEGER :: k
    c = 0
    DO k = 1, SIZE(names)
      IF (TRIM(names(k)) == TRIM(name)) c = k
    END DO
  END FUNCTION col_of

  REAL(wp) FUNCTION range_error(a, b, n) RESULT(e)
    !! max |b - a| over the rows, relative to the range max |a|.
    REAL(wp), INTENT(IN) :: a(:), b(:)
    INTEGER, INTENT(IN) :: n
    e = MAXVAL(ABS(b(1:n) - a(1:n)))/MAX(MAXVAL(ABS(a(1:n))), TINY(1.0_wp))
    IF (.NOT. IEEE_IS_FINITE(e)) e = HUGE(1.0_wp)
  END FUNCTION range_error

  SUBROUTINE run_case(dir, label, ok)
    !! Run the three decks of a case (write_case) on the driver.
    CHARACTER(*), INTENT(IN) :: dir, label
    LOGICAL, INTENT(OUT) :: ok
    LOGICAL :: ok_a, ok_b, ok_c
    CALL run_driver(dir//'cable.dat', dir//'cable', ok_a)
    CALL require(ok_a, label//': the cable alone runs on the standalone cubic-Hermite route')
    CALL run_driver(dir//'chain.dat', dir//'chain', ok_b)
    CALL require(ok_b, label//': the chain alone runs on the EI = 0 route')
    CALL run_driver(dir//'mixed.dat', dir//'mixed', ok_c)
    CALL require(ok_c, label//': the mixed deck runs in the current')
    IF (ok_c) CALL require(log_has(dir//'mixed', 'mixed standalone aggregate'), &
                           label//': the mixed deck runs on the aggregate')
    ok = ok_a .AND. ok_b .AND. ok_c
  END SUBROUTINE run_case

  SUBROUTINE line_errors(nm, vm, nl, vl, first, outs_l, e_static, e_march)
    !! The mixed route's channels MIXED_OUTS(first + 1:first + 5) against a single-line route's
    !! outs_l: the largest difference at t = 0 (the static start) and over every row, each
    !! relative to the channel's range max |a| on the single-line route.
    CHARACTER(32), INTENT(IN) :: nm(:), nl(:)
    REAL(wp), INTENT(IN) :: vm(:, :), vl(:, :)
    INTEGER, INTENT(IN) :: first
    CHARACTER(16), INTENT(IN) :: outs_l(5)
    REAL(wp), INTENT(OUT) :: e_static, e_march
    INTEGER :: k, cm, cl
    REAL(wp) :: scale
    e_static = 0.0_wp
    e_march = 0.0_wp
    DO k = 1, 5
      cm = col_of(nm, MIXED_OUTS(first + k))
      cl = col_of(nl, outs_l(k))
      IF (cm == 0 .OR. cl == 0) THEN
        e_static = HUGE(1.0_wp)
        e_march = HUGE(1.0_wp)
        RETURN
      END IF
      scale = MAX(MAXVAL(ABS(vl(1:NSTEP + 1, cl))), TINY(1.0_wp))
      e_static = MAX(e_static, ABS(vm(1, cm) - vl(1, cl))/scale)
      e_march = MAX(e_march, MAXVAL(ABS(vm(1:NSTEP + 1, cm) - vl(1:NSTEP + 1, cl)))/scale)
    END DO
  END SUBROUTINE line_errors

  SUBROUTINE compare_case(dir, label, still)
    !! The mixed route (mixed.out) against the cable alone (cable.out) and the chain alone
    !! (chain.out): the static row (t = 0) and every row of the march. still: a still-water case
    !! (the baseline of the route difference; no out-of-plane offset to check).
    CHARACTER(*), INTENT(IN) :: dir, label
    LOGICAL, INTENT(IN), OPTIONAL :: still
    CHARACTER(32) :: nm(MAXCOL), na(MAXCOL), nc(MAXCOL)
    REAL(wp), ALLOCATABLE :: vm(:, :), va(:, :), vc(:, :)
    INTEGER :: rm, ra, rc, cm, cs
    REAL(wp) :: e_cable_static, e_cable, e_chain_static, e_chain
    ALLOCATE (vm(MAXROW, MAXCOL), va(MAXROW, MAXCOL), vc(MAXROW, MAXCOL))
    CALL read_out(dir//'mixed.out', nm, vm, rm)
    CALL read_out(dir//'cable.out', na, va, ra)
    CALL read_out(dir//'chain.out', nc, vc, rc)
    CALL require(rm == NSTEP + 1 .AND. ra == NSTEP + 1 .AND. rc == NSTEP + 1, label//': every route writes every row')
    IF (rm /= NSTEP + 1 .OR. ra /= NSTEP + 1 .OR. rc /= NSTEP + 1) RETURN
    CALL line_errors(nm, vm, na, va, 0, CABLE_OUTS, e_cable_static, e_cable)
    CALL line_errors(nm, vm, nc, vc, 5, CHAIN_OUTS, e_chain_static, e_chain)
    WRITE (*, '(A,A,2ES10.3,A,2ES10.3,A)') '  ', label//': driver, mixed route against single-line routes: cable ', &
      e_cable_static, e_cable, ', chain ', e_chain_static, e_chain, ' (static start, march; of each channel''s range)'
    CALL require(e_cable_static <= STATIC_TOL .AND. e_chain_static <= STATIC_TOL, &
                 label//': the static start agrees within the static tolerance')
    CALL require(e_cable <= DRIVER_CABLE_TOL, label//': the cable agrees within the deck''s Newton tolerance')
    CALL require(e_chain <= CHAIN_TOL, label//': the chain agrees within the row-1 transfer')
    ! the current is felt: both mid nodes leave the vertical plane of their chord
    IF (PRESENT(still)) THEN
      IF (still) RETURN
    END IF
    cm = col_of(nm, 'L1N21py')
    cs = col_of(nm, 'L2N11px')
    IF (cm > 0 .AND. cs > 0) THEN
      WRITE (*, '(A,A,F8.4,A,F8.4,A)') '  ', label//': static out-of-plane offset of the mid nodes: cable ', &
        vm(1, cm), ' m, chain ', vm(1, cs), ' m'
      CALL require(ABS(vm(1, cm)) > 0.02_wp .AND. ABS(vm(1, cs)) > 0.02_wp, &
                   label//': the current pushes both lines out of the plane of their chord')
    END IF
  END SUBROUTINE compare_case

  SUBROUTINE march_library(dir, label)
    !! The driver's march of the mixed deck (CableDyn_driver run_mixed_held_deck) through the
    !! aggregate library, with the cable given the standalone route's Newton controls (the deck's
    !! dynamic tolerance 1e-8, 30 iterations, the carried factor): every channel of both lines is
    !! compared at every step with the single-line routes' outputs.
    CHARACTER(*), INTENT(IN) :: dir, label
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: agg
    REAL(wp), ALLOCATABLE :: got(:, :), va(:, :), vc(:, :)
    CHARACTER(32) :: na(MAXCOL), nc(MAXCOL), ng(MAXCOL)
    CHARACTER(2048) :: em
    INTEGER :: c, ra, rc, nch, es
    REAL(wp) :: e_cable_static, e_cable, e_chain_static, e_chain
    LOGICAL :: ok
    ALLOCATE (agg, va(MAXROW, MAXCOL), vc(MAXROW, MAXCOL))
    CALL init_mixed(agg, dir//'mixed.dat', label, ok)
    IF (.NOT. ok) RETURN
    DO c = 1, agg%ncable
      agg%cables(c)%tol = 1.0e-8_wp
      agg%cables(c)%max_iter = 30
      agg%cables(c)%line%tangent_reuse = .TRUE.
    END DO
    nch = CD_AGG_NumChannels(agg)
    ALLOCATE (got(MAXROW, MAXCOL))
    got = 0.0_wp
    CALL march(agg, 0, NSTEP, got(1:NSTEP + 1, 1:nch), label, ok)
    CALL CD_AGG_End(agg, es, em)
    IF (.NOT. ok) RETURN
    CALL read_out(dir//'cable.out', na, va, ra)
    CALL read_out(dir//'chain.out', nc, vc, rc)
    CALL require(ra == NSTEP + 1 .AND. rc == NSTEP + 1, label//': the single-line outputs are complete')
    IF (ra /= NSTEP + 1 .OR. rc /= NSTEP + 1) RETURN
    ng = ''
    ng(1:SIZE(MIXED_OUTS)) = MIXED_OUTS
    CALL line_errors(ng, got, na, va, 0, CABLE_OUTS, e_cable_static, e_cable)
    CALL line_errors(ng, got, nc, vc, 5, CHAIN_OUTS, e_chain_static, e_chain)
    WRITE (*, '(A,A,2ES10.3,A,2ES10.3,A)') '  ', label//': library, the standalone Newton controls: cable ', &
      e_cable_static, e_cable, ', chain ', e_chain_static, e_chain, ' (static start, march; of each channel''s range)'
    CALL require(e_cable <= LIBRARY_CABLE_TOL, label//': with the same Newton controls the cable reproduces the '// &
                 'single-line route')
    CALL require(e_chain <= CHAIN_TOL, label//': the chain reproduces the EI = 0 route')
  END SUBROUTINE march_library
  SUBROUTINE init_mixed(agg, deck, label, ok)
    !! The aggregate as the driver's mixed route builds it, with the motion's first row installed.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    CHARACTER(*), INTENT(IN) :: deck, label
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), load(:, :), orient(:, :, :), omega(:, :), alpha(:, :)
    REAL(wp), ALLOCATABLE :: roll(:)
    CHARACTER(2048) :: em
    INTEGER :: es, n
    LOGICAL :: turns, rolls
    CALL CD_AGG_Init_From_Deck(agg, deck, DT, es, em, forbid_deck_ambient=.TRUE., run_tmax=TMAX, &
                               range_files=.TRUE., host_orientation=.TRUE., prescribed_motion=.TRUE., &
                               deck_current=.TRUE.)
    ok = es == CD_AGG_OK
    CALL require(ok, label//': the aggregate takes the deck current: '//TRIM(em))
    IF (.NOT. ok) RETURN
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (pos(3, n), vel(3, n), acc(3, n), load(3, n), orient(3, 3, n), omega(3, n), alpha(3, n), roll(n))
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em)
    IF (es == CD_AGG_OK) CALL CD_AGG_MotionKinematics(agg, 1, pos, vel, acc, orient, omega, alpha, roll, turns, &
                                                      rolls, es, em)
    IF (es == CD_AGG_OK) CALL CD_AGG_UpdateStates_Moving(agg, pos, vel, acc, es, em)
    IF (es == CD_AGG_OK) CALL CD_AGG_Refresh_Accelerations(agg, es, em)
    ok = es == CD_AGG_OK
    CALL require(ok, label//': the first motion row installs: '//TRIM(em))
  END SUBROUTINE init_mixed

  SUBROUTINE march(agg, first, last, got, label, ok)
    !! Steps first + 1 .. last of the driver's loop (step 0: the outputs only), every channel
    !! of every step into got(step + 1, :).
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    INTEGER, INTENT(IN) :: first, last
    REAL(wp), INTENT(INOUT) :: got(:, :)
    CHARACTER(*), INTENT(IN) :: label
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), orient(:, :, :), omega(:, :), alpha(:, :), roll(:)
    CHARACTER(2048) :: em
    INTEGER :: es, n, step, k, n_iter
    LOGICAL :: turns, rolls, conv, stalled
    REAL(wp) :: v
    n = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (pos(3, n), vel(3, n), acc(3, n), orient(3, 3, n), omega(3, n), alpha(3, n), roll(n))
    ok = .TRUE.
    DO step = first, last
      IF (step > first) THEN
        CALL CD_AGG_MotionKinematics(agg, step + 1, pos, vel, acc, orient, omega, alpha, roll, turns, rolls, es, em)
        IF (es == CD_AGG_OK) CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, conv, stalled, n_iter, es, em, &
                                                     t_committed=DT*step)
        IF (es /= CD_AGG_OK .OR. .NOT. conv) THEN
          CALL require(.FALSE., label//': library march step: '//TRIM(em))
          ok = .FALSE.
          RETURN
        END IF
      ELSE IF (step > 0) THEN
        ! the state of step first, recorded by the march that reached it
        CYCLE
      END IF
      CALL CD_AGG_CalcOutput(agg, es, em)
      DO k = 1, SIZE(got, 2)
        CALL CD_AGG_EvalChannel(agg, k, v, es, em)
        got(step + 1, k) = v
      END DO
    END DO
  END SUBROUTINE march

  SUBROUTINE check_option_currents()
    !! Gate 1.
    LOGICAL :: ok
    CHARACTER(32) :: nu(MAXCOL), ns(MAXCOL)
    REAL(wp), ALLOCATABLE :: vu(:, :), vs(:, :)
    INTEGER :: ru, rs
    REAL(wp) :: change
    CALL write_case('uni/', [CHARACTER(48) :: 'uniform 0.4 0.3 0 current'])
    CALL run_case('uni/', '1 uniform', ok)
    IF (ok) THEN
      CALL compare_case('uni/', '1 uniform')
      CALL march_library('uni/', '1 uniform')
    END IF
    CALL write_case('prof/', [CHARACTER(48) :: 'profile -200 0.1 0.05 0 0 0.6 0.4 0 current'])
    CALL run_case('prof/', '1 profile', ok)
    IF (ok) THEN
      CALL compare_case('prof/', '1 profile')
      CALL march_library('prof/', '1 profile')
    END IF
    ! the same mixed deck in still water: the current changes the chain's tension history
    CALL write_case('still/', [CHARACTER(48) :: 'none current'])
    CALL run_case('still/', '1 still water', ok)
    IF (ok) THEN
      CALL compare_case('still/', '1 still water', still=.TRUE.)
      CALL march_library('still/', '1 still water')
    END IF
    ALLOCATE (vu(MAXROW, MAXCOL), vs(MAXROW, MAXCOL))
    CALL read_out('uni/mixed.out', nu, vu, ru)
    CALL read_out('still/mixed.out', ns, vs, rs)
    IF (ru == NSTEP + 1 .AND. rs == NSTEP + 1) THEN
      change = range_error(vs(:, col_of(ns, 'FairTen2')), vu(:, col_of(nu, 'FairTen2')), rs)
      WRITE (*, '(A,ES10.3,A)') '  1 still water: the uniform current changes the chain fairlead tension by ', change, &
        ' of its range'
      CALL require(change > 1.0e-3_wp, '1: the mixed route applies the current to the chain')
      change = MAXVAL(ABS(vs(1:rs, col_of(ns, 'L1N21py'))))
      CALL require(change < 1.0e-9_wp, '1: in still water the cable stays in its plane')
    ELSE
      CALL require(.FALSE., '1: the still-water and uniform-current outputs are complete')
    END IF
  END SUBROUTINE check_option_currents

  SUBROUTINE write_c1(dir, uniform)
    !! current_profile.txt: a sheared profile across both lines, or the uniform (0.4, 0.3, 0).
    CHARACTER(*), INTENT(IN) :: dir
    LOGICAL, INTENT(IN) :: uniform
    IF (uniform) THEN
      CALL write_text(dir//'current_profile.txt', [CHARACTER(40) :: 'uniform current', 'z ux uy uz', &
                                                   '-200.0 0.4 0.3 0.0', '0.0 0.4 0.3 0.0'])
    ELSE
      CALL write_text(dir//'current_profile.txt', [CHARACTER(40) :: 'sheared current', 'z ux uy uz', &
                                                   '-200.0 0.05 0.02 0.0', '-80.0 0.3 0.2 0.01', &
                                                   '-40.0 0.5 0.35 0.0', '0.0 0.7 0.5 0.0'])
    END IF
  END SUBROUTINE write_c1

  SUBROUTINE write_c2(dir, kind)
    !! current_profile_dynamic.txt at the depths -200, -80, -40, 0 m: kind 1 the three samples
    !! 0, 2, 4 s (the first and last equal, so the field repeats with period 6 s past 4 s),
    !! kind 2 the same table unrolled to 12 s, kind 3 the same table held from 4 s to 12 s.
    CHARACTER(*), INTENT(IN) :: dir
    INTEGER, INTENT(IN) :: kind
    CHARACTER(*), PARAMETER :: A = ' 0.10 0.15 0.20 0.25 0.05 0.08 0.10 0.12', &
                               B = ' 0.40 0.50 0.60 0.70 0.30 0.35 0.40 0.45'
    CHARACTER(96) :: rows(7)
    INTEGER :: n
    SELECT CASE (kind)
    CASE (1)
      rows(1:3) = [CHARACTER(96) :: '0.0'//A, '2.0'//B, '4.0'//A]
      n = 3
    CASE (2)
      rows = [CHARACTER(96) :: '0.0'//A, '2.0'//B, '4.0'//A, '6.0'//A, '8.0'//B, '10.0'//A, '12.0'//A]
      n = 7
    CASE DEFAULT
      rows(1:4) = [CHARACTER(96) :: '0.0'//A, '2.0'//B, '4.0'//A, '12.0'//A]
      n = 4
    END SELECT
    CALL write_text(dir//'current_profile_dynamic.txt', [CHARACTER(96) :: 'time-varying sheared current', &
                                     'across both lines', '', '', '-200.0 -80.0 -40.0 0.0', 't ux... uy...', rows(1:n)])
  END SUBROUTINE write_c2

  SUBROUTINE write_c5(dir, uniform)
    !! current_profile_4d.txt: x in {-10, 110}, y in {-10, 120}, z in {-210, -100, 0} and t in
    !! {0, 3, 6} with u varying in each (sheared, turning across the lines and past its last
    !! sample: the march to 10 s wraps it), or the uniform (0.4, 0.3, 0) at t = 0 and 1.
    CHARACTER(*), INTENT(IN) :: dir
    LOGICAL, INTENT(IN) :: uniform
    REAL(wp), PARAMETER :: XS(2) = [-10.0_wp, 110.0_wp], YS(2) = [-10.0_wp, 120.0_wp], &
                           ZS(3) = [-210.0_wp, -100.0_wp, 0.0_wp], TS(3) = [0.0_wp, 3.0_wp, 6.0_wp]
    INTEGER :: u, ix, iy, iz, it, nt
    REAL(wp) :: ux, uy, s
    OPEN (NEWUNIT=u, FILE=dir//'current_profile_4d.txt', STATUS='REPLACE', ACTION='WRITE')
    nt = MERGE(2, 3, uniform)
    WRITE (u, '(A,I0)') '2 2 3 ', nt
    WRITE (u, '(A)') '-10.0 110.0'
    WRITE (u, '(A)') '-10.0 120.0'
    WRITE (u, '(A)') '-210.0 -100.0 0.0'
    IF (uniform) THEN
      WRITE (u, '(A)') '0.0 1.0'
    ELSE
      WRITE (u, '(A)') '0.0 3.0 6.0'
    END IF
    WRITE (u, '(A)') 'x y z t ux uy uz'
    DO it = 1, nt
      DO iz = 1, 3
        DO iy = 1, 2
          DO ix = 1, 2
            IF (uniform) THEN
              ux = 0.4_wp
              uy = 0.3_wp
            ELSE
              s = 1.0_wp + ZS(iz)/250.0_wp
              ux = s*(0.3_wp + 0.002_wp*XS(ix) + 0.001_wp*YS(iy))*MERGE(1.0_wp, 1.6_wp, it /= 2)
              uy = s*(0.2_wp + 0.001_wp*XS(ix) - 0.001_wp*YS(iy) + 0.1_wp*(it - 1))
            END IF
            WRITE (u, '(4F10.3,3F12.6)') XS(ix), YS(iy), ZS(iz), MERGE(REAL(it - 1, wp), TS(it), uniform), ux, uy, &
              MERGE(0.0_wp, 0.01_wp*s, uniform)
          END DO
        END DO
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_c5

  SUBROUTINE check_moordyn_c_currents()
    !! Gate 2.
    LOGICAL :: ok
    CALL write_case('c1/', [CHARACTER(48) :: '1 Currents'])
    CALL write_c1('c1/', .FALSE.)
    CALL run_case('c1/', '2 Currents 1', ok)
    IF (ok) CALL compare_case('c1/', '2 Currents 1')
    CALL write_case('c2/', [CHARACTER(48) :: '2 Currents'])
    CALL write_c2('c2/', 1)
    CALL run_case('c2/', '2 Currents 2', ok)
    IF (ok) THEN
      CALL compare_case('c2/', '2 Currents 2')
      CALL march_library('c2/', '2 Currents 2')
    END IF
    CALL write_case('c5/', [CHARACTER(48) :: '5 Currents'])
    CALL write_c5('c5/', .FALSE.)
    CALL run_case('c5/', '2 Currents 5', ok)
    IF (ok) THEN
      CALL compare_case('c5/', '2 Currents 5')
      CALL march_library('c5/', '2 Currents 5')
    END IF
  END SUBROUTINE check_moordyn_c_currents

  REAL(wp) FUNCTION outs_difference(root_a, root_b, from_row, to_row) RESULT(e)
    !! max over the mixed channels and the rows from_row..to_row of |b - a| relative to each
    !! channel's range in a (HUGE when an output is incomplete).
    CHARACTER(*), INTENT(IN) :: root_a, root_b
    INTEGER, INTENT(IN) :: from_row, to_row
    CHARACTER(32) :: na(MAXCOL), nb(MAXCOL)
    REAL(wp), ALLOCATABLE :: va(:, :), vb(:, :)
    INTEGER :: ra, rb, k, ca, cb
    REAL(wp) :: scale
    ALLOCATE (va(MAXROW, MAXCOL), vb(MAXROW, MAXCOL))
    CALL read_out(root_a//'.out', na, va, ra)
    CALL read_out(root_b//'.out', nb, vb, rb)
    e = HUGE(1.0_wp)
    IF (ra /= NSTEP + 1 .OR. rb /= NSTEP + 1) RETURN
    e = 0.0_wp
    DO k = 1, SIZE(MIXED_OUTS)
      ca = col_of(na, MIXED_OUTS(k))
      cb = col_of(nb, MIXED_OUTS(k))
      IF (ca == 0 .OR. cb == 0) THEN
        e = HUGE(1.0_wp)
        RETURN
      END IF
      scale = MAXVAL(ABS(va(1:ra, ca)))
      e = MAX(e, MAXVAL(ABS(vb(from_row:to_row, cb) - va(from_row:to_row, ca)))/MAX(scale, TINY(1.0_wp)))
    END DO
  END FUNCTION outs_difference

  SUBROUTINE check_wrap()
    !! Gate 3: the Currents 2 table of gate 2 (c2/) against it unrolled (c2u/) and held (c2h/).
    LOGICAL :: ok
    REAL(wp) :: e_unrolled, e_held, e_early
    CHARACTER(32) :: na(MAXCOL), nb(MAXCOL)
    REAL(wp), ALLOCATABLE :: va(:, :), vb(:, :)
    INTEGER :: ra, rb, c
    CALL write_case('c2u/', [CHARACTER(48) :: '2 Currents'])
    CALL write_c2('c2u/', 2)
    CALL run_driver('c2u/mixed.dat', 'c2u/mixed', ok)
    CALL require(ok, '3: the mixed deck runs with the unrolled table')
    CALL write_case('c2h/', [CHARACTER(48) :: '2 Currents'])
    CALL write_c2('c2h/', 3)
    CALL run_driver('c2h/mixed.dat', 'c2h/mixed', ok)
    CALL require(ok, '3: the mixed deck runs with the held table')
    e_unrolled = outs_difference('c2/mixed', 'c2u/mixed', 1, NSTEP + 1)
    ALLOCATE (va(MAXROW, MAXCOL), vb(MAXROW, MAXCOL))
    CALL read_out('c2/mixed.out', na, va, ra)
    CALL read_out('c2h/mixed.out', nb, vb, rb)
    e_held = 0.0_wp
    e_early = HUGE(1.0_wp)
    IF (ra == NSTEP + 1 .AND. rb == NSTEP + 1) THEN
      c = col_of(na, 'FairTen2')
      e_early = MAXVAL(ABS(vb(1:121, c) - va(1:121, c)))/(MAXVAL(va(1:ra, c)) - MINVAL(va(1:ra, c)))
      e_held = MAXVAL(ABS(vb(122:rb, c) - va(122:ra, c)))/(MAXVAL(va(1:ra, c)) - MINVAL(va(1:ra, c)))
    END IF
    WRITE (*, '(A,ES10.3,A)') '  3 wrap: the wrapped and the unrolled table differ by ', e_unrolled, &
      ' of each channel''s range'
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') '  3 wrap: the held table differs from the wrapped one by ', e_early, &
      ' up to 6 s and by ', e_held, ' after it (chain tension, of its range)'
    CALL require(e_unrolled <= SAME_TOL, '3: past its last sample the march takes the table repeated')
    CALL require(e_early <= SAME_TOL, '3: the held table is the same field up to 6 s')
    CALL require(e_held > 0.01_wp, '3: the wrap changes the march after 6 s')
  END SUBROUTINE check_wrap

  SUBROUTINE check_uniform_writings()
    !! Gate 4: a uniform Currents 5 grid and a uniform Currents 1 profile against OPTION uniform.
    LOGICAL :: ok
    REAL(wp) :: e5, e1, e5_static
    CALL write_case('c5u/', [CHARACTER(48) :: '5 Currents'])
    CALL write_c5('c5u/', .TRUE.)
    CALL run_driver('c5u/mixed.dat', 'c5u/mixed', ok)
    CALL require(ok, '4: the mixed deck runs in a uniform Currents 5 grid')
    CALL write_case('c1u/', [CHARACTER(48) :: '1 Currents'])
    CALL write_c1('c1u/', .TRUE.)
    CALL run_driver('c1u/mixed.dat', 'c1u/mixed', ok)
    CALL require(ok, '4: the mixed deck runs in a uniform Currents 1 profile')
    e5 = outs_difference('uni/mixed', 'c5u/mixed', 1, NSTEP + 1)
    e5_static = outs_difference('uni/mixed', 'c5u/mixed', 1, 1)
    e1 = outs_difference('uni/mixed', 'c1u/mixed', 1, NSTEP + 1)
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A)') '  4 uniform field: Currents 5 grid ', e5, ' (static start ', &
      e5_static, '), Currents 1 profile ', e1, ' of each channel''s range from OPTION uniform'
    ! the grid's trilinear weights and the profile's linear ones reproduce the uniform field to
    ! round-off, which the march carries
    CALL require(e5_static == 0.0_wp .AND. e5 <= GRID_TOL, '4: a uniform Currents 5 grid is OPTION uniform')
    CALL require(e1 <= GRID_TOL, '4: a uniform Currents 1 profile is OPTION uniform')
  END SUBROUTINE check_uniform_writings

  SUBROUTINE check_snapshot(deck, label)
    !! Gate 5 on a mixed deck (the Newton controls of the coupled route): the correction rewind of
    !! the OpenFAST shell (CD_AGG_Snapshot at the start of a step, the step, CD_AGG_Restore, the
    !! step again) every 20th step of the march, against the march without rewinds.
    CHARACTER(*), INTENT(IN) :: deck, label
    TYPE(CD_AGG_ModuleType), ALLOCATABLE :: a, b
    REAL(wp), ALLOCATABLE :: ga(:, :), gb(:, :), gp(:, :)
    INTEGER, PARAMETER :: EVERY = 20
    INTEGER :: es, nch, step, n_rewind
    CHARACTER(2048) :: em
    LOGICAL :: ok
    REAL(wp) :: e_pre, e_post
    ALLOCATE (a, b)
    CALL init_mixed(a, deck, label//' uninterrupted', ok)
    IF (.NOT. ok) RETURN
    nch = CD_AGG_NumChannels(a)
    ALLOCATE (ga(NSTEP + 1, nch), gb(NSTEP + 1, nch), gp(NSTEP + 1, nch))
    ga = 0.0_wp
    gb = 0.0_wp
    gp = 0.0_wp
    CALL march(a, 0, NSTEP, ga, label//' uninterrupted', ok)
    CALL CD_AGG_End(a, es, em)
    IF (.NOT. ok) RETURN
    CALL init_mixed(b, deck, label//' rewound', ok)
    IF (.NOT. ok) RETURN
    CALL march(b, 0, 0, gb, label//' rewound', ok)
    n_rewind = 0
    DO step = 1, NSTEP
      IF (MOD(step, EVERY) == 0) THEN
        CALL CD_AGG_Snapshot(b, es, em)
        CALL require(es == CD_AGG_OK, label//': snapshot: '//TRIM(em))
        CALL march(b, step - 1, step, gp, label//' before the rewind', ok)
        IF (.NOT. ok) EXIT
        CALL CD_AGG_Restore(b, es, em)
        CALL require(es == CD_AGG_OK, label//': restore: '//TRIM(em))
        n_rewind = n_rewind + 1
      END IF
      CALL march(b, step - 1, step, gb, label//' rewound', ok)
      IF (.NOT. ok) EXIT
    END DO
    CALL CD_AGG_End(b, es, em)
    IF (.NOT. ok) RETURN
    e_pre = 0.0_wp
    DO step = EVERY, NSTEP, EVERY
      e_pre = MAX(e_pre, MAXVAL(ABS(gp(step + 1, :) - ga(step + 1, :))))
    END DO
    e_post = MAXVAL(ABS(gb - ga))
    WRITE (*, '(A,I0,A,ES10.3,A,ES10.3)') '  '//label//': ', n_rewind, ' rewinds; largest difference from the '// &
      'march without them: the rewound steps ', e_pre, ', the march after them ', e_post
    CALL require(n_rewind == NSTEP/EVERY .AND. e_pre == 0.0_wp .AND. e_post == 0.0_wp, &
                 label//': a step repeated after a restore is the uninterrupted march, bit for bit')
  END SUBROUTINE check_snapshot

  SUBROUTINE check_refusals()
    !! Gate 6.
    INTEGER :: ex
    LOGICAL :: named
    CALL write_case('wav/', [CHARACTER(48) :: 'airy 2 8 0 waves'])
    ex = driver_exit('wav/mixed.dat', 'wav/mixed')
    named = log_has('wav/mixed', 'the deck waves OPTION is not supported for a standalone mixed')
    CALL require(ex == 1 .AND. named, &
                 '6: deck waves on the mixed deck are refused by name')
    CALL write_case('c2d/', [CHARACTER(48) :: '2 Currents', 'uniform 0.4 0.3 0 current'])
    CALL write_c2('c2d/', 1)
    ex = driver_exit('c2d/mixed.dat', 'c2d/mixed')
    named = log_has('c2d/mixed', 'double-counting')
    CALL require(ex == 1 .AND. named, &
                 '6: a current OPTION beside Currents 2 is refused as double counting')
    CALL write_deck('nodt_mixed.dat', [CHARACTER(64) :: CAB_T, CHAIN_T], &
                    [CHARACTER(40) :: '1 Coupled 0.0 0.0 -50.0 0 0 0 0', '2 Fixed 95.0 0.0 -60.0 0 0 0 0', &
                     '3 Coupled 0.0 20.0 -50.0 0 0 0 0', '4 Fixed 0.0 110.0 -100.0 0 0 0 0'], &
                    [CHARACTER(16) :: '1 1 2 -', '2 3 4 -'], [CHARACTER(24) :: '1 cab 100.0 40', '2 chain 110.0 20'], &
                    [CHARACTER(48) :: 'uniform 0.4 0.3 0 current'], MIXED_OUTS)
    ex = driver_exit('nodt_mixed.dat', 'nodt_mixed')
    named = log_has('nodt_mixed', 'standalone OPTION current requires dtM and TMax')
    CALL require(ex == 1 .AND. named, &
                 '6: a current without dtM is refused as on the single-line routes')
  END SUBROUTINE check_refusals

END PROGRAM test_mixed_route_currents
