! File: tests/test_shared_anchor.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_shared_anchor
  !! Shared anchors and shared points in standalone decks, and the Point<P>F{x,y,z,H} channels:
  !!   1. three chains from three Coupled fairleads (three "turbines") on one Fixed anchor: the
  !!      anchor resultant Point4F equals the sum of the three single-line decks' anchor forces
  !!      (a Fixed anchor couples nothing) in statics and in a dynamic run with one fairlead
  !!      driven by a motionFile, and each single-line anchor force has the AnchTen magnitude;
  !!   2. a Free clump shared by the three lines, resting on the seabed: its line resultant and
  !!      its own seabed reaction (kBot A pen over its footprint A = Vol^(2/3)) balance its
  !!      submerged weight, Point4F + kBot A pen e3 + (rhoW V - m) g e3 = 0.
  !!   3. the same three fairleads written as Turbine<J> points of a TURBINES section (reference
  !!      position, turbine-local fairlead) and driven by per-turbine rigid-body motion records
  !!      reproduce the Coupled-point deck.
  !! Output columns carry 8 significant digits, which bounds the comparisons.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHO_W = 1025.0_wp, GRAV = 9.80665_wp, KBOT = 1.0e5_wp   ! the default kBot
  REAL(wp), PARAMETER :: FAIR(3, 3) = RESHAPE([0.0_wp, 0.0_wp, -10.0_wp, 600.0_wp, 0.0_wp, -10.0_wp, &
                                               300.0_wp, 519.615242_wp, -10.0_wp], [3, 3])
  REAL(wp), PARAMETER :: ANCHOR(3) = [300.0_wp, 173.205081_wp, -100.0_wp]
  INTEGER :: nfail

  nfail = 0
  CALL check_fixed_anchor(.FALSE.)
  CALL check_fixed_anchor(.TRUE.)
  CALL check_free_clump()
  CALL check_turbines_section()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' shared-anchor check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: shared anchor and shared free point (superposition, force balance)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', TRIM(label)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE write_motion(path, which)
    !! Fairlead 1 surges 5 m sinusoidally from rest (s(t) = 5 (1 - cos(2 pi t/20))/2); the others
    !! hold. Rows for the fairleads selected by which.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: which(3)
    INTEGER :: u, k, j
    REAL(wp) :: t, w, x, v, a
    w = 2.0_wp*3.14159265358979323846_wp/20.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO k = 0, 100
      t = 0.1_wp*REAL(k, wp)
      DO j = 1, 3
        IF (.NOT. which(j)) CYCLE
        x = FAIR(1, j)
        v = 0.0_wp
        a = 0.0_wp
        IF (j == 1) THEN
          x = x + 2.5_wp*(1.0_wp - COS(w*t))
          v = 2.5_wp*w*SIN(w*t)
          a = 2.5_wp*w*w*COS(w*t)
        END IF
        WRITE (u, '(F8.3,1X,I0,9(1X,ES22.14))') t, j, x, FAIR(2, j), FAIR(3, j), v, 0.0_wp, 0.0_wp, &
          a, 0.0_wp, 0.0_wp
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_motion

  SUBROUTINE write_deck(path, which, clump, dynamic, motion)
    !! which(j): line j is present. The shared point 4 is a Fixed anchor or (clump) a Free clump.
    !! motion: the dynamic deck drives the fairleads from a motionFile (else they are held).
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: which(3), clump, dynamic, motion
    INTEGER :: u, j
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Shared anchor: three fairleads, one point'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.1 20.0 1.0e9 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    DO j = 1, 3
      IF (which(j)) WRITE (u, '(I0,A,3(1X,F12.6),A)') j, ' Coupled', FAIR(:, j), ' 0 0 0 0'
    END DO
    IF (clump) THEN
      WRITE (u, '(A,3(1X,F12.6),A)') '4 Free', ANCHOR(1), ANCHOR(2), -60.0_wp, ' 20000 2.0 0 0'
    ELSE
      WRITE (u, '(A,3(1X,F12.6),A)') '4 Fixed', ANCHOR, ' 0 0 0 0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    DO j = 1, 3
      IF (which(j)) WRITE (u, '(I0,1X,I0,A)') j, j, ' 4 -'
    END DO
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    DO j = 1, 3
      IF (which(j)) WRITE (u, '(I0,A)') j, ' chain 380.0 20'
    END DO
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    IF (dynamic) THEN
      WRITE (u, '(A)') '0.1 dtM'
      WRITE (u, '(A)') '10.0 TMax'
      IF (motion) THEN
        CALL write_motion(path//'.motion', which)
        WRITE (u, '(A)') '"'//path//'.motion" motionFile'
      END IF
    END IF
    WRITE (u, '(A)') '--- OUTPUTS ---'
    DO j = 1, 3
      IF (which(j)) WRITE (u, '(A,I0)') 'AnchTen', j
    END DO
    WRITE (u, '(A)') 'Point4Fx Point4Fy Point4Fz Point4FH'
    IF (clump) WRITE (u, '(A)') 'Point4pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE run(path, root, ncol, dat, ok)
    CHARACTER(*), INTENT(IN) :: path, root
    INTEGER, INTENT(IN) :: ncol
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: dat(:, :)
    LOGICAL, INTENT(OUT) :: ok
    LOGICAL :: conv
    INTEGER :: es, u, ios, nrow, i
    CHARACTER(512) :: em
    CHARACTER(2048) :: buf

    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
    CALL require(ok, 'deck '//path//' converged: '//TRIM(em))
    IF (.NOT. ok) RETURN
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='OLD', ACTION='READ')
    nrow = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    nrow = nrow - 2
    ALLOCATE (dat(ncol, nrow))
    REWIND (u)
    READ (u, '(A)') buf
    READ (u, '(A)') buf
    DO i = 1, nrow
      READ (u, *) dat(:, i)
    END DO
    CLOSE (u)
    ok = ALL(IEEE_IS_FINITE(dat))
    CALL require(ok, 'finite output of '//path)
  END SUBROUTINE run

  SUBROUTINE check_fixed_anchor(dynamic)
    LOGICAL, INTENT(IN) :: dynamic
    REAL(wp), ALLOCATABLE :: all3(:, :), one(:, :)
    REAL(wp), ALLOCATABLE :: fsum(:, :)
    REAL(wp) :: err, err_mag, scale
    LOGICAL :: ok, which(3)
    INTEGER :: j
    CHARACTER(32) :: tag

    tag = 'static'
    IF (dynamic) tag = 'dynamic'
    CALL write_deck('shared_anchor_all.dat', [.TRUE., .TRUE., .TRUE.], .FALSE., dynamic, dynamic)
    CALL run('shared_anchor_all.dat', 'shared_anchor_all', 8, all3, ok)
    IF (.NOT. ok) RETURN
    ALLOCATE (fsum(3, SIZE(all3, 2)))
    fsum = 0.0_wp
    err_mag = 0.0_wp
    DO j = 1, 3
      which = .FALSE.
      which(j) = .TRUE.
      CALL write_deck('shared_anchor_one.dat', which, .FALSE., dynamic, dynamic)
      CALL run('shared_anchor_one.dat', 'shared_anchor_one', 6, one, ok)
      IF (.NOT. ok) RETURN
      CALL require(SIZE(one, 2) == SIZE(all3, 2), 'single-line run has the shared run''s rows')
      IF (SIZE(one, 2) /= SIZE(all3, 2)) RETURN
      fsum = fsum + one(3:5, :)
      err_mag = MAX(err_mag, nan_max_abs((SQRT(SUM(one(3:5, :)**2, DIM=1)) - one(2, :))/one(2, :)))
    END DO
    scale = MAXVAL(all3(2:4, :))
    err = nan_max_abs(all3(5:7, :) - fsum)/scale
    WRITE (*, '(A,A,A,2ES11.3)') 'shared Fixed anchor (', TRIM(tag), '): |F - sum of single lines|/AnchTen, '// &
      '| |F_single| - AnchTen |/AnchTen = ', err, err_mag
    ! the .out columns carry 8 significant digits
    CALL require(err <= 5.0e-7_wp, 'shared anchor resultant equals the single-line superposition ('//TRIM(tag)//')')
    CALL require(err_mag <= 5.0e-7_wp, 'single-line anchor force has the AnchTen magnitude ('//TRIM(tag)//')')
    CALL require(nan_max_abs(all3(8, :) - SQRT(all3(5, :)**2 + all3(6, :)**2)) <= 5.0e-7_wp*scale, &
                 'Point4FH is the horizontal resultant')
  END SUBROUTINE check_fixed_anchor

  SUBROUTINE check_turbines_section()
    !! Turbine J at FAIR(:, J) - [0, 0, -10] with its fairlead at local (0, 0, -10); turbine 1
    !! surges as write_motion's fairlead 1, written as a per-turbine record.
    REAL(wp), ALLOCATABLE :: a(:, :), b(:, :), c(:, :)
    INTEGER :: u, j
    LOGICAL :: ok

    OPEN (NEWUNIT=u, FILE='shared_turbines.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Shared anchor: three turbines'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.1 20.0 1.0e9 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- TURBINES ---'
    WRITE (u, '(A)') 'J X0 Y0 Z0 PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw'
    DO j = 1, 3
      WRITE (u, '(I0,2(1X,F12.6),A)') j, FAIR(1, j), FAIR(2, j), ' 0 0 0 0 0 0 0'
    END DO
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    DO j = 1, 3
      WRITE (u, '(I0,A,I0,A)') j, ' Turbine', j, ' 0 0 -10 0 0 0 0'
    END DO
    WRITE (u, '(A,3(1X,F12.6),A)') '4 Fixed', ANCHOR, ' 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    DO j = 1, 3
      WRITE (u, '(I0,1X,I0,A)') j, j, ' 4 -'
    END DO
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    DO j = 1, 3
      WRITE (u, '(I0,A)') j, ' chain 380.0 20'
    END DO
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '0.1 dtM'
    WRITE (u, '(A)') '10.0 TMax'
    WRITE (u, '(A)') 'shared_turbines.motion motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'AnchTen1 AnchTen2 AnchTen3'
    WRITE (u, '(A)') 'Point4Fx Point4Fy Point4Fz Point4FH'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    ! malformed per-turbine records fail closed by name (the deck reads shared_turbines.motion)
    CALL write_turbine_motion(1)
    CALL expect_reject('shared_turbines.dat', 'J must be the integer id of a TURBINES row', 'non-integer J')
    CALL write_turbine_motion(2)
    CALL expect_reject('shared_turbines.dat', 'J must be the integer id of a TURBINES row', 'undeclared J')
    CALL write_turbine_motion(3)
    CALL expect_reject('shared_turbines.dat', 'unit norm', 'non-unit quaternion')
    CALL write_turbine_motion(4)
    CALL expect_reject('shared_turbines.dat', 'duplicate row for turbine 2', 'duplicate (J, time) row')
    CALL write_turbine_motion(0)
    CALL run('shared_turbines.dat', 'shared_turbines', 8, a, ok)
    IF (.NOT. ok) RETURN
    ! a record that runs 2 s past TMax is read to TMax: the same run, bit for bit
    CALL write_turbine_motion(5)
    CALL run('shared_turbines.dat', 'shared_turbines_long', 8, c, ok)
    IF (.NOT. ok) RETURN
    CALL require(SIZE(c, 2) == SIZE(a, 2), 'TURBINES record longer than TMax: the run has TMax''s rows')
    IF (SIZE(c, 2) /= SIZE(a, 2)) RETURN
    CALL require(.NOT. MAXVAL(ABS(c - a)) > 0.0_wp, 'TURBINES record longer than TMax: rows after TMax unused')
    CALL write_deck('shared_anchor_all.dat', [.TRUE., .TRUE., .TRUE.], .FALSE., .TRUE., .TRUE.)
    CALL run('shared_anchor_all.dat', 'shared_anchor_all', 8, b, ok)
    IF (.NOT. ok) RETURN
    CALL require(SIZE(a, 2) == SIZE(b, 2), 'TURBINES run has the coupled-point run''s rows')
    IF (SIZE(a, 2) /= SIZE(b, 2)) RETURN
    WRITE (*, '(A,ES11.3)') 'TURBINES deck vs coupled points: max relative difference ', &
      nan_max_abs(a - b)/nan_max_abs(b(2:4, :))
    CALL require(nan_max_abs(a - b) <= 5.0e-7_wp*nan_max_abs(b(2:4, :)), &
                 'TURBINES section and per-turbine motion reproduce the coupled-point deck')
  END SUBROUTINE check_turbines_section

  SUBROUTINE write_turbine_motion(variant)
    !! The per-turbine records; variant 1: J = 1.5 on the first row, 2: J = 4 (no such
    !! TURBINES row), 3: q0 = 0.5 (not a unit quaternion), 4: turbine 2's first row twice,
    !! 5: the record runs to 12 s, 2 s past the deck's TMax.
    INTEGER, INTENT(IN) :: variant
    CHARACTER(16) :: jtok
    INTEGER :: u, j, k
    REAL(wp) :: t, w, x, v, acc
    OPEN (NEWUNIT=u, FILE='shared_turbines.motion', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time J x y z q0 q1 q2 q3 vx vy vz wx wy wz ax ay az alx aly alz'
    w = 2.0_wp*3.14159265358979323846_wp/20.0_wp
    DO k = 0, MERGE(120, 100, variant == 5)
      t = 0.1_wp*REAL(k, wp)
      DO j = 1, 3
        x = FAIR(1, j)
        v = 0.0_wp
        acc = 0.0_wp
        IF (j == 1) THEN
          x = x + 2.5_wp*(1.0_wp - COS(w*t))
          v = 2.5_wp*w*SIN(w*t)
          acc = 2.5_wp*w*w*COS(w*t)
        END IF
        WRITE (jtok, '(I0)') j
        IF (k == 0 .AND. j == 1 .AND. variant == 1) jtok = '1.5'
        IF (k == 0 .AND. j == 1 .AND. variant == 2) jtok = '4'
        IF (k == 0 .AND. j == 1 .AND. variant == 3) THEN
          WRITE (u, '(F8.3,1X,A,3(1X,ES22.14),A,ES22.14,A,ES22.14,A)') t, TRIM(jtok), x, FAIR(2, j), 0.0_wp, &
            ' 0.5 0 0 0 ', v, ' 0 0 0 0 0 ', acc, ' 0 0 0 0 0'
          CYCLE
        END IF
        WRITE (u, '(F8.3,1X,A,3(1X,ES22.14),A,ES22.14,A,ES22.14,A)') t, TRIM(jtok), x, FAIR(2, j), 0.0_wp, &
          ' 1 0 0 0 ', v, ' 0 0 0 0 0 ', acc, ' 0 0 0 0 0'
        IF (k == 0 .AND. j == 2 .AND. variant == 4) &
          WRITE (u, '(F8.3,1X,A,3(1X,ES22.14),A,ES22.14,A,ES22.14,A)') t, TRIM(jtok), x, FAIR(2, j), 0.0_wp, &
          ' 1 0 0 0 ', v, ' 0 0 0 0 0 ', acc, ' 0 0 0 0 0'
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_turbine_motion

  SUBROUTINE expect_reject(path, fragment, label)
    CHARACTER(*), INTENT(IN) :: path, fragment, label
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL CD_Run_Deck_Driver(path, 'shared_turbines_bad', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, fragment) > 0, &
                 'TURBINES motion record with '//label//' fails closed: '//TRIM(em))
  END SUBROUTINE expect_reject

  SUBROUTINE check_free_clump()
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: w_sub, err, pen
    LOGICAL :: ok

    CALL write_deck('shared_clump.dat', [.TRUE., .TRUE., .TRUE.], .TRUE., .TRUE., .FALSE.)
    CALL run('shared_clump.dat', 'shared_clump', 9, d, ok)
    IF (.NOT. ok) RETURN
    w_sub = (20000.0_wp - RHO_W*2.0_wp)*GRAV
    ! the clump rests on the 100 m seabed on its own footprint, (2 m^3)^(2/3)
    pen = -100.0_wp - d(9, 1)
    CALL require(pen > 0.0_wp .AND. pen <= w_sub/(KBOT*2.0_wp**(2.0_wp/3.0_wp)), &
                 'shared free point: the clump rests on its footprint')
    err = NORM2(d(5:7, 1) + [0.0_wp, 0.0_wp, KBOT*2.0_wp**(2.0_wp/3.0_wp)*MAX(pen, 0.0_wp) - w_sub])/w_sub
    WRITE (*, '(A,ES11.3)') 'shared Free clump: |F_lines + seabed reaction + submerged weight|/weight = ', err
    ! the depth is printed to 8 digits (1e-5 m at 100 m), and kBot A 1e-5 m is 1e-5 of the weight
    CALL require(err <= 2.0e-5_wp, 'shared free point: line resultant and seabed reaction balance the '// &
                 'submerged weight')
  END SUBROUTINE check_free_clump
END PROGRAM test_shared_anchor
