! File: tests/test_wavekin_modes.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> MoorDyn-C water-kinematics OPTIONS (WaveKin 3 and 7, Currents 1) against MoorDyn-C v2.7.1 on
!> shared inputs (tests/data/wavekin_mdc, reference rows from validation/scripts/
!> wavekin_mdc_probe.cpp): the deck water kinematics CableDyn samples (CD_Deck_Fluid_Probe) at the
!> points and times MoorDyn-C reported.
!>  - WaveKin 7 (component sum at the node, both codes): elevation, velocity and acceleration
!>    identical to 1e-6 of their scale (MoorDyn-C's wave number is Newman's seven-digit
!>    approximation, CableDyn's the dispersion root);
!>  - WaveKin 3 (elevation record reduced to Fourier components): at the grid points and wave
!>    time samples, where MoorDyn-C's grid interpolation is exact, the elevation within 1e-6 m
!>    (MoorDyn-C's own reconstruction departs from the exact record by up to 3e-7 m; CableDyn's
!>    equals the record's two harmonics to 1e-10 m), and velocity and acceleration, which
!>    MoorDyn-C interpolates in the stretched depth on its 0.25 m grid, within 1e-3 of their
!>    scale;
!>  - a mean level (tests/data/wavekin_mdc_mean, MoorDyn-C v2.7.2): an omega = 0 row of 0.8 m
!>    under six WaveKin 7 components in six directions, and the WaveKin 3 record raised by
!>    0.8 m. MoorDyn-C adds the level to the elevation alone, which its stretching then maps, and
!>    keeps the wave numbers of WtrDpth; CableDyn matches it to the tolerances above (WaveKin 7
!>    to 1e-8). Taking
!>    the wave numbers at WtrDpth plus the level, as 0.4.0 did, put WaveKin 7 7.7e-3 m off in
!>    elevation and 1e-2 of its scale in velocity, and WaveKin 3 2.2e-4 m and 6e-3;
!>  - WvHiCOff: 1 rad/s keeps only the record's 8 s harmonic, exactly; none keeps both, as the
!>    0.5 Hz default does (the record has nothing above it);
!>  - Currents 1: identical to 1e-12 m/s;
!>  - WaveKin 7 rows of different directions, across the quadrants: the elevation is the sum of
!>    the two single-direction seas and the velocity, acceleration likewise at the depth stretched
!>    by the total elevation, to round-off; the beta of the omega = 0 row has no effect;
!>  - WaveRefX, WaveRefY: an elevation record or a component file referred to a point equals the
!>    same sea with the deck translated by it, for WaveKin 3 and 7 and WaterKin WaveKinMod 1;
!>  - the MoorDyn-C modes CableDyn does not support, and a reference point with no record to
!>    place, fail closed by name.
PROGRAM test_wavekin_modes
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Deck_Fluid_Probe, CD_DECKDRV_OK
  IMPLICIT NONE
  INTEGER :: n_fail = 0

  CALL check_mode('wavekin_mdc/wavekin7.dat', 'wavekin_mdc/mdc_wavekin7.csv', 'WaveKin 7', 1.0e-6_wp, &
                  1.0e-6_wp, 1.0e-6_wp)
  CALL check_mode('wavekin_mdc/wavekin3.dat', 'wavekin_mdc/mdc_wavekin3.csv', 'WaveKin 3', 1.0e-6_wp, &
                  1.0e-3_wp, 1.0e-3_wp)
  CALL check_mode('wavekin_mdc_mean/wavekin7.dat', 'wavekin_mdc_mean/mdc_wavekin7.csv', 'WaveKin 7, mean level', &
                  1.0e-6_wp, 1.0e-6_wp, 1.0e-6_wp)
  CALL check_mode('wavekin_mdc_mean/wavekin3.dat', 'wavekin_mdc_mean/mdc_wavekin3.csv', 'WaveKin 3, mean level', &
                  1.0e-6_wp, 1.0e-3_wp, 1.0e-3_wp)
  CALL check_record()
  CALL check_cutoff()
  CALL check_mode('wavekin_mdc/currents1.dat', 'wavekin_mdc/mdc_currents1.csv', 'Currents 1', 1.0e-12_wp, &
                  1.0e-12_wp, 1.0e-12_wp, absolute=.TRUE.)
  CALL check_short_crested()
  CALL check_reference_point()
  CALL check_rejections()
  CALL check_still_water_ramp()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' water-kinematics gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: MoorDyn-C WaveKin 3/7 and Currents 1 kinematics match MoorDyn-C'

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

  SUBROUTINE check_mode(deck, csv, label, tol_eta, tol_vel, tol_acc, absolute)
    CHARACTER(*), INTENT(IN) :: deck, csv, label
    REAL(wp), INTENT(IN) :: tol_eta, tol_vel, tol_acc
    LOGICAL, INTENT(IN), OPTIONAL :: absolute
    REAL(wp), ALLOCATABLE :: ref(:, :), eta(:), vel(:, :), acc(:, :)
    REAL(wp) :: e_eta, e_vel, e_acc, s_eta, s_vel, s_acc
    INTEGER :: es, n
    LOGICAL :: ok, abs_err
    CHARACTER(512) :: em
    abs_err = .FALSE.
    IF (PRESENT(absolute)) abs_err = absolute
    CALL read_reference(csv, ref, ok)
    CALL require(ok, label//': MoorDyn-C reference '//csv//' readable')
    IF (.NOT. ok) RETURN
    n = SIZE(ref, 2)
    ALLOCATE (eta(n), vel(3, n), acc(3, n))
    CALL CD_Deck_Fluid_Probe(deck, ref(2:4, :), ref(1, :), eta, vel, acc, es, em)
    CALL require(es == CD_DECKDRV_OK, label//': deck water kinematics evaluated: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    e_eta = nan_max_abs(eta - ref(5, :))
    e_vel = nan_max_abs(vel - ref(6:8, :))
    e_acc = nan_max_abs(acc - ref(9:11, :))
    s_eta = 1.0_wp
    s_vel = 1.0_wp
    s_acc = 1.0_wp
    IF (.NOT. abs_err) THEN
      s_vel = nan_max_abs(ref(6:8, :))
      s_acc = nan_max_abs(ref(9:11, :))
    END IF
    WRITE (*, '(A,A,I0,A,ES10.3,A,ES10.3,A,ES10.3,A)') label, ' vs MoorDyn-C (', n, ' samples): elevation ', &
      e_eta, ' m, velocity ', e_vel/s_vel, ', acceleration ', e_acc/s_acc, MERGE(' (absolute)', ' (relative)', &
                                                                                 abs_err)
    CALL require(e_eta <= tol_eta, label//': elevation matches MoorDyn-C')
    CALL require(e_vel <= tol_vel*s_vel, label//': velocity matches MoorDyn-C')
    CALL require(e_acc <= tol_acc*s_acc, label//': acceleration matches MoorDyn-C')
  END SUBROUTINE check_mode

  SUBROUTINE check_record()
    !! WaveKin 3 reproduces the recorded elevation 0.8 cos(2 pi t/8) + 0.4 sin(2 pi t/5 + 0.3) of
    !! wave_elevation.txt (a 40 s periodic record) at the origin, between the samples too.
    REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
    REAL(wp) :: pos(3, 7), t(7), eta(7), vel(3, 7), acc(3, 7), err
    INTEGER :: es, i
    CHARACTER(512) :: em
    pos = 0.0_wp
    pos(3, :) = -10.0_wp
    t = [0.0_wp, 0.37_wp, 1.23_wp, 5.55_wp, 13.01_wp, 27.7_wp, 39.95_wp]
    CALL CD_Deck_Fluid_Probe('wavekin_mdc/wavekin3.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es == CD_DECKDRV_OK, 'WaveKin 3 record check evaluated: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    err = 0.0_wp
    DO i = 1, SIZE(t)
      err = MAX(err, ABS(eta(i) - (0.8_wp*COS(2.0_wp*PI*t(i)/8.0_wp) + 0.4_wp*SIN(2.0_wp*PI*t(i)/5.0_wp + 0.3_wp))))
    END DO
    WRITE (*, '(A,ES10.3,A)') 'WaveKin 3 vs the recorded harmonics: elevation ', err, ' m'
    CALL require(err <= 1.0e-10_wp, 'WaveKin 3 reproduces the recorded elevation')
  END SUBROUTINE check_record

  SUBROUTINE check_cutoff()
    !! WvHiCOff drops the record's components above it: at 1 rad/s only 0.8 cos(2 pi t/8) of
    !! wave_elevation.txt is left; with none the record is reproduced as with the default.
    REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
    REAL(wp) :: pos(3, 5), t(5), eta(5), vel(3, 5), acc(3, 5), err_cut, err_none
    CHARACTER(1024) :: line
    INTEGER :: es, i, u_in, u_cut, u_none, ios
    CHARACTER(512) :: em
    OPEN (NEWUNIT=u_in, FILE='wavekin_mdc/wavekin3.dat', STATUS='OLD', ACTION='READ')
    OPEN (NEWUNIT=u_cut, FILE='wavekin_mdc/wavekin3_cut.dat', STATUS='REPLACE', ACTION='WRITE')
    OPEN (NEWUNIT=u_none, FILE='wavekin_mdc/wavekin3_none.dat', STATUS='REPLACE', ACTION='WRITE')
    DO
      READ (u_in, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      WRITE (u_cut, '(A)') TRIM(line)
      WRITE (u_none, '(A)') TRIM(line)
      IF (INDEX(line, 'dtWave') > 0) THEN
        WRITE (u_cut, '(A)') '1.0           WvHiCOff'
        WRITE (u_none, '(A)') 'none          WvHiCOff'
      END IF
    END DO
    CLOSE (u_in); CLOSE (u_cut); CLOSE (u_none)
    pos = 0.0_wp
    pos(3, :) = -10.0_wp
    t = [0.0_wp, 1.23_wp, 5.55_wp, 13.01_wp, 27.7_wp]
    CALL CD_Deck_Fluid_Probe('wavekin_mdc/wavekin3_cut.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es == CD_DECKDRV_OK, 'WvHiCOff 1 rad/s evaluated: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    err_cut = 0.0_wp
    DO i = 1, SIZE(t)
      err_cut = MAX(err_cut, ABS(eta(i) - 0.8_wp*COS(2.0_wp*PI*t(i)/8.0_wp)))
    END DO
    CALL CD_Deck_Fluid_Probe('wavekin_mdc/wavekin3_none.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es == CD_DECKDRV_OK, 'none WvHiCOff evaluated: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    err_none = 0.0_wp
    DO i = 1, SIZE(t)
      err_none = MAX(err_none, ABS(eta(i) - (0.8_wp*COS(2.0_wp*PI*t(i)/8.0_wp) + &
                                             0.4_wp*SIN(2.0_wp*PI*t(i)/5.0_wp + 0.3_wp))))
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'WvHiCOff: 1 rad/s vs the 8 s harmonic ', err_cut, ' m; none vs the record ', &
      err_none, ' m'
    CALL require(err_cut <= 1.0e-10_wp, 'WvHiCOff 1 rad/s keeps only the 8 s harmonic')
    CALL require(err_none <= 1.0e-10_wp, 'none WvHiCOff reproduces the record')
  END SUBROUTINE check_cutoff

  SUBROUTINE write_fail_deck(path, wavekin, currents, extra_option)
    !! The shared probe deck with the given WaveKin and Currents rows (and an optional extra
    !! OPTIONS row).
    CHARACTER(*), INTENT(IN) :: path, wavekin, currents
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra_option
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '--------------------- MoorDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'unsupported water-kinematics mode'
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
    WRITE (u, '(A)') wavekin//'             WaveKin'
    WRITE (u, '(A)') currents//'             Currents'
    IF (PRESENT(extra_option)) WRITE (u, '(A)') extra_option
    WRITE (u, '(A)') '------------------------- need this line --------------------------------------'
    CLOSE (u)
  END SUBROUTINE write_fail_deck

  SUBROUTINE expect_failure(wavekin, currents, needle)
    CHARACTER(*), INTENT(IN) :: wavekin, currents, needle
    REAL(wp) :: pos(3, 1), t(1), eta(1), vel(3, 1), acc(3, 1)
    INTEGER :: es
    CHARACTER(512) :: em
    pos = 0.0_wp
    pos(3, 1) = -5.0_wp
    t = 0.0_wp
    CALL write_fail_deck('wavekin_fail.dat', wavekin, currents)
    CALL CD_Deck_Fluid_Probe('wavekin_fail.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, needle) > 0, 'WaveKin '//wavekin//' Currents '//currents// &
                 ' fails closed naming "'//needle//'": '//TRIM(em))
  END SUBROUTINE expect_failure

  SUBROUTINE expect_row_failure(wavekin, row, needle)
    CHARACTER(*), INTENT(IN) :: wavekin, row, needle
    REAL(wp) :: pos(3, 1), t(1), eta(1), vel(3, 1), acc(3, 1)
    INTEGER :: es
    CHARACTER(512) :: em
    pos = 0.0_wp
    pos(3, 1) = -5.0_wp
    t = 0.0_wp
    CALL write_fail_deck('wavekin_fail.dat', wavekin, '0', row)
    CALL CD_Deck_Fluid_Probe('wavekin_fail.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, needle) > 0, 'WaveKin '//wavekin//' with '//row// &
                 ' fails closed naming "'//needle//'": '//TRIM(em))
  END SUBROUTINE expect_row_failure

  SUBROUTINE write_components(beta_a, beta_b, which, beta_mean)
    !! wave_frequencies.txt of two component sets, set a at direction beta_a and set b at beta_b
    !! (radians), in file order a then b, so that the frequencies do not ascend; which: 0 both,
    !! 1 a alone, 2 b alone. beta_mean: the direction of the omega = 0 row (default that of the
    !! first component).
    REAL(wp), INTENT(IN) :: beta_a, beta_b
    INTEGER, INTENT(IN) :: which
    REAL(wp), INTENT(IN), OPTIONAL :: beta_mean
    INTEGER :: u
    REAL(wp) :: b0
    b0 = MERGE(beta_b, beta_a, which == 2)
    IF (PRESENT(beta_mean)) b0 = beta_mean
    OPEN (NEWUNIT=u, FILE='wave_frequencies.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A,ES24.16)') '0.0 0.0 0.0 ', b0
    IF (which /= 2) THEN
      WRITE (u, '(A,ES24.16)') '0.6 0.7 0.2 ', beta_a
      WRITE (u, '(A,ES24.16)') '1.1 0.25 -0.3 ', beta_a
    END IF
    IF (which /= 1) THEN
      WRITE (u, '(A,ES24.16)') '0.6 -0.3 0.5 ', beta_b
      WRITE (u, '(A,ES24.16)') '0.9 0.4 0.1 ', beta_b
    END IF
    CLOSE (u)
  END SUBROUTINE write_components

  SUBROUTINE probe_components(beta_a, beta_b, which, pos, t, eta, vel, acc)
    REAL(wp), INTENT(IN) :: beta_a, beta_b, pos(:, :), t(:)
    INTEGER, INTENT(IN) :: which
    REAL(wp), INTENT(OUT) :: eta(:), vel(:, :), acc(:, :)
    INTEGER :: es
    CHARACTER(512) :: em
    CALL write_components(beta_a, beta_b, which)
    CALL write_fail_deck('wavekin_short.dat', '7', '0')
    CALL CD_Deck_Fluid_Probe('wavekin_short.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es == CD_DECKDRV_OK, 'WaveKin 7 component deck evaluated: '//TRIM(em))
  END SUBROUTINE probe_components

  SUBROUTINE check_short_crested()
    !! Rows of different directions against the two single-direction seas they are made of. The
    !! deck stretches each sea by its own elevation, so a single sea is probed at the depth that
    !! maps to the depth the total elevation stretches the point to.
    INTEGER, PARAMETER :: NP = 6, NPAIR = 6
    REAL(wp), PARAMETER :: D = 50.0_wp
    ! radians, within +-2 pi: the quadrants, the axes, and directions that are no multiple of 90 deg
    REAL(wp), PARAMETER :: PAIRS(2, NPAIR) = RESHAPE([0.0_wp, 1.5707963267948966_wp, 0.3_wp, 2.4_wp, -1.0_wp, 3.7_wp, &
                                                      5.1_wp, -2.2_wp, 3.141592653589793_wp, 4.71238898038469_wp, &
                                                      0.65_wp, -6.0_wp], [2, NPAIR])
    REAL(wp) :: pos(3, NP), t(NP), eta(NP), vel(3, NP), acc(3, NP), ea(NP), va(3, NP), aa(3, NP)
    REAL(wp) :: eb(NP), vb(3, NP), ab(3, NP), ze(NP), pa(3, NP), pb(3, NP), err_e, err_v, err_a, tmp(NP)
    REAL(wp) :: tmpv(3, NP), tmpa(3, NP), e0(NP), v0(3, NP), a0(3, NP)
    INTEGER :: ip, es
    CHARACTER(512) :: em
    pos(1, :) = [0.0_wp, 13.0_wp, -41.5_wp, 77.0_wp, -8.25_wp, 150.0_wp]
    pos(2, :) = [0.0_wp, -7.0_wp, 22.0_wp, 90.5_wp, -33.0_wp, -120.0_wp]
    pos(3, :) = [-2.0_wp, -5.0_wp, -11.0_wp, -20.0_wp, -33.0_wp, -46.0_wp]
    t = [0.0_wp, 1.7_wp, 3.3_wp, 5.9_wp, 7.1_wp, 9.8_wp]
    err_e = 0.0_wp
    err_v = 0.0_wp
    err_a = 0.0_wp
    DO ip = 1, NPAIR
      CALL probe_components(PAIRS(1, ip), PAIRS(2, ip), 0, pos, t, eta, vel, acc)
      CALL probe_components(PAIRS(1, ip), PAIRS(2, ip), 1, pos, t, ea, tmpv, tmpa)
      CALL probe_components(PAIRS(1, ip), PAIRS(2, ip), 2, pos, t, eb, tmpv, tmpa)
      err_e = MAX(err_e, MAXVAL(ABS(eta - ea - eb)))
      ze = (pos(3, :) - eta)*D/(D + eta)
      pa = pos
      pb = pos
      pa(3, :) = ze*(D + ea)/D + ea
      pb(3, :) = ze*(D + eb)/D + eb
      CALL probe_components(PAIRS(1, ip), PAIRS(2, ip), 1, pa, t, tmp, va, aa)
      CALL probe_components(PAIRS(1, ip), PAIRS(2, ip), 2, pb, t, tmp, vb, ab)
      err_v = MAX(err_v, MAXVAL(ABS(vel - va - vb)))
      err_a = MAX(err_a, MAXVAL(ABS(acc - aa - ab)))
    END DO
    WRITE (*, '(A,3ES10.3)') 'WaveKin 7 two directions vs two seas: elevation, velocity, acceleration ', err_e, &
      err_v, err_a
    CALL require(err_e <= 1.0e-13_wp, 'two directions: the elevation is the sum of the two seas')
    CALL require(err_v <= 1.0e-13_wp, 'two directions: the velocity is the sum of the two seas')
    CALL require(err_a <= 1.0e-13_wp, 'two directions: the acceleration is the sum of the two seas')
    ! the mean row carries no direction: a different beta there leaves a one-direction table
    CALL write_components(0.4_wp, 0.4_wp, 0)
    CALL write_fail_deck('wavekin_short.dat', '7', '0')
    CALL CD_Deck_Fluid_Probe('wavekin_short.dat', pos, t, e0, v0, a0, es, em)
    CALL require(es == CD_DECKDRV_OK, 'one direction evaluated: '//TRIM(em))
    CALL write_components(0.4_wp, 0.4_wp, 0, beta_mean=1.3_wp)
    CALL CD_Deck_Fluid_Probe('wavekin_short.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es == CD_DECKDRV_OK, 'mean-row direction evaluated: '//TRIM(em))
    CALL require(ALL(eta == e0) .AND. ALL(vel == v0) .AND. ALL(acc == a0), &
                 'the direction of the omega = 0 row has no effect')
  END SUBROUTINE check_short_crested

  SUBROUTINE copy_deck_with(source, target, match, row, replace)
    !! source with row after the line that holds match, or in its place (replace).
    CHARACTER(*), INTENT(IN) :: source, target, match, row
    LOGICAL, INTENT(IN) :: replace
    CHARACTER(1024) :: line
    INTEGER :: u_in, u_out, ios
    OPEN (NEWUNIT=u_in, FILE=source, STATUS='OLD', ACTION='READ')
    OPEN (NEWUNIT=u_out, FILE=target, STATUS='REPLACE', ACTION='WRITE')
    DO
      READ (u_in, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (INDEX(line, match) > 0) THEN
        IF (.NOT. replace) WRITE (u_out, '(A)') TRIM(line)
        WRITE (u_out, '(A)') row
      ELSE
        WRITE (u_out, '(A)') TRIM(line)
      END IF
    END DO
    CLOSE (u_in)
    CLOSE (u_out)
  END SUBROUTINE copy_deck_with

  SUBROUTINE compare_translated(plain, shifted, shift, label)
    !! The deck shifted, referred to the point shift, at positions p + shift, against the deck
    !! plain at p.
    CHARACTER(*), INTENT(IN) :: plain, shifted, label
    REAL(wp), INTENT(IN) :: shift(2)
    INTEGER, PARAMETER :: NP = 5
    REAL(wp) :: pos(3, NP), moved(3, NP), t(NP), e0(NP), v0(3, NP), a0(3, NP), e1(NP), v1(3, NP), a1(3, NP), err
    INTEGER :: es
    CHARACTER(512) :: em
    pos(1, :) = [0.0_wp, 11.0_wp, -37.0_wp, 60.5_wp, -5.0_wp]
    pos(2, :) = [0.0_wp, -3.5_wp, 19.0_wp, 44.0_wp, -71.0_wp]
    pos(3, :) = [-1.5_wp, -6.0_wp, -14.0_wp, -27.0_wp, -41.0_wp]
    t = [0.3_wp, 1.9_wp, 4.4_wp, 6.2_wp, 9.1_wp]
    moved = pos
    moved(1, :) = pos(1, :) + shift(1)
    moved(2, :) = pos(2, :) + shift(2)
    CALL CD_Deck_Fluid_Probe(plain, pos, t, e0, v0, a0, es, em)
    CALL require(es == CD_DECKDRV_OK, label//' plain deck evaluated: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL CD_Deck_Fluid_Probe(shifted, moved, t, e1, v1, a1, es, em)
    CALL require(es == CD_DECKDRV_OK, label//' referred deck evaluated: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    err = MAX(MAXVAL(ABS(e1 - e0)), MAXVAL(ABS(v1 - v0)), MAXVAL(ABS(a1 - a0)))
    WRITE (*, '(A,A,ES10.3)') label, ' referred to a point vs the deck translated: ', err
    CALL require(err <= 1.0e-12_wp, label//': a shifted reference point equals the deck translated')
    ! and the point matters: the same positions without the shift are another sea
    CALL CD_Deck_Fluid_Probe(shifted, pos, t, e1, v1, a1, es, em)
    CALL require(MAXVAL(ABS(e1 - e0)) > 1.0e-3_wp, label//': the reference point moves the sea')
  END SUBROUTINE compare_translated

  SUBROUTINE check_reference_point()
    REAL(wp), PARAMETER :: SHIFT(2) = [250.37_wp, -70.19_wp]
    CHARACTER(*), PARAMETER :: ROWS = '250.37 WaveRefX'//NEW_LINE('a')//'-70.19 WaveRefY'
    INTEGER :: u
    ! WaveKin 7, one direction and two
    CALL write_components(0.9_wp, 0.9_wp, 0)
    CALL write_fail_deck('wavekin_ref0.dat', '7', '0')
    CALL write_fail_deck('wavekin_ref1.dat', '7', '0', ROWS)
    CALL compare_translated('wavekin_ref0.dat', 'wavekin_ref1.dat', SHIFT, 'WaveKin 7')
    CALL write_components(0.65_wp, 2.9_wp, 0)
    CALL compare_translated('wavekin_ref0.dat', 'wavekin_ref1.dat', SHIFT, 'WaveKin 7, two directions')
    ! WaveKin 3
    CALL copy_deck_with('wavekin_mdc/wavekin3.dat', 'wavekin_mdc/wavekin3_ref.dat', 'dtWave', ROWS, .FALSE.)
    CALL compare_translated('wavekin_mdc/wavekin3.dat', 'wavekin_mdc/wavekin3_ref.dat', SHIFT, 'WaveKin 3')
    ! WaterKin WaveKinMod 1, along a direction off the axes
    OPEN (NEWUNIT=u, FILE='wavekin_mdc/waterkin_ref.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'MoorDyn v2 water kinematics file'
    WRITE (u, '(A)') '(header line 2)'
    WRITE (u, '(A)') '--------------------------- WAVES -------------------------------------'
    WRITE (u, '(A)') '1                    WaveKinMod'
    WRITE (u, '(A)') '"wave_elevation.txt" WaveKinFile'
    WRITE (u, '(A)') '0.1                  dtWave'
    WRITE (u, '(A)') '37.0                 WaveDir'
    WRITE (u, '(A)') '0                    X wave input'
    WRITE (u, '(A)') '0.0'
    WRITE (u, '(A)') '0                    Y wave input'
    WRITE (u, '(A)') '0.0'
    WRITE (u, '(A)') '0                    Z wave input'
    WRITE (u, '(A)') '0.0'
    WRITE (u, '(A)') '--------------------------- CURRENT -----------------------------------'
    WRITE (u, '(A)') '0                    CurrentMod'
    WRITE (u, '(A)') '0                    Z current'
    WRITE (u, '(A)') '0.0'
    WRITE (u, '(A)') '--------------------- need this line ----------------------------------'
    CLOSE (u)
    CALL copy_deck_with('wavekin_mdc/wavekin3.dat', 'wavekin_mdc/waterkin0.dat', 'WaveKin ', &
                        'waterkin_ref.dat WaterKin', .TRUE.)
    CALL copy_deck_with('wavekin_mdc/waterkin0.dat', 'wavekin_mdc/waterkin1.dat', 'WaterKin', &
                        'waterkin_ref.dat WaterKin'//NEW_LINE('a')//ROWS, .TRUE.)
    CALL compare_translated('wavekin_mdc/waterkin0.dat', 'wavekin_mdc/waterkin1.dat', SHIFT, 'WaterKin WaveKinMod 1')
  END SUBROUTINE check_reference_point

  SUBROUTINE check_still_water_ramp()
    !! rampTime is valid without waves (it also ramps prescribed motion). The still-water
    !! kinematics must then be exactly zero, including at t = 0 where the ramp is closed
    !! (r = 0, dr/dt = 0), with no 0/0 in the ramped-acceleration term.
    REAL(wp) :: pos(3, 3), t(3), eta(3), vel(3, 3), acc(3, 3)
    INTEGER :: es
    CHARACTER(512) :: em
    pos = 0.0_wp
    pos(3, :) = -5.0_wp
    t = [0.0_wp, 1.0_wp, 5.0_wp]
    CALL write_fail_deck('wavekin_ramp_still.dat', '0', '0', '4.0          rampTime')
    CALL CD_Deck_Fluid_Probe('wavekin_ramp_still.dat', pos, t, eta, vel, acc, es, em)
    CALL require(es == CD_DECKDRV_OK, 'still-water deck with rampTime probes: '//TRIM(em))
    CALL require(ALL(ABS(eta) <= 0.0_wp) .AND. ALL(ABS(vel) <= 0.0_wp) .AND. ALL(ABS(acc) <= 0.0_wp), &
                 'still water with rampTime: zero (and finite) kinematics at t = 0, inside and after the ramp')
  END SUBROUTINE check_still_water_ramp

  SUBROUTINE check_rejections()
    CALL expect_failure('1', '0', 'MoorDyn-C API')
    CALL expect_failure('2', '0', 'FFT_GRID')
    CALL expect_failure('4', '0', 'no kinematics source in MoorDyn-C')
    CALL expect_failure('6', '0', 'no kinematics source in MoorDyn-C')
    CALL expect_failure('0', '3', 'no current source in MoorDyn-C')
    CALL expect_failure('0', '4', 'no current source in MoorDyn-C')
    ! a reference point needs a record or component file to place, and a bounded position
    CALL write_components(0.4_wp, 0.4_wp, 0)
    CALL expect_row_failure('0', '1.0 WaveRefX', 'reference point')
    CALL expect_row_failure('0', '1.0 WaveRefY'//NEW_LINE('a')//'airy 2.0 8.0 0.0 waves', 'reference point')
    CALL expect_row_failure('7', '2.0e6 WaveRefX', 'at most 1e6 m')
    CALL expect_row_failure('7', 'nan WaveRefY', 'WaveRefY')
  END SUBROUTINE check_rejections
END PROGRAM test_wavekin_modes
