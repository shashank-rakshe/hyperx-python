! File: tests/test_torsion_attachments.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> Deck-level gates of a line restrained in torsion with discrete ATTACHMENTS (the torsion stage
!> on the discrete equilibrium, after the attachment polish):
!>  1. neutral attachments (mass = rhoW volume, no drag) on the straight neutral line of
!>     test_torsion_deck held taut, two turns of pretwist: the torque and the twist are those of the
!>     bare line, GJ Phi / L and 720 deg;
!>  2. the lazy wave of tests/data/lazy_wave_torsion_attachments.dat (25 buoyancy modules, one turn
!>     of pretwist, Irn 1 kg m: the nodal twist), in still water and in a cross-flow current
!>     (the attachment drag of the twisted state, to a fixed point): a still 10 s run keeps the
!>     fairlead tension, the torque at both ends and the twist of its static start. A torsion
!>     stage on the smeared state, before the polish, leaves the discrete start untwisted and the
!>     run rings by 3e-3 of the torque;
!>  3. the mesh safety diagnosis of the twisted discrete start: a line of test_torsion_coupling
!>     (GJ|K, stretched by 1e-4, Phi = -45 deg, tensile_safety True) whose coupling force
!>     compresses it is refused with one neutral module as without it (the diagnosis of the
!>     untwisted smeared state alone would let it start).
!>
!> Usage: test_torsion_attachments <lazy_wave_torsion_attachments.dat>
PROGRAM test_torsion_attachments
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, RHOW = 1025.0_wp
  REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp
  INTEGER :: n_fail = 0
  CHARACTER(512) :: lazy_wave

  IF (COMMAND_ARGUMENT_COUNT() /= 1) THEN
    WRITE (*, '(A)') 'usage: test_torsion_attachments <lazy_wave_torsion_attachments.dat>'
    ERROR STOP 2
  END IF
  CALL GET_COMMAND_ARGUMENT(1, lazy_wave)
  CALL check_neutral()
  CALL check_still_lazy_wave('still water', '')
  CALL check_still_lazy_wave('cross-flow current', 'uniform 0.2 0.3 0.0 current')
  CALL check_tensile_safety()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' torsion attachment check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: torsion with ATTACHMENTS (neutral modules, still lazy wave in water and current)'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  SUBROUTINE run_deck(path, root, ok)
    CHARACTER(*), INTENT(IN) :: path, root
    LOGICAL, INTENT(OUT) :: ok
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(2048) :: em
    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
    IF (.NOT. ok) WRITE (*, '(A)') '  '//TRIM(path)//': '//TRIM(em)
  END SUBROUTINE run_deck

  SUBROUTINE read_rows(path, ncol, vals, nrow, ok)
    !! Every data row of a driver .out file (up to SIZE(vals, 2) rows), ncol columns each.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: ncol
    REAL(wp), INTENT(OUT) :: vals(:, :)
    INTEGER, INTENT(OUT) :: nrow
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: u, ios
    CHARACTER(2048) :: buf
    ok = .FALSE.
    nrow = 0
    vals = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO WHILE (nrow < SIZE(vals, 2))
      READ (u, *, IOSTAT=ios) vals(1:ncol, nrow + 1)
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    CLOSE (u)
    ok = nrow > 0 .AND. ALL(IEEE_IS_FINITE(vals(1:ncol, 1:nrow)))
  END SUBROUTINE read_rows

  SUBROUTINE write_straight(path, attachments)
    !! The straight neutral line of test_torsion_deck (100 m along +x at z = -50 from a Coupled End A
    !! to a Fixed End B, clamped, rigid in torsion, two turns of pretwist at End B; statics only), held
    !! taut at 0.5 % strain (a weightless line at zero strain has no unique static shape), with or
    !! without three neutral attachments.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: attachments
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'torsion with neutral attachments'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, &
      ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-12 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 100.5 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 100.0 40'
    IF (attachments) THEN
      WRITE (u, '(A)') '--- ATTACHMENTS ---'
      WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca'
      WRITE (u, '(A)') '(-) (m) (kg) (m3) (m2) (-)'
      WRITE (u, '(A)') '1 25.0:25.0:75.0 102.5 0.1 0.0 1.0'
    END IF
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '1 A Rigid 1 0 0 Rigid 0 0 1 0'
    WRITE (u, '(A)') '1 B Rigid 1 0 0 Rigid 0 0 1 720'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.1 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Torq1N1'
    WRITE (u, '(A)') 'Torq1N41'
    WRITE (u, '(A)') 'Twist1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_straight

  SUBROUTINE check_neutral()
    REAL(wp) :: bare(4, 1), att(4, 1), m_ref
    INTEGER :: nb, na
    LOGICAL :: ok
    CALL write_straight('tatt_bare.dat', .FALSE.)
    CALL write_straight('tatt_neutral.dat', .TRUE.)
    CALL run_deck('tatt_bare.dat', 'tatt_bare', ok)
    CALL require(ok, '1: the bare twisted line solves')
    IF (.NOT. ok) RETURN
    CALL run_deck('tatt_neutral.dat', 'tatt_neutral', ok)
    CALL require(ok, '1: the twisted line with neutral ATTACHMENTS solves')
    IF (.NOT. ok) RETURN
    CALL read_rows('tatt_bare.out', 4, bare, nb, ok)
    CALL require(ok, '1: bare output')
    CALL read_rows('tatt_neutral.out', 4, att, na, ok)
    CALL require(ok, '1: neutral-attachment output')
    IF (.NOT. ok) RETURN
    m_ref = GJ*(4.0_wp*PI)/L
    WRITE (*, '(A,3ES16.8,A,3ES16.8,A,ES16.8)') '1 neutral modules: Torq A, B, Twist ', att(2:4, 1), &
      '; bare ', bare(2:4, 1), '; GJ Phi / L ', m_ref
    CALL require(MAXVAL(ABS(att(2:3, 1) - m_ref)) <= 1.0e-6_wp*m_ref .AND. ABS(att(4, 1) - 720.0_wp) <= 1.0e-6_wp, &
                 '1: neutral modules leave the torque GJ Phi / L and the twist 720 deg')
    CALL require(MAXVAL(ABS(att(2:4, 1) - bare(2:4, 1))) <= 1.0e-9_wp*m_ref, &
                 '1: neutral modules reproduce the bare line')
  END SUBROUTINE check_neutral

  SUBROUTINE check_still_lazy_wave(label, option)
    !! The lazy wave deck, optionally with one more OPTIONS row, run still for 10 s.
    CHARACTER(*), INTENT(IN) :: label, option
    INTEGER, PARAMETER :: MAXROW = 1000
    REAL(wp), ALLOCATABLE :: vals(:, :)
    REAL(wp) :: spread(4)
    INTEGER :: nrow, j
    LOGICAL :: ok
    CHARACTER(64) :: path, root
    root = 'tatt_lw_'//MERGE('still  ', 'current', LEN_TRIM(option) == 0)
    path = TRIM(root)//'.dat'
    CALL copy_with_option(TRIM(lazy_wave), TRIM(path), option, ok)
    CALL require(ok, '2 '//label//': the deck is written')
    IF (.NOT. ok) RETURN
    CALL run_deck(TRIM(path), TRIM(root), ok)
    CALL require(ok, '2 '//label//': the lazy wave with modules and torsion solves and runs')
    IF (.NOT. ok) RETURN
    ALLOCATE (vals(5, MAXROW))
    CALL read_rows(TRIM(root)//'.out', 5, vals, nrow, ok)
    CALL require(ok .AND. nrow == 401, '2 '//label//': 401 output rows')
    IF (.NOT. ok) RETURN
    DO j = 1, 4
      spread(j) = (MAXVAL(vals(j + 1, 1:nrow)) - MINVAL(vals(j + 1, 1:nrow)))/ABS(vals(j + 1, 1))
    END DO
    WRITE (*, '(A,A,A,4ES14.6,A,4ES10.2)') '2 ', label, ': FairTen, Torq A, Torq B, Twist ', vals(2:5, 1), &
      '; relative spread over 10 s ', spread
    CALL require(ABS(vals(5, 1)) > 300.0_wp, '2 '//label//': the static start is twisted (one turn of pretwist)')
    CALL require(MAXVAL(spread) <= 1.0e-6_wp, '2 '//label//': a still run keeps the twisted discrete static start')
  END SUBROUTINE check_still_lazy_wave

  SUBROUTINE check_tensile_safety()
    !! The coupled line of test_torsion_coupling's compression gate with one neutral module.
    INTEGER :: u
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(2048) :: em
    OPEN (NEWUNIT=u, FILE='tatt_comp.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'torsion with attachments under tensile_safety'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, &
      ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4|4.0e5 1.0 1.0e-9 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 99.9900 40'
    WRITE (u, '(A)') '--- ATTACHMENTS ---'
    WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca'
    WRITE (u, '(A)') '(-) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 50.0 102.5 0.1 0.0 1.0'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '1 A Rigid 1 0 0 Rigid 0 0 1 0'
    WRITE (u, '(A)') '1 B Rigid 1 0 0 Rigid 0 0 1 -45'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') 'True tensile_safety'
    WRITE (u, '(A)') '0.1 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL CD_Run_Deck_Driver('tatt_comp.dat', 'tatt_comp', conv, es, em)
    WRITE (*, '(A)') '3 tensile_safety with a neutral module: '//TRIM(em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'twisted discrete equilibrium carries axial compression') > 0, &
                 '3: the coupling-compressed twisted start with ATTACHMENTS is refused under tensile_safety True')
  END SUBROUTINE check_tensile_safety

  SUBROUTINE copy_with_option(src, dst, option, ok)
    !! Copy deck src to dst, inserting the row option after the TMax row (none if blank).
    CHARACTER(*), INTENT(IN) :: src, dst, option
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: ui, uo, ios
    CHARACTER(512) :: buf
    ok = .FALSE.
    OPEN (NEWUNIT=ui, FILE=src, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    OPEN (NEWUNIT=uo, FILE=dst, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    IF (ios /= 0) THEN
      CLOSE (ui)
      RETURN
    END IF
    DO
      READ (ui, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      WRITE (uo, '(A)') TRIM(buf)
      IF (LEN_TRIM(option) > 0 .AND. INDEX(buf, 'TMax') > 0) WRITE (uo, '(A)') option
    END DO
    CLOSE (ui)
    CLOSE (uo)
    ok = .TRUE.
  END SUBROUTINE copy_with_option

END PROGRAM test_torsion_attachments
