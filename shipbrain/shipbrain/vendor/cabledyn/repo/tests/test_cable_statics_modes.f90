! File: tests/test_cable_statics_modes.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cable_statics_modes
  !! OPTION cable_statics: the two finite-EI static routes, "continuation" (the default) and
  !! "sequenced", solve each shipped Lozon power cable (80 m, 200 m and 800 m) to the same
  !! equilibrium. Every channel of the deck's static output row (fairlead and anchor tension
  !! and inclination, a sag-bend curvature and bend moment) must agree between the two routes
  !! to RTOL of its magnitude, and a malformed mode fails closed by name.
  !! Argument: the examples directory.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  ! observed <= 6e-8 (the 8-digit output resolution); the bound leaves a factor of ~15
  REAL(wp), PARAMETER :: RTOL = 1.0e-6_wp
  CHARACTER(40), PARAMETER :: SITES(3) = [CHARACTER(40) :: 'lozon_gomex80_power_cable', &
                                                        'lozon_gomaine200_power_cable', 'lozon_humboldt800_power_cable']
  CHARACTER(512) :: examples
  INTEGER :: n_fail, is, alen, astat

  n_fail = 0
  CALL GET_COMMAND_ARGUMENT(1, examples, alen, astat)
  IF (astat /= 0 .OR. alen < 1) THEN
    WRITE (*, '(A)') 'usage: test_cable_statics_modes <examples directory>'
    ERROR STOP 2
  END IF
  DO is = 1, SIZE(SITES)
    CALL compare_modes(TRIM(SITES(is)))
  END DO
  CALL check_bad_mode()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' cable_statics check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: cable_statics continuation and sequenced routes agree on the Lozon cables'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', TRIM(label)
      n_fail = n_fail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE write_mode_deck(site, option_row, path)
    !! The shipped deck with option_row added as the first OPTIONS row.
    CHARACTER(*), INTENT(IN) :: site, option_row, path
    CHARACTER(1024) :: line
    INTEGER :: uin, uout, ios
    LOGICAL :: added
    OPEN (NEWUNIT=uin, FILE=TRIM(examples)//'/'//site//'.dat', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open the shipped deck '//site)
    IF (ios /= 0) RETURN
    OPEN (NEWUNIT=uout, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    added = .FALSE.
    DO
      READ (uin, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      WRITE (uout, '(A)') TRIM(line)
      IF (.NOT. added .AND. INDEX(line, '---') > 0 .AND. INDEX(line, 'OPTIONS') > 0) THEN
        WRITE (uout, '(A)') option_row
        added = .TRUE.
      END IF
    END DO
    CLOSE (uin)
    CLOSE (uout)
    CALL require(added, 'the shipped deck '//site//' has an OPTIONS section')
  END SUBROUTINE write_mode_deck

  SUBROUTINE run_row(path, root, vals, ok)
    !! Run the deck and return the numeric columns of its first output row.
    CHARACTER(*), INTENT(IN) :: path, root
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: vals(:)
    LOGICAL, INTENT(OUT) :: ok
    LOGICAL :: conv
    INTEGER :: es, u, ios, n, k
    CHARACTER(512) :: em
    CHARACTER(4096) :: hdr, row
    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
    CALL require(ok, root//' solves: '//TRIM(em))
    IF (.NOT. ok) RETURN
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    ok = ios == 0
    IF (.NOT. ok) RETURN
    READ (u, '(A)') hdr
    READ (u, '(A)') hdr
    READ (u, '(A)', IOSTAT=ios) row
    CLOSE (u)
    ok = ios == 0
    IF (.NOT. ok) RETURN
    n = 1
    DO k = 1, LEN_TRIM(hdr)
      IF (hdr(k:k) == CHAR(9)) n = n + 1
    END DO
    ALLOCATE (vals(n))
    READ (row, *, IOSTAT=ios) vals
    ok = ios == 0
  END SUBROUTINE run_row

  SUBROUTINE compare_modes(site)
    CHARACTER(*), INTENT(IN) :: site
    REAL(wp), ALLOCATABLE :: vc(:), vs(:)
    LOGICAL :: okc, oks
    REAL(wp) :: rel
    INTEGER :: k
    CALL write_mode_deck(site, 'continuation cable_statics', 'csm_'//site//'_cont.dat')
    CALL write_mode_deck(site, 'sequenced cable_statics', 'csm_'//site//'_seq.dat')
    CALL run_row('csm_'//site//'_cont.dat', 'csm_'//site//'_cont', vc, okc)
    CALL run_row('csm_'//site//'_seq.dat', 'csm_'//site//'_seq', vs, oks)
    IF (.NOT. (okc .AND. oks)) RETURN
    CALL require(SIZE(vc) == SIZE(vs) .AND. SIZE(vc) > 1, site//': both routes write the same channels')
    IF (SIZE(vc) /= SIZE(vs)) RETURN
    rel = 0.0_wp
    DO k = 2, SIZE(vc)
      rel = MAX(rel, ABS(vc(k) - vs(k))/MAX(ABS(vc(k)), ABS(vs(k)), 1.0e-12_wp))
    END DO
    WRITE (*, '(A,A,A,ES10.3)') 'cable_statics ', site, ': continuation vs sequenced, largest relative difference ', rel
    CALL require(nan_max_abs(vc) >= 0.0_wp .AND. nan_max_abs(vs) >= 0.0_wp, site//': finite outputs')
    CALL require(rel <= RTOL, site//': the two static routes agree')
  END SUBROUTINE compare_modes

  SUBROUTINE check_bad_mode()
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL write_mode_deck('lozon_gomex80_power_cable', 'shortest cable_statics', 'csm_bad.dat')
    CALL CD_Run_Deck_Driver('csm_bad.dat', 'csm_bad', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'cable_statics') > 0, &
                 'a malformed cable_statics mode fails closed by name: '//TRIM(em))
  END SUBROUTINE check_bad_mode
END PROGRAM test_cable_statics_modes
