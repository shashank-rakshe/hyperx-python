! File: tests/test_cable_between_bodies.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> Gates of a finite-EI (cubic-Hermite) line between two objects on the standalone multibody
!> march: End A on a Rigid6 body point, End B on another body point or a rod end, both ends
!> driven by their objects and their end loads returned to them.
!>  S  symmetry: two identical bodies joined by a cable clamped at both ends and pulled apart by
!>     mirrored external loads keep their mirror symmetry (surge, heave, pitch, end tensions), on
!>     the monolithic step and, pinned, on the staggered one;
!>  F  a body joined to an immobile body (mass 1e15 kg) equals the same line to a Fixed point on
!>     the established route (body motion, End A force and moment), clamped and twisted;
!>  E  conservation: two free neutral bodies joined by a taut cable, no drag, added mass or net
!>     weight (no external load), body 1 launched: the total linear momentum (bodies plus cable)
!>     is constant to 1e-4 and the energy (bodies plus cable kinetic and elastic) to 0.5 % under
!>     the rhoInf = 1 monolithic step;
!>  T  torsion: a cable twisted 90 deg between two bodies returns equal and opposite torques to
!>     them, GJ Phi / L at the start, and the bodies counter-rotate;
!>  Q  statics: two moored bodies joined by a clamped cable start balanced (bodyIC static) and
!>     stay at rest in the dynamics;
!>  P  a stiff (EI 1e6 N m^2) clamped cable between two unequal moored bodies, its ends offset out
!>     of the bodies' plane: the static passes converge, written in either direction to the same
!>     equilibrium, which the still dynamics hold; with the passes limited the solve fails
!>     closed naming the line;
!>  D  the coupling does not depend on the line's direction (a cable from a Fixed point to a rod
!>     end and the reversed one: the same motion and end tensions; written from the Fixed point
!>     the line is turned around, as one to a body point, so both write the same output), and an
!>     End B on a fixed rod's end is the same Fixed End B (byte for byte);
!>  R  a cable between a body point and a rod end runs; fail-closed: an End B on a Free point or
!>     a Coupled point, a clamped End B on the staggered scheme and a torsion frame at a body
!>     End A on the staggered scheme are refused by name.
PROGRAM test_cable_between_bodies
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK, CD_Multibody_Probe_Arm, CD_Multibody_Probe_Get, &
                                 CD_Body_Static_Pass_Limit
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, RHOW = 1025.0_wp
  REAL(wp), PARAMETER :: DIAM = 0.2_wp
  INTEGER :: n_fail = 0

  CALL check_symmetry('monolithic', 'Rigid')
  CALL check_symmetry('staggered', 'Pinned')
  CALL check_fixed_equivalence()
  CALL check_conservation()
  CALL check_torsion()
  CALL check_statics()
  CALL check_stiff_statics()
  CALL check_direction()
  CALL check_rod_and_refusals()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' gate(s) of a cable between two objects failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: a finite-EI cable between two objects (symmetry, Fixed limit, conservation, '// &
    'torsion, statics, refusals)'

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

  SUBROUTINE line_type_rows(u, torsion)
    !! A neutrally buoyant cable (no net weight), without drag or added mass; with torsion the
    !! 14-column row (GJ 5e4 N m^2).
    INTEGER, INTENT(IN) :: u
    LOGICAL, INTENT(IN) :: torsion
    REAL(wp) :: m
    m = RHOW*0.25_wp*PI*DIAM**2
    WRITE (u, '(A)') '--- LINE TYPES ---'
    IF (torsion) THEN
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-) (-)'
      WRITE (u, '(A,ES24.16,A)') 'cab 0.2 ', m, ' 1.0e7 0.0 1.0e4 1.0e8 5.0e4 1.0 1.0e-12 0.0 0.0 0.0 0.0'
    ELSE
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
      WRITE (u, '(A,ES24.16,A)') 'cab 0.2 ', m, ' 1.0e6 0.0 1.0e4 0.0 0.0 0.0 0.0'
    END IF
  END SUBROUTINE line_type_rows

  SUBROUTINE body_rows(u, x1, x2, z, m1, m2, vol, inertia2)
    !! Two Rigid6 bodies at (x1, 0, z) and (x2, 0, z), no drag or added mass, inertia (2e3, 3e3,
    !! 4e3) kg m^2 (body 2: inertia2 for each axis when positive).
    INTEGER, INTENT(IN) :: u
    REAL(wp), INTENT(IN) :: x1, x2, z, m1, m2, vol(2), inertia2
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A,3(ES24.16,1X),A,2(ES24.16,1X),A)') '1 Rigid6 ', x1, 0.0_wp, z, '0 0 0 ', m1, vol(1), &
      '0 0 0 0 0 2.0e3 3.0e3 4.0e3'
    IF (inertia2 > 0.0_wp) THEN
      WRITE (u, '(A,3(ES24.16,1X),A,2(ES24.16,1X),A,3(1X,ES24.16))') '2 Rigid6 ', x2, 0.0_wp, z, '0 0 0 ', m2, &
        vol(2), '0 0 0 0 0', inertia2, inertia2, inertia2
    ELSE
      WRITE (u, '(A,3(ES24.16,1X),A,2(ES24.16,1X),A)') '2 Rigid6 ', x2, 0.0_wp, z, '0 0 0 ', m2, vol(2), &
        '0 0 0 0 0 2.0e3 3.0e3 4.0e3'
    END IF
  END SUBROUTINE body_rows

  SUBROUTINE option_rows(u, scheme, ic, dtm, tmax)
    INTEGER, INTENT(IN) :: u
    CHARACTER(*), INTENT(IN) :: scheme, ic
    REAL(wp), INTENT(IN) :: dtm, tmax
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') 'moordyn bodyWetting'
    WRITE (u, '(A)') ic//' bodyIC'
    WRITE (u, '(A)') scheme//' bodyScheme'
    WRITE (u, '(ES12.5,A)') dtm, ' dtM'
    WRITE (u, '(ES12.5,A)') tmax, ' TMax'
    WRITE (u, '(A)') '1.0 rhoInf'
  END SUBROUTINE option_rows

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_symmetric_deck(path, scheme, conn)
    !! Bodies at x = -10.5 and +10.5 m (6 t, 5 m^3: 875 kg of net weight each), the cable from body
    !! 1's point (+0.5, 0, 0) to body 2's (-0.5, 0, 0), 20.2 m long (sagging), End A and End B
    !! connection conn along the chord; external loads of 2 kN pull the bodies apart (-x on body
    !! 1, +x on body 2) with mirrored damping.
    CHARACTER(*), INTENT(IN) :: path, scheme, conn
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'cable between two bodies: symmetry'
    CALL line_type_rows(u, .FALSE.)
    CALL body_rows(u, -10.5_wp, 10.5_wp, -50.0_wp, 6.0e3_wp, 6.0e3_wp, [5.0_wp, 5.0_wp], 0.0_wp)
    WRITE (u, '(A)') '--- EXTERNAL LOADS ---'
    WRITE (u, '(A)') 'ID Object Fext Blin Bquad CSys'
    WRITE (u, '(A)') '(-) (-) (N) (Ns/m) (Ns2/m2) (-)'
    WRITE (u, '(A)') '1 Body1 -2000|0|0 500 0 G'
    WRITE (u, '(A)') '2 Body2 2000|0|0 500 0 G'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 0.5 0 0 0 0 0 0'
    WRITE (u, '(A)') '2 Body2 -0.5 0 0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 20.2 20'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    WRITE (u, '(A)') '1 A '//conn//' 1.0 0.0 0.0'
    WRITE (u, '(A)') '1 B '//conn//' 1.0 0.0 0.0'
    CALL option_rows(u, scheme, 'deck', 0.02_wp, 4.0_wp)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px Body1Pz Body1Ry Body2Px Body2Pz Body2Ry FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_symmetric_deck

  SUBROUTINE check_symmetry(scheme, conn)
    !! S. Mirror x -> -x maps body 1 to body 2 and End A to End B: Px1 = -Px2, Pz1 = Pz2,
    !!    Ry1 = -Ry2 and FairTen = AnchTen at every output step.
    CHARACTER(*), INTENT(IN) :: scheme, conn
    REAL(wp) :: rows(9, 300), dev, amp, tdev, tamp
    INTEGER :: n, k
    LOGICAL :: ok
    CHARACTER(1024) :: em
    CHARACTER(64) :: root
    root = 'cbb_sym_'//scheme
    CALL write_symmetric_deck(TRIM(root)//'.dat', scheme, conn)
    CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok, em)
    CALL require(ok, 'S: the symmetric two-body deck runs ('//scheme//'): '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_rows(TRIM(root)//'.out', rows, n, ok)
    CALL require(ok, 'S: symmetric output readable')
    IF (.NOT. ok) RETURN
    dev = 0.0_wp
    tdev = 0.0_wp
    amp = 0.0_wp
    tamp = 0.0_wp
    DO k = 1, n
      dev = nan_max_abs([dev, rows(2, k) + rows(5, k), rows(3, k) - rows(6, k), rows(4, k) + rows(7, k)])
      amp = nan_max_abs([amp, rows(2, k) - rows(2, 1), rows(3, k) - rows(3, 1), rows(4, k) - rows(4, 1)])
      tdev = nan_max_abs([tdev, rows(8, k) - rows(9, k)])
      tamp = nan_max_abs([tamp, rows(8, k)])
    END DO
    WRITE (*, '(A,A,A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A)') 'S (', scheme, '): mirror deviation ', dev, &
      ' (motion ', amp, '), tension deviation ', tdev, ' N (of ', tamp, ' N)'
    CALL require(amp > 1.0e-2_wp, 'S: the external loads move the bodies ('//scheme//')')
    CALL require(dev <= 1.0e-6_wp*MAX(1.0_wp, amp), 'S: the two bodies stay mirror images ('//scheme//')')
    CALL require(tdev <= 1.0e-6_wp*tamp, 'S: equal tensions at both ends ('//scheme//')')
  END SUBROUTINE check_symmetry

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_pair_deck(path, end_b_kind, torsion, m2, vol2, i2, scheme, bend_a)
    !! Body 1 (5 t, neutral) at (0, 0, -50), the cable from its point (1, 0, 0) along +x to
    !! (21.1, 0, -50), 20 m long (taut), clamped at End A (and twisted 90 deg with torsion); End
    !! B a Fixed point there (end_b_kind 'fixed') or body 2's point (-1, 0, 0) (body 2 at
    !! (22.1, 0, -50), mass m2, volume vol2, inertia i2), clamped.
    CHARACTER(*), INTENT(IN) :: path, end_b_kind
    LOGICAL, INTENT(IN) :: torsion
    REAL(wp), INTENT(IN) :: m2, vol2, i2
    ! scheme: bodyScheme (monolithic by default); bend_a: End A's bending connection (Rigid)
    CHARACTER(*), INTENT(IN), OPTIONAL :: scheme, bend_a
    INTEGER :: u
    REAL(wp) :: mb1
    CHARACTER(16) :: sch, bnd
    sch = 'monolithic'
    IF (PRESENT(scheme)) sch = scheme
    bnd = 'Rigid'
    IF (PRESENT(bend_a)) bnd = bend_a
    mb1 = 5.0e3_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'cable between two bodies: pair'
    CALL line_type_rows(u, torsion)
    IF (end_b_kind == 'fixed') THEN
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
      WRITE (u, '(A,ES24.16,A)') '1 Rigid6 0 0 -50 0 0 0 5.0e3 ', mb1/RHOW, ' 0 0 0 0 0 2.0e3 3.0e3 4.0e3'
    ELSE
      CALL body_rows(u, 0.0_wp, 22.1_wp, -50.0_wp, mb1, m2, [mb1/RHOW, vol2], i2)
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 1.0 0 0 0 0 0 0'
    IF (end_b_kind == 'fixed') THEN
      WRITE (u, '(A)') '2 Fixed 21.1 0 -50 0 0 0 0'
    ELSE
      WRITE (u, '(A)') '2 Body2 -1.0 0 0 0 0 0 0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 20.0 20'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    IF (torsion) THEN
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
      WRITE (u, '(A)') '1 A '//TRIM(bnd)//' 1.0 0.0 0.0 Rigid 0 0 1 0'
      WRITE (u, '(A)') '1 B Rigid 1.0 0.0 0.0 Rigid 0 0 1 90'
    ELSE
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
      WRITE (u, '(A)') '1 A Rigid 1.0 0.0 0.0'
      WRITE (u, '(A)') '1 B Rigid 1.0 0.0 0.0'
    END IF
    CALL option_rows(u, TRIM(sch), 'deck', 0.02_wp, 6.0_wp)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_pair_deck

  SUBROUTINE run_probed(path, root, v0, w0, rec, ok, em)
    CHARACTER(*), INTENT(IN) :: path, root
    REAL(wp), INTENT(IN) :: v0(3), w0(3)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: rec(:, :)
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(*), INTENT(OUT) :: em
    CALL CD_Multibody_Probe_Arm(v0, w0)
    CALL run_deck(path, root, ok, em)
    CALL CD_Multibody_Probe_Get(rec)
    ok = ok .AND. ALLOCATED(rec)
  END SUBROUTINE run_probed

  SUBROUTINE check_fixed_equivalence()
    !! F. Body 1 launched on a cable clamped to it and to a Fixed point (the established route),
    !!    and on the same cable clamped to body 2 of 1e15 kg (neutral, inertia 1e15 kg m^2) at
    !!    that point: body 1's trajectory, the End A force and moment agree, without and with
    !!    torsion (90 deg of pretwist).
    REAL(wp), ALLOCATABLE :: rf(:, :), rb(:, :)
    REAL(wp) :: dx, df, dm, sx, sf, sm, d2
    INTEGER :: k, it
    LOGICAL :: ok, tors
    CHARACTER(1024) :: em
    CHARACTER(8) :: tag
    DO it = 1, 2
      tors = it == 2
      tag = MERGE('tors', 'bend', tors)
      CALL write_pair_deck('cbb_fix_'//TRIM(tag)//'.dat', 'fixed', tors, 0.0_wp, 0.0_wp, 0.0_wp)
      CALL run_probed('cbb_fix_'//TRIM(tag)//'.dat', 'cbb_fix_'//TRIM(tag), [0.05_wp, 0.02_wp, 0.05_wp], &
                      [0.01_wp, 0.03_wp, 0.02_wp], rf, ok, em)
      CALL require(ok, 'F: the body-to-Fixed deck runs ('//TRIM(tag)//'): '//TRIM(em))
      IF (.NOT. ok) CYCLE
      CALL write_pair_deck('cbb_imm_'//TRIM(tag)//'.dat', 'body', tors, 1.0e15_wp, 1.0e15_wp/RHOW, 1.0e15_wp)
      CALL run_probed('cbb_imm_'//TRIM(tag)//'.dat', 'cbb_imm_'//TRIM(tag), [0.05_wp, 0.02_wp, 0.05_wp], &
                      [0.01_wp, 0.03_wp, 0.02_wp], rb, ok, em)
      CALL require(ok, 'F: the body-to-immobile-body deck runs ('//TRIM(tag)//'): '//TRIM(em))
      IF (.NOT. ok) CYCLE
      ok = UBOUND(rf, 2) == UBOUND(rb, 2)
      CALL require(ok, 'F: same number of steps')
      IF (.NOT. ok) CYCLE
      dx = 0.0_wp
      df = 0.0_wp
      dm = 0.0_wp
      d2 = 0.0_wp
      sx = 0.0_wp
      sf = 0.0_wp
      sm = 0.0_wp
      DO k = 0, UBOUND(rf, 2)
        dx = nan_max_abs([dx, rf(2:7, k) - rb(2:7, k), rf(17:19, k) - rb(17:19, k)])
        sx = nan_max_abs([sx, rf(2:4, k) - rf(2:4, 0), rf(5:7, k), rf(17:19, k)])
        df = nan_max_abs([df, rf(27:29, k) - rb(27:29, k)])
        sf = nan_max_abs([sf, rf(27:29, k)])
        dm = nan_max_abs([dm, rf(24:26, k) - rb(24:26, k)])
        sm = nan_max_abs([sm, rf(24:26, k)])
        d2 = nan_max_abs([d2, rb(30:32, k) - rb(30:32, 0)])
      END DO
      WRITE (*, '(A,A,A,3(ES10.3,A),ES10.3)') 'F (', TRIM(tag), '): body-to-Fixed vs body-to-immobile body: '// &
       'state ', dx/sx, ', End A force ', df/sf, ', End A moment ', dm/MAX(sm, 1.0_wp), ' (relative); body 2 moves ', d2
      CALL require(dx <= 1.0e-6_wp*sx, 'F: body 1 moves as on a Fixed End B ('//TRIM(tag)//')')
      CALL require(df <= 1.0e-6_wp*sf, 'F: End A force as on a Fixed End B ('//TRIM(tag)//')')
      CALL require(dm <= 1.0e-6_wp*MAX(sm, 1.0_wp), 'F: End A moment as on a Fixed End B ('//TRIM(tag)//')')
    END DO
  END SUBROUTINE check_fixed_equivalence

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_conservation()
    !! E. Two free neutral bodies (5 t each) joined by the taut 20 m cable clamped at both ends,
    !!    body 1 launched with v = (0.05, 0.02, 0.05) m/s, omega = (0.01, 0.03, 0.02) rad/s; no
    !!    drag, added mass or net weight: no external load. The total linear momentum (bodies plus
    !!    the cable's consistent-mass momentum) stays at its value after the first step (the
    !!    first step brings the cable, at rest at t = 0, to the bodies' end velocities) to 1e-4 of
    !!    the launch momentum (each step's junction residual, below 1e-6 of the body weight, is an
    !!    impulse of at most 1e-3 kg m/s), and the energy (bodies plus cable kinetic and elastic)
    !!    is conserved by the rhoInf = 1 step to 0.5 %.
    REAL(wp), PARAMETER :: MB = 5.0e3_wp, IB(3) = [2.0e3_wp, 3.0e3_wp, 4.0e3_wp]
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: p(3), p1(3), dp, e, e1, de, rot(3, 3), wb(3), amp, pscale
    INTEGER :: k
    LOGICAL :: ok
    CHARACTER(1024) :: em
    CALL write_pair_deck('cbb_cons.dat', 'body', .FALSE., MB, MB/RHOW, 0.0_wp)
    CALL run_probed('cbb_cons.dat', 'cbb_cons', [0.05_wp, 0.02_wp, 0.05_wp], [0.01_wp, 0.03_wp, 0.02_wp], rec, ok, em)
    CALL require(ok, 'E: the free two-body deck runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    dp = 0.0_wp
    de = 0.0_wp
    amp = 0.0_wp
    pscale = MB*NORM2([0.05_wp, 0.02_wp, 0.05_wp])
    DO k = 1, UBOUND(rec, 2)
      p = MB*rec(5:7, k) + MB*rec(33:35, k) + rec(48:50, k)
      rot = RESHAPE(rec(8:16, k), [3, 3])
      wb = MATMUL(TRANSPOSE(rot), rec(17:19, k))
      e = 0.5_wp*MB*DOT_PRODUCT(rec(5:7, k), rec(5:7, k)) + 0.5_wp*DOT_PRODUCT(wb, IB*wb)
      rot = RESHAPE(rec(36:44, k), [3, 3])
      wb = MATMUL(TRANSPOSE(rot), rec(45:47, k))
      e = e + 0.5_wp*MB*DOT_PRODUCT(rec(33:35, k), rec(33:35, k)) + 0.5_wp*DOT_PRODUCT(wb, IB*wb) + rec(23, k)
      IF (k == 1) THEN
        p1 = p
        e1 = e
      END IF
      dp = MAX(dp, NORM2(p - p1))
      de = MAX(de, ABS(e - e1)/e1)
      amp = MAX(amp, NORM2(rec(30:32, k) - rec(30:32, 0)))
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A,ES10.3,A)') 'E: free two-body system: momentum drift ', dp/pscale, &
      ' (of the launch momentum), energy drift ', de, ', momentum after the first step ', NORM2(p1)/pscale, &
      ' (launch 1), body 2 excursion ', amp, ' m'
    CALL require(amp > 1.0e-2_wp, 'E: the cable carries body 1''s motion to body 2')
    CALL require(dp <= 1.0e-4_wp*pscale, 'E: total linear momentum conserved')
    CALL require(de <= 5.0e-3_wp, 'E: energy conserved to 0.5 %')
  END SUBROUTINE check_conservation

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_torsion()
    !! T. The cable of E twisted 90 deg (Pretwist B - A), torsion rigid at both bodies, at rest:
    !!    the End A and End B moments on the bodies are equal and opposite, GJ Phi / L about the
    !!    chord at the start, and the bodies counter-rotate about it.
    REAL(wp), PARAMETER :: MB = 5.0e3_wp
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: m0, dev, mmax, rx1, rx2, rdev, rot(3, 3)
    INTEGER :: k
    LOGICAL :: ok
    CHARACTER(1024) :: em
    CALL write_pair_deck('cbb_tors.dat', 'body', .TRUE., MB, MB/RHOW, 0.0_wp)
    CALL run_probed('cbb_tors.dat', 'cbb_tors', [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], rec, ok, em)
    CALL require(ok, 'T: the twisted two-body deck runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    m0 = 5.0e4_wp*0.5_wp*PI/20.0_wp
    dev = 0.0_wp
    mmax = 0.0_wp
    rdev = 0.0_wp
    DO k = 0, UBOUND(rec, 2)
      dev = MAX(dev, NORM2(rec(24:26, k) + rec(51:53, k)))
      mmax = MAX(mmax, NORM2(rec(24:26, k)))
      rot = RESHAPE(rec(8:16, k), [3, 3])
      rx1 = ATAN2(rot(3, 2), rot(3, 3))
      rot = RESHAPE(rec(36:44, k), [3, 3])
      rx2 = ATAN2(rot(3, 2), rot(3, 3))
      rdev = MAX(rdev, ABS(rx1 + rx2))
    END DO
    WRITE (*, '(A,2ES12.5,A,ES12.5,A,ES10.3,A,ES10.3,A,ES10.3,A)') 'T: start moments about x ', rec(24, 0), &
      rec(51, 0), ' N m (GJ Phi/L ', m0, '); |M_A + M_B| up to ', dev, ' N m; body roll asymmetry ', rdev, &
      ' rad; roll at the end ', rx1, ' rad'
    CALL require(ABS(ABS(rec(24, 0)) - m0) <= 1.0e-3_wp*m0, 'T: the start torque is GJ Phi / L')
    CALL require(ABS(rec(24, 0) + rec(51, 0)) <= 1.0e-6_wp*m0, 'T: equal and opposite torques at the start')
    CALL require(dev <= 1.0e-2_wp*mmax, 'T: equal and opposite end moments through the run')
    CALL require(ABS(rx1) > 1.0e-3_wp, 'T: the torque turns the bodies')
    CALL require(rdev <= 1.0e-6_wp + 1.0e-4_wp*ABS(rx1), 'T: the bodies counter-rotate')
  END SUBROUTINE check_torsion

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_moored_pair(path, tmax, conn, stiff, reversed)
    !! Two buoyant bodies (2e4 kg, 40 m^3, C44 = C55 = 2e6 N m/rad) at x = -30 and +30 m, each on
    !! three EI = 0 legs, joined keel to keel by a 64 m finite-EI cable clamped at both ends
    !! (connection conn, Ez along the end tangents); mirror symmetric about x = 0.
    CHARACTER(*), INTENT(IN) :: path, conn
    REAL(wp), INTENT(IN) :: tmax
    ! stiff: EI 1e6 N m^2, body 2 of 2.5e4 kg and its cable point at (0.5, 0.3, -3) (no symmetry);
    ! reversed: the cable written from body 2 to body 1
    LOGICAL, INTENT(IN), OPTIONAL :: stiff, reversed
    LOGICAL :: stf, rev
    INTEGER :: u
    stf = .FALSE.
    IF (PRESENT(stiff)) stf = stiff
    rev = .FALSE.
    IF (PRESENT(reversed)) rev = reversed
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'cable between two moored bodies: statics'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'cab 0.2 60.0 5.0e8 -1.0 '//MERGE('1.0e6', '2.0e4', stf)//' 1.2 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 -30 0 -20 0 0 0 2.0e4 40.0 0.0 2.0e6 2.0e6 8.0 0.5 3.5e4 3.5e4 3.5e4'
    WRITE (u, '(A)') '2 Rigid6 30 0 -20 0 0 0 '//MERGE('2.5e4', '2.0e4', stf)//' 40.0 0.0 2.0e6 2.0e6 8.0 0.5 '// &
      '3.5e4 3.5e4 3.5e4'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 -1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -70.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -10.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -10.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '7 Body2 1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '8 Body2 -0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '9 Body2 -0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '10 Fixed 70.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '11 Fixed 10.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '12 Fixed 10.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '13 Body1 0.0 0.0 -3.0 0 0 0 0'
    WRITE (u, '(A)') '14 Body2 '//MERGE('0.5 0.3', '0.0 0.0', stf)//' -3.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 4 -'
    WRITE (u, '(A)') '2 2 5 -'
    WRITE (u, '(A)') '3 3 6 -'
    WRITE (u, '(A)') '4 7 10 -'
    WRITE (u, '(A)') '5 8 11 -'
    WRITE (u, '(A)') '6 9 12 -'
    WRITE (u, '(A)') MERGE('7 14 13 -', '7 13 14 -', rev)
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 86.85 20'
    WRITE (u, '(A)') '2 poly 86.85 20'
    WRITE (u, '(A)') '3 poly 86.85 20'
    WRITE (u, '(A)') '4 poly 86.85 20'
    WRITE (u, '(A)') '5 poly 86.85 20'
    WRITE (u, '(A)') '6 poly 86.85 20'
    WRITE (u, '(A)') '7 cab 64.0 40'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    IF (rev) THEN
      ! End A on body 2, the directions from End A to End B
      WRITE (u, '(A)') '7 A '//conn//' -0.7071067811865476 0.0 -0.7071067811865476'
      WRITE (u, '(A)') '7 B '//conn//' -0.7071067811865476 0.0 0.7071067811865476'
    ELSE
      WRITE (u, '(A)') '7 A '//conn//' 0.7071067811865476 0.0 -0.7071067811865476'
      WRITE (u, '(A)') '7 B '//conn//' 0.7071067811865476 0.0 0.7071067811865476'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(ES12.5,A)') tmax, ' TMax'
    WRITE (u, '(A)') 'static bodyIC'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    IF (stf) THEN
      WRITE (u, '(A)') 'Body1Px Body1Py Body1Pz Body1Rx Body1Ry Body1Rz Body2Px Body2Py Body2Pz Body2Rx Body2Ry Body2Rz'
    ELSE
      WRITE (u, '(A)') 'Body1Px Body1Pz Body1Ry Body2Px Body2Pz Body2Ry'
    END IF
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_moored_pair

  SUBROUTINE check_stiff_statics()
    !! P. The stiff, unequal, out-of-plane pair, written in both directions: the static passes
    !!    converge to one equilibrium (1e-6 m and deg), held by the still dynamics over 5 s
    !!    (2e-6); with two passes allowed the solve fails closed naming the line.
    REAL(wp) :: rf(13, 200), rr(13, 200), d0, drift
    INTEGER :: nf, nr, k
    LOGICAL :: okf, okr
    CHARACTER(1024) :: em
    CALL write_moored_pair('cbb_stiff_fwd.dat', 5.0_wp, 'Rigid', stiff=.TRUE.)
    CALL write_moored_pair('cbb_stiff_rev.dat', 5.0_wp, 'Rigid', stiff=.TRUE., reversed=.TRUE.)
    CALL run_deck('cbb_stiff_fwd.dat', 'cbb_stiff_fwd', okf, em)
    CALL require(okf, 'P: the stiff pair (forward) balances and runs: '//TRIM(em))
    CALL run_deck('cbb_stiff_rev.dat', 'cbb_stiff_rev', okr, em)
    CALL require(okr, 'P: the stiff pair (reversed) balances and runs: '//TRIM(em))
    IF (.NOT. (okf .AND. okr)) RETURN
    CALL read_rows('cbb_stiff_fwd.out', rf, nf, okf)
    CALL read_rows('cbb_stiff_rev.out', rr, nr, okr)
    CALL require(okf .AND. okr .AND. nf == nr, 'P: stiff pair outputs readable')
    IF (.NOT. (okf .AND. okr .AND. nf == nr)) RETURN
    d0 = nan_max_abs(rf(2:13, 1) - rr(2:13, 1))
    drift = 0.0_wp
    DO k = 1, nf
      drift = nan_max_abs([drift, rf(2:13, k) - rf(2:13, 1), rr(2:13, k) - rr(2:13, 1)])
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A,F9.4,A,F9.4,A)') 'P: stiff pair, forward vs reversed start ', d0, &
      '; drift over 5 s ', drift, ' (pitches ', rf(6, 1), ' / ', rf(12, 1), ' deg)'
    CALL require(d0 <= 1.0e-6_wp, 'P: both directions reach the same equilibrium')
    CALL require(drift <= 2.0e-6_wp, 'P: the still dynamics hold the equilibrium')
    ! the non-convergence report names the line (whichever end's entry is the worst)
    CALL CD_Body_Static_Pass_Limit(2)
    CALL run_deck('cbb_stiff_fwd.dat', 'cbb_stiff_lim', okf, em)
    CALL CD_Body_Static_Pass_Limit(0)
    WRITE (*, '(A,A)') 'P: two passes: ', TRIM(em)
    CALL require(.NOT. okf .AND. INDEX(em, 'finite-EI LINE 7') > 0 .AND. INDEX(em, 'after 2 passes') > 0, &
                 'P: the limited static passes fail closed naming the line')
  END SUBROUTINE check_stiff_statics

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_rod_line(path, kind, end_b_conn, rod_type)
    !! A cable between a Fixed point (1, 0, -50) and the end A (21, 0, -50) of a rod spanning to
    !! (31, 0, -50), rod type rod_type (Free or Fixed): kind 'fr' from the Fixed point to the rod
    !! end, 'rf' the reverse, 'bp' from body 1's point to the rod end, 'bf' from body 1's point to
    !! a Fixed point at the rod end; End B's connection end_b_conn.
    CHARACTER(*), INTENT(IN) :: path, kind, end_b_conn, rod_type
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'cable to a rod end'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cab 0.2 60.0 1.0e6 0.0 1.0e4 0.0 0.0 0.0 0.0'
    IF (kind == 'bp' .OR. kind == 'bf') THEN
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) '// &
        '(kgm2) (kgm2)'
      WRITE (u, '(A,ES24.16,A)') '1 Rigid6 0 0 -50 0 0 0 5.0e3 ', 5.0e3_wp/RHOW, ' 0 0 0 0 0 2.0e3 3.0e3 4.0e3'
    END IF
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'spar 1.0 805.0 0.8 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 spar '//rod_type//' 21.0 0 -50 31.0 0 -50 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    SELECT CASE (kind)
    CASE ('fr', 'rf')
      WRITE (u, '(A)') '1 Fixed 1.0 0 -50 0 0 0 0'
      WRITE (u, '(A)') '2 Rod1A 21.0 0 -50 0 0 0 0'
    CASE ('bp')
      WRITE (u, '(A)') '1 Body1 1.0 0 0 0 0 0 0'
      WRITE (u, '(A)') '2 Rod1A 21.0 0 -50 0 0 0 0'
    CASE DEFAULT
      WRITE (u, '(A)') '1 Body1 1.0 0 0 0 0 0 0'
      WRITE (u, '(A)') '2 Fixed 21.0 0 -50 0 0 0 0'
    END SELECT
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') MERGE('1 2 1 -', '1 1 2 -', kind == 'rf')
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 20.5 20'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    IF (kind == 'rf') THEN
      WRITE (u, '(A)') '1 A '//end_b_conn//' -1.0 0.0 0.0'
      WRITE (u, '(A)') '1 B Pinned -1.0 0.0 0.0'
    ELSE
      WRITE (u, '(A)') '1 A Pinned 1.0 0.0 0.0'
      WRITE (u, '(A)') '1 B '//end_b_conn//' 1.0 0.0 0.0'
    END IF
    CALL option_rows(u, 'monolithic', 'deck', 0.02_wp, 3.0_wp)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    IF (kind == 'fr' .OR. kind == 'rf') THEN
      WRITE (u, '(A)') 'Rod1Px Rod1Pz Rod1Ry FairTen1 AnchTen1'
    ELSE
      WRITE (u, '(A)') 'Body1Px Body1Pz Body1Ry FairTen1 AnchTen1'
    END IF
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_rod_line

  SUBROUTINE check_direction()
    !! D. A cable from a Fixed point to a free rod's end and the same cable written from the rod
    !!    end to the Fixed point (pinned, and rigid at the rod) move the rod alike and carry the
    !!    same end tensions, byte for byte in the output (the line written from the Fixed point is
    !!    turned around to start at the rod end, so FairTen is the rod end's in both);
    !!    a body's cable to a fixed rod's end writes the output of the same cable to a Fixed point
    !!    there: byte for byte pinned, to the output's last digit rigid at End B (whose
    !!    connection direction passes through the rod's frame).
    REAL(wp) :: a(6, 200), b(6, 200)
    INTEGER :: na, nb, ic
    LOGICAL :: ok, oka, okb
    CHARACTER(1024) :: em
    CHARACTER(8) :: conn
    DO ic = 1, 2
      conn = MERGE('Pinned', 'Rigid ', ic == 1)
      CALL write_rod_line('cbb_fr.dat', 'fr', TRIM(conn), 'Free')
      CALL write_rod_line('cbb_rf.dat', 'rf', TRIM(conn), 'Free')
      CALL run_deck('cbb_fr.dat', 'cbb_fr', oka, em)
      CALL require(oka, 'D: Fixed point to rod end runs ('//TRIM(conn)//'): '//TRIM(em))
      CALL run_deck('cbb_rf.dat', 'cbb_rf', okb, em)
      CALL require(okb, 'D: rod end to Fixed point runs ('//TRIM(conn)//'): '//TRIM(em))
      IF (.NOT. (oka .AND. okb)) CYCLE
      CALL read_rows('cbb_fr.out', a, na, oka)
      CALL read_rows('cbb_rf.out', b, nb, okb)
      ok = oka .AND. okb .AND. na == nb
      IF (ok) ok = ALL(a(1:6, 1:na) == b(1:6, 1:nb))
      WRITE (*, '(A,A,A,L1)') 'D (', TRIM(conn), '): either direction, the same rod motion and end tensions: ', ok
      CALL require(ok, 'D: the coupling does not depend on the line direction ('//TRIM(conn)//')')
      CALL write_rod_line('cbb_bp.dat', 'bp', TRIM(conn), 'Fixed')
      CALL write_rod_line('cbb_bf.dat', 'bf', TRIM(conn), 'Fixed')
      CALL run_deck('cbb_bp.dat', 'cbb_bp', oka, em)
      CALL run_deck('cbb_bf.dat', 'cbb_bf', okb, em)
      CALL require(oka .AND. okb, 'D: body to fixed rod end / Fixed point run ('//TRIM(conn)//'): '//TRIM(em))
      IF (.NOT. (oka .AND. okb)) CYCLE
      IF (ic == 1) THEN
        ok = same_file('cbb_bp.out', 'cbb_bf.out')
        WRITE (*, '(A,A,A,L1)') 'D (', TRIM(conn), '): End B on a fixed rod''s end is the Fixed End B, byte for '// &
          'byte: ', ok
      ELSE
        CALL read_rows('cbb_bp.out', a, na, oka)
        CALL read_rows('cbb_bf.out', b, nb, okb)
        ok = oka .AND. okb .AND. na == nb
        IF (ok) ok = ALL(ABS(a(:, 1:na) - b(:, 1:nb)) <= 1.0e-7_wp*MAX(1.0_wp, ABS(b(:, 1:nb))))
        WRITE (*, '(A,A,A,L1)') 'D (', TRIM(conn), '): End B on a fixed rod''s end is the Fixed End B, to the '// &
          'output precision: ', ok
      END IF
      CALL require(ok, 'D: an End B on a fixed rod writes the Fixed End B''s output ('//TRIM(conn)//')')
    END DO
  END SUBROUTINE check_direction

  LOGICAL FUNCTION same_file(p1, p2) RESULT(same)
    !! The two files are equal line by line.
    CHARACTER(*), INTENT(IN) :: p1, p2
    INTEGER :: u1, u2, i1, i2
    CHARACTER(2048) :: l1, l2
    same = .FALSE.
    OPEN (NEWUNIT=u1, FILE=p1, STATUS='OLD', ACTION='READ', IOSTAT=i1)
    OPEN (NEWUNIT=u2, FILE=p2, STATUS='OLD', ACTION='READ', IOSTAT=i2)
    IF (i1 /= 0 .OR. i2 /= 0) RETURN
    DO
      READ (u1, '(A)', IOSTAT=i1) l1
      READ (u2, '(A)', IOSTAT=i2) l2
      IF (i1 /= 0 .OR. i2 /= 0) EXIT
      IF (l1 /= l2) THEN
        CLOSE (u1)
        CLOSE (u2)
        RETURN
      END IF
    END DO
    same = i1 /= 0 .AND. i2 /= 0
    CLOSE (u1)
    CLOSE (u2)
  END FUNCTION same_file

  SUBROUTINE check_statics()
    !! Q. bodyIC static balances both bodies on the clamped cable: over 5 s of dynamics they
    !!    stay at rest (1 mm, 1e-3 deg), mirror images of each other, and the connection moments
    !!    turn them from their pitch on the pinned cable.
    REAL(wp) :: rows(7, 200), drift, rdrift, sym, prow(7, 2)
    INTEGER :: n, k
    LOGICAL :: ok
    CHARACTER(1024) :: em
    CALL write_moored_pair('cbb_static.dat', 5.0_wp, 'Rigid')
    CALL run_deck('cbb_static.dat', 'cbb_static', ok, em)
    CALL require(ok, 'Q: the moored two-body deck runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_rows('cbb_static.out', rows, n, ok)
    CALL require(ok, 'Q: output readable')
    IF (.NOT. ok) RETURN
    drift = 0.0_wp
    rdrift = 0.0_wp
    sym = 0.0_wp
    DO k = 1, n
      drift = nan_max_abs([drift, rows(2:3, k) - rows(2:3, 1), rows(5:6, k) - rows(5:6, 1)])
      rdrift = nan_max_abs([rdrift, rows(4, k) - rows(4, 1), rows(7, k) - rows(7, 1)])
      sym = nan_max_abs([sym, rows(2, k) + rows(5, k), rows(3, k) - rows(6, k), rows(4, k) + rows(7, k)])
    END DO
    WRITE (*, '(A,F10.5,A,F10.5,A,ES10.3,A,ES10.3,A,ES10.3)') 'Q: static pitch ', rows(4, 1), ' / ', rows(7, 1), &
      ' deg; drift over 5 s ', drift, ' m, ', rdrift, ' deg; mirror deviation ', sym
    CALL require(drift <= 1.0e-3_wp, 'Q: both bodies at rest in the dynamics (1 mm)')
    CALL require(rdrift <= 1.0e-3_wp, 'Q: both pitches at rest (1e-3 deg)')
    CALL require(sym <= 1.0e-5_wp, 'Q: the static pair is mirror symmetric')
    CALL write_moored_pair('cbb_static_pin.dat', 0.05_wp, 'Pinned')
    CALL run_deck('cbb_static_pin.dat', 'cbb_static_pin', ok, em)
    CALL require(ok, 'Q: the moored pair on a pinned cable runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_rows('cbb_static_pin.out', prow, n, ok)
    IF (.NOT. ok) RETURN
    WRITE (*, '(A,F10.5,A,F10.5,A)') 'Q: pitch of body 1, clamped ', rows(4, 1), ' deg, pinned ', prow(4, 1), ' deg'
    CALL require(ABS(rows(4, 1) - prow(4, 1)) > 1.0e-2_wp, 'Q: the connection moments turn the bodies in statics')
  END SUBROUTINE check_statics

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_rod_and_refusals()
    !! R. A pinned cable from a body point to the end of a free rod runs (both ends driven); an
    !!    End B on a Free point or a Coupled point, and a clamped End B on the staggered scheme,
    !!    are refused by name.
    INTEGER :: u
    LOGICAL :: ok
    CHARACTER(1024) :: em
    REAL(wp) :: rows(3, 300)
    INTEGER :: n
    OPEN (NEWUNIT=u, FILE='cbb_rod.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'cable between a body and a rod end'
    CALL line_type_rows(u, .FALSE.)
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A,ES24.16,A)') '1 Rigid6 0 0 -50 0 0 0 5.0e3 ', 5.0e3_wp/RHOW, ' 0 0 0 0 0 2.0e3 3.0e3 4.0e3'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'spar 1.0 805.0 0.8 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 spar Free 21.0 0 -50 31.0 0 -50 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 1.0 0 0 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1A 21.0 0 -50 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 20.0 20'
    CALL option_rows(u, 'monolithic', 'deck', 0.02_wp, 2.0_wp)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL run_deck('cbb_rod.dat', 'cbb_rod', ok, em)
    CALL require(ok, 'R: a cable between a body point and a rod end runs: '//TRIM(em))
    IF (ok) THEN
      CALL read_rows('cbb_rod.out', rows, n, ok)
      CALL require(ok .AND. n == 101, 'R: body-to-rod output complete and finite')
    END IF
    ! refusals
    CALL refused('Free', 'monolithic', 'Pinned', 'Free/Connect point')
    CALL refused('Coupled', 'monolithic', 'Pinned', 'Coupled/Vessel End B')
    CALL refused('Body2', 'staggered', 'Rigid', 'needs bodyScheme monolithic')
    ! a torsion frame at a bending-pinned body End A on the staggered scheme (which would hold
    ! the frame still while the body turns)
    CALL write_pair_deck('cbb_tors_stag.dat', 'fixed', .TRUE., 0.0_wp, 0.0_wp, 0.0_wp, scheme='staggered', &
                         bend_a='Pinned')
    CALL run_deck('cbb_tors_stag.dat', 'cbb_tors_stag', ok, em)
    CALL require(.NOT. ok .AND. INDEX(em, 'or a torsional one on a body or rod needs bodyScheme monolithic') > 0, &
                 'R: a torsion frame at a body End A is refused on the staggered scheme: '//TRIM(em))
    CALL write_pair_deck('cbb_tors_mono.dat', 'fixed', .TRUE., 0.0_wp, 0.0_wp, 0.0_wp, bend_a='Pinned')
    CALL run_deck('cbb_tors_mono.dat', 'cbb_tors_mono', ok, em)
    CALL require(ok, 'R: the same deck runs on the monolithic scheme: '//TRIM(em))
  END SUBROUTINE check_rod_and_refusals

  SUBROUTINE refused(ptype, scheme, conn, key)
    CHARACTER(*), INTENT(IN) :: ptype, scheme, conn, key
    INTEGER :: u
    LOGICAL :: ok
    CHARACTER(1024) :: em
    OPEN (NEWUNIT=u, FILE='cbb_refuse.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'refused cable end'
    CALL line_type_rows(u, .FALSE.)
    WRITE (u, '(A)') 'leg 0.1 10.0 1.0e7 0.0 0.0 0.0 0.0 0.0 0.0'
    CALL body_rows(u, 0.0_wp, 22.1_wp, -50.0_wp, 5.0e3_wp, 5.0e3_wp, [5.0e3_wp/RHOW, 5.0e3_wp/RHOW], 0.0_wp)
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 1.0 0 0 0 0 0 0'
    IF (ptype == 'Body2') THEN
      WRITE (u, '(A)') '2 Body2 -1.0 0 0 0 0 0 0'
    ELSE
      WRITE (u, '(A)') '2 '//ptype//' 21.1 0 -50 0 0 0 0'
    END IF
    WRITE (u, '(A)') '3 Fixed 21.1 0 -100 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 2 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 20.0 20'
    WRITE (u, '(A)') '2 leg 50.0 10'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    WRITE (u, '(A)') '1 B '//conn//' 1.0 0.0 0.0'
    CALL option_rows(u, scheme, 'deck', 0.02_wp, 0.1_wp)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL run_deck('cbb_refuse.dat', 'cbb_refuse', ok, em)
    CALL require(.NOT. ok .AND. INDEX(em, key) > 0, 'R: End B on a '//ptype//' point ('//scheme//', '//conn// &
                 ') is refused naming "'//key//'": '//TRIM(em))
  END SUBROUTINE refused

END PROGRAM test_cable_between_bodies
