! File: tests/test_dtm_advisor.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_dtm_advisor
  !! The dtM advisor on the coupled (aggregate) route: the IEA-15 MW mixed mooring example built
  !! with the mooring step of an OpenFAST run. Its power cable (80 m bare, 100 m buoyant, 420 m
  !! bare) has an axial period of 0.351 s, which dtM = 0.1 s resolves in 3.5 steps: its
  !! initialisation note names the period and a dtM that resolves it, while the chains (0.778 s,
  !! 7.8 steps) are not noted. At dtM = 0.05 s (7.0 steps) no line is noted.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_GetInitLine, &
                                         CD_AGG_End, CD_AGG_OK
  IMPLICIT NONE

  CHARACTER(1024) :: deck
  INTEGER :: nfail

  nfail = 0
  IF (COMMAND_ARGUMENT_COUNT() < 1) THEN
    WRITE (*, '(A)') 'FAIL: the mixed example deck path argument is required'
    ERROR STOP 1
  END IF
  CALL GET_COMMAND_ARGUMENT(1, deck)
  CALL check_step(0.1_wp, .TRUE.)
  CALL check_step(0.05_wp, .FALSE.)
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: the dtM advisor notes the cable at dtM = 0.1 s and nothing at 0.05 s'

CONTAINS

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'FAIL: '//TRIM(msg)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE check_step(dt, cable_noted)
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(IN) :: cable_noted
    TYPE(CD_AGG_ModuleType) :: agg
    CHARACTER(2048) :: note
    CHARACTER(512) :: em
    CHARACTER(16) :: tag
    REAL(wp) :: tension, force(3), incl, decl, azi
    INTEGER :: es, i, line_id
    LOGICAL :: noted

    WRITE (tag, '(F5.3)') dt
    CALL CD_AGG_Init_From_Deck(agg, TRIM(deck), dt, es, em)
    CALL require(es == CD_AGG_OK, 'dtM '//TRIM(tag)//': init: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    DO i = 1, 4
      CALL CD_AGG_GetInitLine(agg, i, line_id, tension, force, incl, decl, azi, es, em, note=note)
      CALL require(es == CD_AGG_OK, 'dtM '//TRIM(tag)//': line summary: '//TRIM(em))
      noted = INDEX(note, 'axial period') > 0
      IF (line_id == 4 .AND. cable_noted) THEN
        CALL require(noted, 'dtM '//TRIM(tag)//': the cable is noted')
        CALL require(INDEX(note, 'LINE 4: dtM = 0.1000 s resolves its axial period of 0.351 s') > 0 .AND. &
                     INDEX(note, 'in 3.5 steps, fewer than 6') > 0 .AND. &
                     INDEX(note, 'A dtM of at most 0.0585 s resolves them') > 0, &
                     'dtM '//TRIM(tag)//': the cable note gives the period, the steps and the remedy: '//TRIM(note))
      ELSE
        CALL require(.NOT. noted, 'dtM '//TRIM(tag)//': line '//CHAR(48 + line_id)//' is not noted: '//TRIM(note))
      END IF
    END DO
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_step

END PROGRAM test_dtm_advisor
