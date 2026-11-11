! File: tests/test_static_mesh_refinement.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_static_mesh_refinement
  !! Mesh-refinement gate for the EI=0 static initialization of the shipped composite
  !! (multi-section, strong EA/l0 contrast) grounded mooring decks. Each deck is re-run with
  !! every SECTIONS NumSegs multiplied by 1, 2, 3 and 4 and must converge at every factor,
  !! with the fairlead tension settling as the mesh is refined (a successive change that
  !! does not grow and stays below 3 %). A fine mesh of a stiff grounded line has to migrate
  !! its touchdown across many seabed-contact kinks; the plain Newton-Armijo stage stalls
  !! there and the static solve must recover through its regularized stage retry.
  !!
  !! Usage: test_static_mesh_refinement <examples directory>
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  CHARACTER(*), PARAMETER :: DECKS(3) = [CHARACTER(32) :: &
                                         'composite_chain_wire', 'composite_chain_poly_chain', &
                                         'semitaut_chain_polyester']
  INTEGER, PARAMETER :: NFACTOR = 4
  CHARACTER(1024) :: example_dir
  CHARACTER(256) :: root
  CHARACTER(512) :: em
  REAL(wp) :: fair(NFACTOR), change, prev_change
  INTEGER :: nfail, idk, k, es, nargs
  LOGICAL :: conv

  nfail = 0
  nargs = COMMAND_ARGUMENT_COUNT()
  IF (nargs < 1) THEN
    WRITE (*, '(A)') 'usage: test_static_mesh_refinement <examples directory>'
    ERROR STOP 2
  END IF
  CALL GET_COMMAND_ARGUMENT(1, example_dir)

  DO idk = 1, SIZE(DECKS)
    fair = 0.0_wp
    DO k = 1, NFACTOR
      WRITE (root, '(A,A,I0)') TRIM(DECKS(idk)), '_x', k
      CALL write_refined_deck(TRIM(example_dir)//'/'//TRIM(DECKS(idk))//'.dat', TRIM(root)//'.dat', k, es)
      CALL require(es == 0, 'write refined deck '//TRIM(root))
      IF (es /= 0) CYCLE
      CALL CD_Run_Deck_Driver(TRIM(root)//'.dat', TRIM(root), conv, es, em)
      CALL require(es == CD_DECKDRV_OK .AND. conv, 'static solve converges: '//TRIM(root)//' '//TRIM(em))
      CALL read_first_channel(TRIM(root)//'.out', fair(k), es)
      CALL require(es == 0 .AND. fair(k) > 0.0_wp, 'read fairlead tension '//TRIM(root))
    END DO
    prev_change = HUGE(1.0_wp)
    DO k = 2, NFACTOR
      IF (fair(k - 1) <= 0.0_wp) CYCLE
      change = ABS(fair(k) - fair(k - 1))/fair(k - 1)
      WRITE (*, '(A,A,I0,A,ES12.5,A,ES10.3)') TRIM(DECKS(idk)), ' x', k, ' FairTen1=', fair(k), &
        ' relative change=', change
      CALL require(change < 0.03_wp, 'fairlead tension settles under refinement: '//TRIM(DECKS(idk)))
      IF (prev_change < HUGE(1.0_wp)) CALL require(change <= prev_change*(1.0_wp + 1.0e-6_wp) + 1.0e-6_wp, &
                                                   'successive mesh change does not grow: '//TRIM(DECKS(idk)))
      prev_change = change
    END DO
  END DO

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'test_static_mesh_refinement: ', nfail, ' check(s) FAILED'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'test_static_mesh_refinement: all checks passed'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', TRIM(label)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE write_refined_deck(src, dst, factor, ErrStat)
    !! Copy a deck, multiplying the NumSegs column of every numeric SECTIONS row by factor.
    CHARACTER(*), INTENT(IN) :: src, dst
    INTEGER, INTENT(IN) :: factor
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: uin, uout, ios, line_id, nsegs
    CHARACTER(1024) :: buf
    CHARACTER(64) :: ltype
    REAL(wp) :: length
    LOGICAL :: in_sections

    ErrStat = 0
    in_sections = .FALSE.
    OPEN (NEWUNIT=uin, FILE=src, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      ErrStat = ios
      RETURN
    END IF
    OPEN (NEWUNIT=uout, FILE=dst, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    IF (ios /= 0) THEN
      ErrStat = ios
      CLOSE (uin)
      RETURN
    END IF
    DO
      READ (uin, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      IF (buf(1:1) == '-') THEN
        in_sections = INDEX(buf, 'SECTIONS') > 0
      ELSE IF (in_sections) THEN
        READ (buf, *, IOSTAT=ios) line_id, ltype, length, nsegs
        IF (ios == 0) THEN
          WRITE (uout, '(I0,1X,A,1X,ES23.16,1X,I0)') line_id, TRIM(ltype), length, factor*nsegs
          CYCLE
        END IF
      END IF
      WRITE (uout, '(A)') TRIM(buf)
    END DO
    CLOSE (uin)
    CLOSE (uout)
  END SUBROUTINE write_refined_deck

  SUBROUTINE read_first_channel(path, value, ErrStat)
    !! First output channel (FairTen1) of the last data row of a deck .out file.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: value
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    CHARACTER(1024) :: buf
    REAL(wp) :: t, v

    value = 0.0_wp
    ErrStat = 1
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, v
      IF (ios == 0) THEN
        value = v
        ErrStat = 0
      END IF
    END DO
    CLOSE (u)
  END SUBROUTINE read_first_channel

END PROGRAM test_static_mesh_refinement
