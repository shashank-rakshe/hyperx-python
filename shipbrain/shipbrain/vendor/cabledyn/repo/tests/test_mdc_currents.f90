! File: tests/test_mdc_currents.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> MoorDyn-C time-varying and gridded currents (Currents 2, current_profile_dynamic.txt, and
!> Currents 5, current_profile_4d.txt) on the shared inputs of tests/data/currents_mdc: the deck
!> current CableDyn samples (CD_Deck_Fluid_Probe) at given points and times against
!>  - MoorDyn-C v2.7.1 itself (ref_moordyn_c.csv, validation/scripts/wavekin_mdc_probe.cpp) and an
!>    independent Python evaluation of the files (ref_python.csv,
!>    validation/scripts/currents_mdc_reference.py), both to 1e-14 m/s: a time-varying depth
!>    profile with uneven times (c2, sampled past the table's last time, where MoorDyn-C's grid
!>    repeats), single-precision depths and x velocities only (c2stof), a grid uniform in x and y
!>    (c5uniform) and a grid sheared in x, y and z and varying in time (c5); the current has no
!>    acceleration, as in MoorDyn-C;
!>  - a second source of the same field: Currents 2 with the steady profile of current_profile.txt
!>    at every time (c2const) equals Currents 1 (c1) to round-off, and the grid uniform in x and y
!>    (c5uniform) equals the Currents 2 profile (c2) to round-off, inside and beyond its x-y span;
!>  - a line-6 data row of current_profile_4d.txt (the layout of MoorDyn-C's documentation) is a
!>    grid point, not a header;
!>  - malformed tables, Currents 3 and 4 (no current source in MoorDyn-C v2.7.1) and a second
!>    current source fail closed by name.
PROGRAM test_mdc_currents
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Deck_Fluid_Probe, CD_DECKDRV_OK
  IMPLICIT NONE
  INTEGER :: n_fail = 0
  CHARACTER(*), PARAMETER :: CASES(6) = [CHARACTER(9) :: 'c1', 'c2const', 'c2', 'c2stof', 'c5uniform', 'c5']
  INTEGER :: k

  DO k = 1, SIZE(CASES)
    CALL check_reference(TRIM(CASES(k)), 'ref_moordyn_c.csv', 'MoorDyn-C v2.7.1')
    CALL check_reference(TRIM(CASES(k)), 'ref_python.csv', 'the Python evaluation')
  END DO
  CALL check_same_field('c2const', 'c1', 1, 'Currents 2 (a constant table) vs Currents 1')
  CALL check_same_field('c5uniform', 'c2', 2, 'Currents 5 (uniform in x and y) vs Currents 2')
  CALL check_line6_row()
  CALL check_rejections()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' MoorDyn-C current gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: MoorDyn-C Currents 2 and 5 match MoorDyn-C and the independent evaluation'

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

  SUBROUTINE read_reference(path, ref, ok)
    !! The rows "t,x,y,z,zeta,ux,uy,uz,ax,ay,az" of a probe CSV into ref(11, n).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: ref(:, :)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: u, ios, n, i
    CHARACTER(1024) :: buf
    ok = .FALSE.
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    n = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(buf) > 0) n = n + 1
    END DO
    REWIND (u)
    READ (u, '(A)') buf
    ALLOCATE (ref(11, n - 1))
    DO i = 1, n - 1
      READ (u, *, IOSTAT=ios) ref(:, i)
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
    END DO
    CLOSE (u)
    ok = n > 1
  END SUBROUTINE read_reference

  SUBROUTINE probe(deck, ref, vel, acc, ok)
    !! The deck current at the reference rows' points and times.
    CHARACTER(*), INTENT(IN) :: deck
    REAL(wp), INTENT(IN) :: ref(:, :)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: vel(:, :), acc(:, :)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), ALLOCATABLE :: eta(:)
    INTEGER :: es
    CHARACTER(512) :: em
    ALLOCATE (eta(SIZE(ref, 2)), vel(3, SIZE(ref, 2)), acc(3, SIZE(ref, 2)))
    CALL CD_Deck_Fluid_Probe(deck, ref(2:4, :), ref(1, :), eta, vel, acc, es, em)
    ok = es == CD_DECKDRV_OK
    CALL require(ok, deck//': deck current evaluated: '//TRIM(em))
  END SUBROUTINE probe

  SUBROUTINE check_reference(case, csv, label)
    CHARACTER(*), INTENT(IN) :: case, csv, label
    REAL(wp), ALLOCATABLE :: ref(:, :), vel(:, :), acc(:, :)
    REAL(wp) :: e_vel, e_acc
    LOGICAL :: ok
    CALL read_reference('../currents_mdc/'//case//'/'//csv, ref, ok)
    CALL require(ok, case//': reference '//csv//' readable')
    IF (.NOT. ok) RETURN
    CALL probe('../currents_mdc/'//case//'/currents.dat', ref, vel, acc, ok)
    IF (.NOT. ok) RETURN
    e_vel = nan_max_abs(vel - ref(6:8, :))
    e_acc = nan_max_abs(acc - ref(9:11, :))
    WRITE (*, '(A,A,A,A,A,A,I0,A,ES10.3,A,ES10.3,A,ES10.3,A)') case, ' vs ', label, ' (', csv, ', ', SIZE(ref, 2), &
      ' samples): velocity ', e_vel, ' m/s of ', nan_max_abs(ref(6:8, :)), ' m/s, acceleration ', e_acc, ' m/s^2'
    CALL require(e_vel <= 1.0e-14_wp, case//': the current matches '//label)
    CALL require(e_acc <= 0.0_wp, case//': the current has no acceleration, as in '//label)
  END SUBROUTINE check_reference

  SUBROUTINE check_same_field(case, other, repeat, label)
    !! The current of case at the points of its reference equals that of other at the same depths
    !! and times: each row of other's reference stands for repeat consecutive rows of case's (the
    !! uniform grid's points are other's and points far outside its x-y span).
    CHARACTER(*), INTENT(IN) :: case, other, label
    INTEGER, INTENT(IN) :: repeat
    REAL(wp), ALLOCATABLE :: ref(:, :), ref_o(:, :), vel(:, :), acc(:, :), vel_o(:, :), acc_o(:, :)
    REAL(wp) :: err
    INTEGER :: i, j
    LOGICAL :: ok, ok_o
    CALL read_reference('../currents_mdc/'//case//'/ref_python.csv', ref, ok)
    CALL read_reference('../currents_mdc/'//other//'/ref_python.csv', ref_o, ok_o)
    CALL require(ok .AND. ok_o, label//': points readable')
    IF (.NOT. (ok .AND. ok_o)) RETURN
    CALL require(SIZE(ref, 2) == repeat*SIZE(ref_o, 2), label//': point sets correspond')
    IF (SIZE(ref, 2) /= repeat*SIZE(ref_o, 2)) RETURN
    CALL probe('../currents_mdc/'//case//'/currents.dat', ref, vel, acc, ok)
    CALL probe('../currents_mdc/'//other//'/currents.dat', ref_o, vel_o, acc_o, ok_o)
    IF (.NOT. (ok .AND. ok_o)) RETURN
    err = 0.0_wp
    DO i = 1, SIZE(ref_o, 2)
      DO j = 1, repeat
        CALL require(ref(1, repeat*(i - 1) + j) == ref_o(1, i) .AND. ref(4, repeat*(i - 1) + j) == ref_o(4, i), &
                     label//': the same time and depth')
        err = MAX(err, nan_max_abs(vel(:, repeat*(i - 1) + j) - vel_o(:, i)))
      END DO
    END DO
    WRITE (*, '(A,A,I0,A,ES10.3,A)') label, ' (', SIZE(ref, 2), ' samples): velocity ', err, ' m/s'
    CALL require(err <= 4.0_wp*EPSILON(1.0_wp), label//': the same current to round-off')
  END SUBROUTINE check_same_field

  SUBROUTINE write_deck(path, currents, extra_option)
    !! A one-line probe deck with the given Currents row (and an optional extra OPTIONS row).
    CHARACTER(*), INTENT(IN) :: path, currents
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra_option
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '--------------------- MoorDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'MoorDyn-C current table checks'
    WRITE (u, '(A)') '----------------------- LINE TYPES ------------------------------------------'
    WRITE (u, '(A)') 'TypeName   Diam    Mass/m     EA         BA/-zeta    EI         Cd     Ca     CdAx    CaAx'
    WRITE (u, '(A)') '(name)     (m)     (kg/m)     (N)        (N-s/-)     (N-m^2)    (-)    (-)    (-)     (-)'
    WRITE (u, '(A)') 'chain      0.1     50.0       1.0e7      0.0         0          1.2    1.0    0.2     0.0'
    WRITE (u, '(A)') '---------------------- POINT PROPERTIES --------------------------------'
    WRITE (u, '(A)') 'ID    Type      X       Y       Z       Mass   Volume  CdA    Ca'
    WRITE (u, '(A)') '(#)   (-)       (m)     (m)     (m)     (kg)   (m^3)   (m^2)  (-)'
    WRITE (u, '(A)') '1     Fixed     -30.0   0.0     -20.0   0      0       0      0'
    WRITE (u, '(A)') '2     Vessel    30.0    0.0     -20.0   0      0       0      0'
    WRITE (u, '(A)') '---------------------- LINES ----------------------------------------'
    WRITE (u, '(A)') 'ID   LineType   AttachA  AttachB  UnstrLen  NumSegs  LineOutputs'
    WRITE (u, '(A)') '(#)   (name)     (#)      (#)       (m)       (-)     (-)'
    WRITE (u, '(A)') '1     chain      2        1         70.0      20      -'
    WRITE (u, '(A)') '---------------------- OPTIONS -----------------------------------------'
    WRITE (u, '(A)') '0.002         dtM'
    WRITE (u, '(A)') '10.0          TMax'
    WRITE (u, '(A)') '50            WtrDpth'
    WRITE (u, '(A)') currents//'             Currents'
    IF (PRESENT(extra_option)) WRITE (u, '(A)') extra_option
    WRITE (u, '(A)') '------------------------- need this line --------------------------------------'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE write_text(path, lines)
    CHARACTER(*), INTENT(IN) :: path, lines(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    DO i = 1, SIZE(lines)
      WRITE (u, '(A)') TRIM(lines(i))
    END DO
    CLOSE (u)
  END SUBROUTINE write_text

  SUBROUTINE check_line6_row()
    !! current_profile_4d.txt with its first grid point on line 6, as MoorDyn-C's documentation
    !! lays the file out: that row is read (MoorDyn-C v2.7.1 starts at line 7 and leaves the point
    !! at zero), so the current at the corner (x, y, z, t) = (-1, -2, -3, 0) is the row's.
    REAL(wp) :: pos(3, 2), t(2), eta(2), vel(3, 2), acc(3, 2)
    INTEGER :: es
    CHARACTER(512) :: em
    CALL write_deck('mdc_line6.dat', '5')
    CALL write_text('current_profile_4d.txt', [CHARACTER(40) :: '2 2 2 2', '-1 1', '-2 2', '-3 0', '0 15', &
                                         '-1 -2 -3 0 0.7 -0.2 0.05', '-1 -2 0 0 0.0 0.0 0.0', '-1 2 -3 0 0.0 0.0 0.0', &
                                              '-1 2 0 0 0.0 0.0 0.0', '1 -2 -3 0 0.0 0.0 0.0', '1 -2 0 0 0.0 0.0 0.0', &
                                           '1 2 -3 0 0.0 0.0 0.0', '1 2 0 0 0.0 0.0 0.0', '-1 -2 -3 15 -0.5 -0.5 0.0', &
                                    '-1 -2 -0 15 -1.0 -1.0 0.0', '-1 2 -3 15 -0.5 0.5 0.0', '-1 2 -0 15 -1.0 1.0 0.0', &
                                        '1 -2 -3 15 0.5 -0.5 0.0', '1 -2 -0 15 1.0 -1.0 0.0', '1 2 -3 15 0.5 0.5 0.0', &
                                               '1 2 -0 15 1.0 1.0 0.0'])
    pos(:, 1) = [-5.0_wp, -7.0_wp, -9.0_wp]
    pos(:, 2) = [3.0_wp, 4.0_wp, 1.0_wp]
    t = [0.0_wp, 7.5_wp]
    CALL CD_Deck_Fluid_Probe('mdc_line6.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es == CD_DECKDRV_OK, 'line-6 row: evaluated: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    WRITE (*, '(A,3ES12.4,A,3ES12.4)') 'line-6 row: corner current ', vel(:, 1), '; (1, 2, 0) at 7.5 s ', vel(:, 2)
    CALL require(nan_max_abs(vel(:, 1) - [0.7_wp, -0.2_wp, 0.05_wp]) <= 0.0_wp, &
                 'line-6 row: the first grid point is the row on line 6')
    ! "-0" is the coordinate 0 (matched by value): half of the 15 s value at the (1, 2, 0) corner
    CALL require(nan_max_abs(vel(:, 2) - [0.5_wp, 0.5_wp, 0.0_wp]) <= 1.0e-15_wp, &
                 'line-6 row: a "-0" coordinate is the grid coordinate 0')
  END SUBROUTINE check_line6_row

  SUBROUTINE expect_failure(currents, file, lines, needle, extra_option)
    !! The deck with the given Currents row and the table lines written to file fails, naming needle.
    CHARACTER(*), INTENT(IN) :: currents, file, lines(:), needle
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra_option
    REAL(wp) :: pos(3, 1), t(1), eta(1), vel(3, 1), acc(3, 1)
    INTEGER :: es
    CHARACTER(512) :: em
    pos = 0.0_wp
    pos(3, 1) = -5.0_wp
    t = 0.0_wp
    IF (PRESENT(extra_option)) THEN
      CALL write_deck('mdc_fail.dat', currents, extra_option)
    ELSE
      CALL write_deck('mdc_fail.dat', currents)
    END IF
    IF (LEN_TRIM(file) > 0) CALL write_text(file, lines)
    CALL CD_Deck_Fluid_Probe('mdc_fail.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, needle) > 0, 'Currents '//currents// &
                 ' fails closed naming "'//needle//'": '//TRIM(em))
  END SUBROUTINE expect_failure

  SUBROUTINE check_rejections()
    CHARACTER(*), PARAMETER :: DYN = 'current_profile_dynamic.txt', G4 = 'current_profile_4d.txt'
    CHARACTER(40), PARAMETER :: HEAD(4) = [CHARACTER(40) :: 'MoorDyn dynamic currents', 'header', '', '']
    CALL expect_failure('3', '', [CHARACTER(1) :: ' '], 'no current source in MoorDyn-C v2.7.1')
    CALL expect_failure('4', '', [CHARACTER(1) :: ' '], 'no current source in MoorDyn-C v2.7.1')
    ! Currents 2: a row with a partial velocity set, times out of order, one time row, depths
    ! out of order, a non-number
    CALL expect_failure('2', DYN, [CHARACTER(40) :: HEAD, '-10 0', 'h', '0 0.1 0.2', '5 0.1 0.2 0.3'], &
                        'found 4')
    CALL expect_failure('2', DYN, [CHARACTER(40) :: HEAD, '-10 0', 'h', '5 0.1 0.2', '0 0.1 0.2'], &
                        'times must be strictly increasing')
    CALL expect_failure('2', DYN, [CHARACTER(40) :: HEAD, '-10 0', 'h', '0 0.1 0.2'], 'at least two time rows')
    CALL expect_failure('2', DYN, [CHARACTER(40) :: HEAD, '0 -10', 'h', '0 0.1 0.2', '5 0.1 0.2'], &
                        'depths must be strictly increasing')
    CALL expect_failure('2', DYN, [CHARACTER(40) :: HEAD, '-10 0', 'h', '0 0.1 0.2', '5 0.1 1/2'], &
                        'is not a plain finite number')
    CALL expect_failure('2', DYN, [CHARACTER(40) :: HEAD, '-10 0', 'h', '0 0.1 0.2', '5 0.1 0.2'], &
                        'double-counting', 'uniform 0.2 0 0   current')
    ! Currents 5: a missing, a repeated and an off-grid point, one time, a short coordinate line
    CALL expect_failure('5', G4, [CHARACTER(40) :: '1 1 1 2', '0', '0', '0', '0 5', '0 0 0 0 0.1 0 0'], &
                        'has no row for the grid point')
    CALL expect_failure('5', G4, [CHARACTER(40) :: '1 1 1 2', '0', '0', '0', '0 5', '0 0 0 0 0.1 0 0', &
                                  '0 0 0 0 0.1 0 0'], 'repeats a grid point')
    CALL expect_failure('5', G4, [CHARACTER(40) :: '1 1 1 2', '0', '0', '0', '0 5', '0 0 0 0 0.1 0 0', &
                                  '0 0 0 6 0.1 0 0'], 'off the grid')
    CALL expect_failure('5', G4, [CHARACTER(40) :: '1 1 1 1', '0', '0', '0', '0', '0 0 0 0 0.1 0 0'], &
                        'at least two times')
    CALL expect_failure('5', G4, [CHARACTER(40) :: '2 1 1 2', '0', '0', '0', '0 5', '0 0 0 0 0.1 0 0'], &
                        'must list the 2 x coordinates')
    CALL expect_failure('5', G4, [CHARACTER(40) :: '1 1 2 2', '0', '0', '0 -1', '0 5', '0 0 0 0 0.1 0 0'], &
                        'coordinates must be strictly increasing')
  END SUBROUTINE check_rejections
END PROGRAM test_mdc_currents
