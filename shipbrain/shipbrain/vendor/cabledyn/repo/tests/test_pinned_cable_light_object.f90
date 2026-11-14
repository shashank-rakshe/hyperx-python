! File: tests/test_pinned_cable_light_object.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> Gates of a finite-EI (cubic-Hermite) cable pinned to a light object on the standalone
!> monolithic multibody march. The deck: a 10 m, 1 m diameter buoyant free rod spar (3 t dry,
!> 8 t displaced) on four taut EI = 0 legs in 50 m of water, and a finite-EI cable (EA 5e8 N,
!> EI 2e4 N m^2, 40 elements over 55 m) pinned at a rod end and run to an anchor. The static
!> passes balance the rod on the cubic-Hermite cable, so the start is the march's equilibrium,
!> and a stable one. The monolithic step coupled such a pinned cable at the Newmark predictor
!> (stepped once with the predicted end motion, its end force held): the cable's dynamic end
!> stiffness against the rod's few tonnes made that explicit coupling unstable (K_e dt^2 / m_e
!> above about 0.85), the step change of the cable tension alternated in sign and grew 2.3
!> times per step, and the rod fell over. A pinned cable on a moving object is now re-stepped
!> at every outer iteration with its end stiffness in the Newton matrix, as a clamped one is.
!> Positions are written to 8 digits (1e-6 m at the rod's 20 to 30 m depths).
!>  H  hold: the static start stays at rest over 2 s with the cable pinned at the upper and at
!>     the lower rod end: rod end move at most 1e-5 m and the cable end tensions within 1e-5 of
!>     the larger (measured 1e-10 and 1.8e-10 m, 2.7e-8 and 3.4e-8); in a 0.5 m/s current at
!>     most 2e-3 m and 1e-3 (measured 6.3e-4 m and 1.2e-4: a slow swing of the start in the
!>     current, the same on the staggered scheme). The old coupling: rod end moves of 6.3, 5.4
!>     and 6.5 m, tension changes of 161, 472 and 5596 times the start tension;
!>  D  the cable written from its anchor is turned around to start at the rod end and writes
!>     the same output (byte for byte); a cable from a fixed rod's end to the free rod's end
!>     (an End B on the moving object) holds to 1e-5 m and its tension to 1e-4 (measured 2e-7
!>     m and 9e-8; old: 6.1 m, 1190 times). That cable's End A (the fixed rod's end) lies on
!>     the seabed below its End B: its catenary seed is laid from End A, the line seen from
!>     its other end. Before, the catenary route refused it (fairlead on the bed) and the
!>     mesh-sequenced route took over, whose branch depended on platform round-off: Linux
!>     gfortran reached a kinked state (max h kappa 1.96) and failed the deck, Windows the
!>     cable's equilibrium;
!>  R  the static start of that deck with the fixed rod moved by 1 ulp in x either way or by
!>     1e-12 m up is the same rod pose to 1e-9 m;
!>  B  a light Rigid6 buoy (4 t) with a pinned keel cable holds over 4 s (move at most 1e-5 m,
!>     tension within 1e-5; measured 1e-9 m and 3.3e-8; old: 0.22 m, 38 times);
!>  S  second route: the staggered scheme, whose sub-stepped central difference resolves the
!>     same coupling, gives the same rod motion (within 1e-5 m) and cable tensions (within 1e-5
!>     of the larger) as the monolithic step, the cable at the upper and at the lower rod end
!>     (measured 1e-10 and 1.7e-10 m; old: 6.0 and 6.5 m apart);
!>  E  controls of the routes coupled implicitly before: the same deck with an EI = 0 cable
!>     holds its static start to 1e-6 m, and the cable clamped (Rigid) at the upper or lower
!>     rod end to 1e-5 m.
PROGRAM test_pinned_cable_light_object
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  INTEGER :: n_fail = 0
  REAL(wp) :: mv_m, ten_m

  CALL check_hold('upper', 'pcl_upper', .FALSE., 1.0e-5_wp, 1.0e-5_wp)
  CALL check_hold('upper', 'pcl_current', .TRUE., 2.0e-3_wp, 1.0e-3_wp)
  CALL check_hold('lower', 'pcl_lower', .FALSE., 1.0e-5_wp, 1.0e-5_wp)
  CALL check_reversed()
  CALL check_hold('fixrod', 'pcl_fixrod', .FALSE., 1.0e-5_wp, 1.0e-4_wp)
  CALL check_fixrod_roundoff()
  CALL check_buoy()
  CALL check_staggered('upper', 'pcl_upper')
  CALL check_staggered('lower', 'pcl_lower')
  CALL check_hold('upper', 'pcl_ei0', .FALSE., 1.0e-6_wp, 1.0e-6_wp, ei0=.TRUE.)
  CALL check_hold('upper', 'pcl_clamp_up', .FALSE., 1.0e-5_wp, 1.0e-4_wp, clamp='1.0')
  CALL check_hold('lower', 'pcl_clamp_lo', .FALSE., 1.0e-5_wp, 1.0e-4_wp, clamp='-1.0')
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' gate(s) of a pinned cable on a light object failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: a finite-EI cable pinned to a light object (hold, direction, buoy, staggered '// &
    'route, EI = 0 and clamped controls)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  SUBROUTINE run_deck(path, root, ok, em)
    CHARACTER(*), INTENT(IN) :: path, root
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(*), INTENT(OUT) :: em
    LOGICAL :: conv
    INTEGER :: es
    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
  END SUBROUTINE run_deck

  SUBROUTINE read_rows(path, vals, nrow, ok)
    !! Every data row of a driver .out file (two header lines) into vals(:, 1:nrow).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: vals(:, :)
    INTEGER, INTENT(OUT) :: nrow
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: u, ios
    CHARACTER(512) :: buf
    nrow = 0
    vals = 0.0_wp
    ok = .FALSE.
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO WHILE (nrow < SIZE(vals, 2))
      READ (u, *, IOSTAT=ios) vals(:, nrow + 1)
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    CLOSE (u)
    ok = nrow > 0 .AND. ALL(IEEE_IS_FINITE(vals(:, 1:nrow)))
  END SUBROUTINE read_rows

  LOGICAL FUNCTION same_text(p1, p2) RESULT(same)
    !! The two files have the same lines.
    CHARACTER(*), INTENT(IN) :: p1, p2
    INTEGER :: u1, u2, i1, i2
    CHARACTER(1024) :: b1, b2
    same = .FALSE.
    OPEN (NEWUNIT=u1, FILE=p1, STATUS='OLD', ACTION='READ', IOSTAT=i1)
    IF (i1 /= 0) RETURN
    OPEN (NEWUNIT=u2, FILE=p2, STATUS='OLD', ACTION='READ', IOSTAT=i2)
    IF (i2 /= 0) THEN
      CLOSE (u1)
      RETURN
    END IF
    DO
      READ (u1, '(A)', IOSTAT=i1) b1
      READ (u2, '(A)', IOSTAT=i2) b2
      IF (i1 /= 0 .OR. i2 /= 0) EXIT
      IF (b1 /= b2) EXIT
    END DO
    same = i1 < 0 .AND. i2 < 0
    CLOSE (u1)
    CLOSE (u2)
  END FUNCTION same_text

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_spar_deck(path, cable_at, current, scheme, ei0, clamp, from_anchor, rod2_a, tmax)
    !! The free rod spar between z = -30 m (End A) and -20 m (End B) on four taut EI = 0 legs
    !! (from End A to anchors 25 m up- and downstream, from End B to anchors 30 m to either side)
    !! and the finite-EI cable (line 5, 55 m) to the anchor (-40, 0, -50): from the rod's upper
    !! end (cable_at 'upper'), its lower end ('lower'), or from the end of a fixed rod at that
    !! anchor to the upper end ('fixrod', End B on the free rod). current: 0.5 m/s in +X;
    !! scheme: bodyScheme; ei0: the cable without bending stiffness; clamp: a Rigid End A
    !! connection along the rod axis (EzZ given); from_anchor: line 5 written from the anchor;
    !! rod2_a: the fixed rod's End A (default the anchor; its End B 1 m above); tmax: TMax
    !! (default 2 s).
    CHARACTER(*), INTENT(IN) :: path, cable_at, scheme, clamp
    LOGICAL, INTENT(IN) :: current, ei0, from_anchor
    REAL(wp), INTENT(IN), OPTIONAL :: rod2_a(3)
    CHARACTER(*), INTENT(IN), OPTIONAL :: tmax
    INTEGER :: u
    CHARACTER(8) :: rod_end
    REAL(wp) :: r2(3)
    r2 = [-40.0_wp, 0.0_wp, -50.0_wp]
    IF (PRESENT(rod2_a)) r2 = rod2_a
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'free rod spar with a finite-EI cable pinned at a rod end'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.10 10.0 2.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    IF (ei0) THEN
      WRITE (u, '(A)') 'cab 0.20 60.0 5.0e8 -1.0 0.0 1.2 0.0 1.0 0.0'
    ELSE
      WRITE (u, '(A)') 'cab 0.20 60.0 5.0e8 -1.0 2.0e4 1.2 0.0 1.0 0.0'
    END IF
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'spar 1.0 300.0 0.8 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 spar Free 0.0 0.0 -30.0 0.0 0.0 -20.0 1 -'
    IF (cable_at == 'fixrod') WRITE (u, '(A,6(ES24.16,1X),A)') '2 spar Fixed ', r2, r2 + [0.0_wp, 0.0_wp, 1.0_wp], &
      ' 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.0 0.0 -30.0 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 0.0 0.0 -20.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed 25.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -25.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed 0.0 30.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed 0.0 -30.0 -50.0 0 0 0 0'
    IF (cable_at == 'fixrod') THEN
      WRITE (u, '(A,3(ES24.16,1X),A)') '7 Rod2A ', r2, ' 0 0 0 0'
    ELSE
      WRITE (u, '(A)') '7 Fixed -40.0 0.0 -50.0 0 0 0 0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 1 4 -'
    WRITE (u, '(A)') '3 2 5 -'
    WRITE (u, '(A)') '4 2 6 -'
    rod_end = MERGE('1', '2', cable_at == 'lower')
    IF (from_anchor .OR. cable_at == 'fixrod') THEN
      WRITE (u, '(A)') '5 7 '//TRIM(rod_end)//' -'
    ELSE
      WRITE (u, '(A)') '5 '//TRIM(rod_end)//' 7 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 31.95 16'
    WRITE (u, '(A)') '2 poly 31.95 16'
    WRITE (u, '(A)') '3 poly 42.40 20'
    WRITE (u, '(A)') '4 poly 42.40 20'
    WRITE (u, '(A)') '5 cab 55.0 40'
    IF (LEN_TRIM(clamp) > 0) THEN
      WRITE (u, '(A)') '--- END CONNECTIONS ---'
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
      WRITE (u, '(A)') '5 A Rigid 0.0 0.0 '//TRIM(clamp)
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '0.01 dtM'
    IF (PRESENT(tmax)) THEN
      WRITE (u, '(A)') tmax//' TMax'
    ELSE
      WRITE (u, '(A)') '2.0 TMax'
    END IF
    WRITE (u, '(A)') 'static bodyIC'
    WRITE (u, '(A)') scheme//' bodyScheme'
    WRITE (u, '(A)') '0.4 rhoInf'
    IF (current) WRITE (u, '(A)') 'uniform 0.5 0.0 0.0 current'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1px Point1pz Point2px Point2pz FairTen5 AnchTen5'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_spar_deck

  SUBROUTINE spar_measures(root, mv, ten, ok)
    !! The largest rod end move from the start and the largest change of the cable's end
    !! tensions from their start over the run, relative to the larger start tension.
    CHARACTER(*), INTENT(IN) :: root
    REAL(wp), INTENT(OUT) :: mv, ten
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: rows(7, 400)
    INTEGER :: n, k
    CALL read_rows(TRIM(root)//'.out', rows, n, ok)
    mv = HUGE(1.0_wp)
    ten = HUGE(1.0_wp)
    IF (.NOT. ok) RETURN
    mv = 0.0_wp
    ten = 0.0_wp
    DO k = 1, n
      mv = nan_max_abs([mv, NORM2(rows(2:3, k) - rows(2:3, 1)), NORM2(rows(4:5, k) - rows(4:5, 1))])
      ten = nan_max_abs([ten, (rows(6:7, k) - rows(6:7, 1))/MAXVAL(rows(6:7, 1))])
    END DO
  END SUBROUTINE spar_measures

  SUBROUTINE check_hold(cable_at, root, current, mv_tol, ten_tol, ei0, clamp)
    !! H / D / E. The spar deck (cable_at, current, ei0, clamp as in write_spar_deck) holds its
    !! static start: rod end move at most mv_tol, cable tension change at most ten_tol relative.
    CHARACTER(*), INTENT(IN) :: cable_at, root
    LOGICAL, INTENT(IN) :: current
    REAL(wp), INTENT(IN) :: mv_tol, ten_tol
    LOGICAL, INTENT(IN), OPTIONAL :: ei0
    CHARACTER(*), INTENT(IN), OPTIONAL :: clamp
    LOGICAL :: ok, e0
    CHARACTER(1024) :: em
    CHARACTER(8) :: cl
    e0 = .FALSE.
    IF (PRESENT(ei0)) e0 = ei0
    cl = ''
    IF (PRESENT(clamp)) cl = clamp
    CALL write_spar_deck(root//'.dat', cable_at, current, 'monolithic', e0, cl, .FALSE.)
    CALL run_deck(root//'.dat', root, ok, em)
    CALL require(ok, root//': the spar deck runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL spar_measures(root, mv_m, ten_m, ok)
    CALL require(ok, root//': output readable')
    IF (.NOT. ok) RETURN
    WRITE (*, '(A,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A)') root, ': rod end move ', mv_m, ' m (tol ', mv_tol, &
      '), cable tension change ', ten_m, ' (tol ', ten_tol, ')'
    CALL require(mv_m <= mv_tol, root//': the rod holds its static start')
    CALL require(ten_m <= ten_tol, root//': the cable tension holds')
  END SUBROUTINE check_hold

  SUBROUTINE check_reversed()
    !! D. Line 5 written from its anchor to the upper rod end runs as the deck written from the
    !!    rod end (the line is turned around): the same output, byte for byte.
    LOGICAL :: ok
    CHARACTER(1024) :: em
    CALL write_spar_deck('pcl_reversed.dat', 'upper', .FALSE., 'monolithic', .FALSE., '', .TRUE.)
    CALL run_deck('pcl_reversed.dat', 'pcl_reversed', ok, em)
    CALL require(ok, 'D: the reversed spar deck runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    ok = same_text('pcl_reversed.out', 'pcl_upper.out')
    WRITE (*, '(A,L1)') 'D: cable written from its anchor writes the same output: ', ok
    CALL require(ok, 'D: the cable written from its anchor writes the same output as from the rod end')
  END SUBROUTINE check_reversed

  SUBROUTINE check_fixrod_roundoff()
    !! R. The fixed-rod-to-free-rod cable of D, its End A on the seabed below End B: its static
    !!    start with the fixed rod moved by 1 ulp in x either way and by 1e-12 m up is the
    !!    same rod pose to 1e-9 m.
    REAL(wp), PARAMETER :: X0 = -40.0_wp, Z0 = -50.0_wp
    REAL(wp) :: r2(3, 3), rows(7, 4), p0(4), dmax
    INTEGER :: k, n
    LOGICAL :: ok
    CHARACTER(1024) :: em
    CHARACTER(24) :: root
    r2(:, 1) = [NEAREST(X0, 1.0_wp), 0.0_wp, Z0]
    r2(:, 2) = [NEAREST(X0, -1.0_wp), 0.0_wp, Z0]
    r2(:, 3) = [X0, 0.0_wp, Z0 + 1.0e-12_wp]
    CALL write_spar_deck('pcl_fixrod_r0.dat', 'fixrod', .FALSE., 'monolithic', .FALSE., '', .FALSE., tmax='0.0')
    CALL run_deck('pcl_fixrod_r0.dat', 'pcl_fixrod_r0', ok, em)
    CALL require(ok, 'R: the fixed-rod deck static start runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_rows('pcl_fixrod_r0.out', rows, n, ok)
    CALL require(ok, 'R: static row written')
    IF (.NOT. ok) RETURN
    p0 = rows(2:5, 1)
    dmax = 0.0_wp
    DO k = 1, 3
      WRITE (root, '(A,I0)') 'pcl_fixrod_r', k
      CALL write_spar_deck(TRIM(root)//'.dat', 'fixrod', .FALSE., 'monolithic', .FALSE., '', .FALSE., &
                           rod2_a=r2(:, k), tmax='0.0')
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok, em)
      CALL require(ok, 'R: '//TRIM(root)//' (the fixed rod moved by round-off) runs: '//TRIM(em))
      IF (.NOT. ok) RETURN
      CALL read_rows(TRIM(root)//'.out', rows, n, ok)
      CALL require(ok, 'R: '//TRIM(root)//' static row written')
      IF (.NOT. ok) RETURN
      dmax = MAX(dmax, MAXVAL(ABS(rows(2:5, 1) - p0)))
    END DO
    WRITE (*, '(A,ES10.3,A)') 'R: fixed rod moved by 1 ulp or 1e-12 m: rod pose change ', dmax, ' m'
    CALL require(dmax <= 1.0e-9_wp, 'R: the fixed rod moved by round-off gives the same static start')
  END SUBROUTINE check_fixrod_roundoff

  SUBROUTINE check_staggered(cable_at, mono_root)
    !! S. The spar deck (cable_at) on the staggered scheme: rod end positions within 1e-5 m and
    !!    the cable end tensions within 1e-5 of the larger start tension of the monolithic
    !!    step's (run mono_root) at every output step.
    CHARACTER(*), INTENT(IN) :: cable_at, mono_root
    REAL(wp) :: rm(7, 400), rs(7, 400), dp, dt_rel
    INTEGER :: nm, ns, k
    LOGICAL :: ok, ok2
    CHARACTER(1024) :: em
    CALL write_spar_deck('pcl_stag_'//cable_at//'.dat', cable_at, .FALSE., 'staggered', .FALSE., '', .FALSE.)
    CALL run_deck('pcl_stag_'//cable_at//'.dat', 'pcl_stag_'//cable_at, ok, em)
    CALL require(ok, 'S: the staggered spar deck runs ('//cable_at//'): '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_rows(mono_root//'.out', rm, nm, ok)
    CALL read_rows('pcl_stag_'//cable_at//'.out', rs, ns, ok2)
    CALL require(ok .AND. ok2 .AND. nm == ns, 'S: both outputs readable with the same rows ('//cable_at//')')
    IF (.NOT. (ok .AND. ok2 .AND. nm == ns)) RETURN
    dp = 0.0_wp
    dt_rel = 0.0_wp
    DO k = 1, nm
      dp = nan_max_abs([dp, rm(2:5, k) - rs(2:5, k)])
      dt_rel = nan_max_abs([dt_rel, (rm(6:7, k) - rs(6:7, k))/MAXVAL(rs(6:7, 1))])
    END DO
    WRITE (*, '(A,A,A,ES10.3,A,ES10.3)') 'S (', cable_at, '): monolithic vs staggered: rod end position ', dp, &
      ' m, cable tension (relative) ', dt_rel
    CALL require(dp <= 1.0e-5_wp, 'S: the monolithic and staggered rod motions agree ('//cable_at//')')
    CALL require(dt_rel <= 1.0e-5_wp, 'S: the monolithic and staggered cable tensions agree ('//cable_at//')')
  END SUBROUTINE check_staggered

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_buoy()
    !! B. A 4 t Rigid6 buoy (12 m^3) on three taut legs with a finite-EI cable pinned at its keel
    !!    point to a seabed anchor holds its static start over 4 s: body move at most 1e-5 m
    !!    and the cable tension within 1e-5.
    INTEGER :: u, n, k
    REAL(wp) :: rows(4, 500), mv, ten
    LOGICAL :: ok
    CHARACTER(1024) :: em
    OPEN (NEWUNIT=u, FILE='pcl_buoy.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'light buoy with a finite-EI cable pinned at its keel'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'cable 0.20 60.0 5.0e8 -1.0 2.0e4 1.2 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 0.0 0.0 0.0 0.0 4.0e3 12.0 2.84e5 2.0e6 2.0e6 24.0 0.1 2.0e4 2.0e4 1.8e4'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 3.0 0.0 -4.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 -1.5 2.598 -4.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 -1.5 -2.598 -4.0 0 0 0 0'
    WRITE (u, '(A)') '4 Body1 0.0 0.0 -4.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed 60.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -30.0 51.962 -100.0 0 0 0 0'
    WRITE (u, '(A)') '7 Fixed -30.0 -51.962 -100.0 0 0 0 0'
    WRITE (u, '(A)') '8 Fixed -60.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 5 -'
    WRITE (u, '(A)') '2 2 6 -'
    WRITE (u, '(A)') '3 3 7 -'
    WRITE (u, '(A)') '4 4 8 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 111.4 20'
    WRITE (u, '(A)') '2 poly 111.4 20'
    WRITE (u, '(A)') '3 poly 111.4 20'
    WRITE (u, '(A)') '4 cable 10.0 40'
    WRITE (u, '(A)') '4 cable 120.0 60'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '4.0 TMax'
    WRITE (u, '(A)') 'static bodyIC'
    WRITE (u, '(A)') 'monolithic bodyScheme'
    WRITE (u, '(A)') '0.4 rhoInf'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px Body1Pz FairTen4'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL run_deck('pcl_buoy.dat', 'pcl_buoy', ok, em)
    CALL require(ok, 'B: the buoy deck runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_rows('pcl_buoy.out', rows, n, ok)
    CALL require(ok, 'B: buoy output readable')
    IF (.NOT. ok) RETURN
    mv = 0.0_wp
    ten = 0.0_wp
    DO k = 1, n
      mv = nan_max_abs([mv, NORM2(rows(2:3, k) - rows(2:3, 1))])
      ten = nan_max_abs([ten, (rows(4, k) - rows(4, 1))/rows(4, 1)])
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3)') 'B: light buoy, pinned keel cable: body move ', mv, &
      ' m, cable tension change ', ten
    CALL require(mv <= 1.0e-5_wp, 'B: the light buoy holds its static start')
    CALL require(ten <= 1.0e-5_wp, 'B: the keel cable tension holds')
  END SUBROUTINE check_buoy
END PROGRAM test_pinned_cable_light_object
