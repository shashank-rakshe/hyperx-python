! File: tests/test_deck_massless_connect.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_deck_massless_connect
  !! Deck-level gate for the MoorDyn mid-line split pattern: a MASSLESS Connect point
  !! joins a rope section to a large-diameter, nearly neutral float section. The float
  !! section's added mass per length (Can = 2: 1610 kg/m) is about twice its structural
  !! mass (820 kg/m); EI=0 decks reject net-buoyant sections, so Can = 2 is what puts a
  !! sinking section in that regime. Such a junction diverged within a few steps when the
  !! attached end nodes' added mass was carried at the previous step's acceleration. The
  !! 60 s wave-excited dynamic march at a typical dtM must complete with finite, bounded
  !! loads and junction motion.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  INTEGER, PARAMETER :: NCOL = 6
  INTEGER :: failures, es, u, ios, nrow
  LOGICAL :: conv
  REAL(wp) :: row(NCOL), first(NCOL), last(NCOL), max_ten, late_lo(3), late_hi(3)
  LOGICAL :: inside
  CHARACTER(512) :: em, buf

  failures = 0
  CALL write_deck('deck_massless_connect_float.dat')
  CALL CD_Run_Deck_Driver('deck_massless_connect_float.dat', 'deck_massless_connect_float', conv, es, em)
  CALL require(es == CD_DECKDRV_OK, 'massless Connect + float section 60 s march: '//TRIM(em))
  CALL require(conv, 'massless Connect + float section march converged')

  nrow = 0
  max_ten = 0.0_wp
  late_lo = HUGE(1.0_wp)
  late_hi = -HUGE(1.0_wp)
  inside = .TRUE.
  first = 0.0_wp
  last = 0.0_wp
  OPEN (NEWUNIT=u, FILE='deck_massless_connect_float.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  CALL require(ios == 0, 'open .out')
  IF (ios == 0) THEN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) row
      CALL require(ios == 0, 'parse .out row')
      IF (ios /= 0) EXIT
      nrow = nrow + 1
      IF (nrow == 1) first = row
      last = row
      CALL require(ALL(IEEE_IS_FINITE(row)), 'finite loads and junction motion in every row')
      IF (.NOT. ALL(IEEE_IS_FINITE(row))) EXIT
      max_ten = MAX(max_ten, row(2), row(3))
      inside = inside .AND. row(4) >= -150.0_wp .AND. row(4) <= 0.0_wp .AND. &
               row(6) >= -100.0_wp .AND. row(6) <= 0.0_wp
      IF (row(1) >= 50.0_wp) THEN
        late_lo = MIN(late_lo, row(4:6))
        late_hi = MAX(late_hi, row(4:6))
      END IF
    END DO
    CLOSE (u)
  END IF
  CALL require(nrow > 100 .AND. ABS(last(1) - 60.0_wp) < 1.0e-6_wp, 'march reaches TMax = 60 s')
  CALL require(first(2) > 0.0_wp .AND. first(3) > 0.0_wp, 'both sections start in tension')
  CALL require(max_ten < 5.0_wp*MAX(first(2), first(3)), 'fairlead/anchor tension stays bounded')
  ! The junction is seeded at its deck coordinates and settles dynamically; it must stay
  ! between the anchor and the fairlead and be settled (not growing) over the last 10 s.
  CALL require(inside, 'massless junction stays between the anchor and the fairlead above the seabed')
  CALL require(MAXVAL(late_hi - late_lo) < 1.0_wp, 'massless junction settled over the last 10 s')

  IF (failures /= 0) THEN
    WRITE (*, '(A,I0,A)') 'test_deck_massless_connect: ', failures, ' failure(s)'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'test_deck_massless_connect: all checks passed'

CONTAINS

  SUBROUTINE write_deck(path)
    !! Anchor - rope (100 m) - massless Connect - float section (80 m) - fixed
    !! fairlead, 100 m water, Airy waves for excitation.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: w
    OPEN (NEWUNIT=w, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (w, '(A)') 'Massless Connect joining a rope and a nearly neutral float section (Can = 2)'
    WRITE (w, '(A)') '--- LINE TYPES ---'
    WRITE (w, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (w, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (w, '(A)') 'rope 0.16 25.0 5.0e7 -1.0 0.0 1.2 0.008 1.0 0.0'
    WRITE (w, '(A)') 'float 1.00 820.0 5.0e7 -1.0 0.0 1.2 0.008 2.0 0.0'
    WRITE (w, '(A)') '--- POINTS ---'
    WRITE (w, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (w, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (w, '(A)') '1 Fixed -150.0 0.0 -100.0 0.0 0.0 0.0 0.0'
    WRITE (w, '(A)') '2 Connect -60.0 0.0 -60.0 0.0 0.0 0.0 0.0'
    WRITE (w, '(A)') '3 Fixed 0.0 0.0 -20.0 0.0 0.0 0.0 0.0'
    WRITE (w, '(A)') '--- LINES ---'
    WRITE (w, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (w, '(A)') '(-) (-) (-) (-)'
    WRITE (w, '(A)') '1 1 2 -'
    WRITE (w, '(A)') '2 2 3 -'
    WRITE (w, '(A)') '--- SECTIONS ---'
    WRITE (w, '(A)') 'LineID LineType Length NumSegs'
    WRITE (w, '(A)') '(-) (-) (m) (-)'
    WRITE (w, '(A)') '1 rope 100.0 10'
    WRITE (w, '(A)') '2 float 80.0 8'
    WRITE (w, '(A)') '--- OPTIONS ---'
    WRITE (w, '(A)') '9.80665 g'
    WRITE (w, '(A)') '1025.0 rhoW'
    WRITE (w, '(A)') '100.0 WtrDpth'
    WRITE (w, '(A)') '1.0e5 kBot'
    WRITE (w, '(A)') '1.0e4 cBot'
    WRITE (w, '(A)') '0.01 dtM'
    WRITE (w, '(A)') '60.0 TMax'
    WRITE (w, '(A)') 'airy 3.0 8.0 0.0 waves'
    WRITE (w, '(A)') '--- OUTPUTS ---'
    WRITE (w, '(A)') 'FairTen1 FairTen2 Point2px Point2py Point2pz'
    WRITE (w, '(A)') '--- end ---'
    CLOSE (w)
  END SUBROUTINE write_deck

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (cond) RETURN
    failures = failures + 1
    WRITE (*, '(A)') 'FAIL: '//msg
  END SUBROUTINE require
END PROGRAM test_deck_massless_connect
